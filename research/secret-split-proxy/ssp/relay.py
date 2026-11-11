"""中継サーバー(relay)。API キーを持ち、内側の TLS は終端しない。

relay が知るもの: API キー、接続先、phone が渡した「自分が書く世代」の送信鍵、暗号文の長さと時刻。
relay が知らないもの: phone の本文、Anthropic の応答(phone が証明で開けた範囲を除く)。
"""
from __future__ import annotations

import dataclasses
import json
import re
import socket
import ssl
import struct
import threading
import time
from typing import Any, Callable

from . import tlsrec
from .channel import recv_frame, send_frame


@dataclasses.dataclass
class Policy:
    """relay が強制する内容。HTTP の先頭と、本文の先頭・末尾を relay が書く。"""
    host: str
    api_key: str
    path: str = "/v1/messages"
    body_prefix: bytes = b""
    body_suffix: bytes = b""          # 空なら末尾の世代は使わない
    keep_alive: bool = False
    extra_headers: tuple[tuple[str, str], ...] = (("anthropic-version", "2023-06-01"),)

    def head(self, middle_len: int) -> bytes:
        total: int = len(self.body_prefix) + middle_len + len(self.body_suffix)
        lines: list[str] = [f"POST {self.path} HTTP/1.1", f"Host: {self.host}", f"x-api-key: {self.api_key}"]
        lines += [f"{k}: {v}" for k, v in self.extra_headers]
        lines += ["content-type: application/json", f"content-length: {total}"]
        if not self.keep_alive:
            lines.append("connection: close")
        return ("\r\n".join(lines) + "\r\n\r\n").encode() + self.body_prefix


class ClientHelloRejected(Exception):
    pass


def check_client_hello(record: bytes, expect_sni: str) -> None:
    """ClientHello(平文)の接続先を確かめる。別のホスト名や ECH は通さない。"""
    if record[0] != 0x16 or record[5] != 0x01:
        raise ClientHelloRejected("first record is not a ClientHello")
    p: int = 5 + 4 + 2 + 32
    p += 1 + record[p]
    p += 2 + struct.unpack(">H", record[p:p + 2])[0]
    p += 1 + record[p]
    end: int = p + 2 + struct.unpack(">H", record[p:p + 2])[0]
    p += 2
    sni: str | None = None
    alpn: list[bytes] = []
    while p < end:
        etype, elen = struct.unpack(">HH", record[p:p + 4])
        body: bytes = record[p + 4:p + 4 + elen]
        if etype == 0x0000:
            sni = body[5:5 + struct.unpack(">H", body[3:5])[0]].decode()
        elif etype == 0xFE0D:
            raise ClientHelloRejected("encrypted client hello is not allowed")
        elif etype == 0x0010:
            q: int = 2
            while q < len(body):
                alpn.append(body[q + 1:q + 1 + body[q]])
                q += 1 + body[q]
        p += 4 + elen
    if sni != expect_sni:
        raise ClientHelloRejected(f"server name {sni!r} is not {expect_sni!r}")
    if alpn != [b"http/1.1"]:
        raise ClientHelloRejected(f"alpn {alpn!r} is not http/1.1 only")


class Session:
    """phone 1 接続ぶんの relay の状態。"""

    def __init__(self, down: socket.socket, upstream: tuple[str, int], policy: Policy,
                 verifier: Callable[[list[bytes], list[bytes]], tuple[list[bytes], dict[str, Any]]] | None) -> None:
        self.down: socket.socket = down
        self.policy: Policy = policy
        self.verifier = verifier
        self.down_lock: threading.Lock = threading.Lock()
        self.up: socket.socket = socket.create_connection(upstream)
        self.up.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
        self.client_parser: tlsrec.RecordParser = tlsrec.RecordParser()
        self.server_parser: tlsrec.RecordParser = tlsrec.RecordParser()
        self.first_client_record: bool = True
        # 記録(検証で「relay に何が見えたか」を調べるためのもの)
        self.client_records: list[bytes] = []       # phone が書いた内側 TLS のレコード
        self.injected_records: list[bytes] = []     # relay が書いたレコード
        self.server_records: list[bytes] = []       # Anthropic から来たレコード(暗号文のまま)
        self.held_keys: list[tuple[bytes, bytes]] = []
        self.up_bytes: int = 0
        self.down_bytes: int = 0
        self.app_records: list[bytes] = []          # server_records のうち種類 0x17 のもの(証明での番号)
        self.response_start: int = 0                # いまの応答が始まる app_records の位置
        self.proved_until: int | None = None        # 直前の証明が「ここまでが応答」とした app_records の長さ
        self.late_records: bool = False             # 証明の後に、その応答のレコードが届いた
        self.server_closed: threading.Event = threading.Event()
        self.verdicts: list[dict[str, Any]] = []
        self.error: str | None = None

    def send_up(self, data: bytes) -> None:
        self.up_bytes += len(data)
        self.up.sendall(data)

    def run(self) -> None:
        threading.Thread(target=self._pump_down, daemon=True).start()
        try:
            while True:
                kind, payload = recv_frame(self.down)
                if kind == b"D":
                    for rec in self.client_parser.feed(payload):
                        if self.first_client_record:
                            check_client_hello(rec, self.policy.host)
                            self.first_client_record = False
                        self.client_records.append(rec)
                        self.send_up(rec)
                elif kind == b"H":
                    reply: dict[str, Any] = self._handoff(json.loads(payload))
                    send_frame(self.down, b"A", json.dumps(reply).encode(), self.down_lock)
                elif kind == b"P":
                    verdict: dict[str, Any] = self._judge(json.loads(payload))
                    self.verdicts.append(verdict)
                    send_frame(self.down, b"R", json.dumps(verdict).encode(), self.down_lock)
        except ClientHelloRejected as e:
            self.error = f"rejected: {e}"
        except (ConnectionError, OSError):
            pass
        finally:
            for s in (self.up, self.down):
                try:
                    s.close()
                except OSError:
                    pass

    def _pump_down(self) -> None:
        try:
            while True:
                data: bytes = self.up.recv(65536)
                if not data:
                    break
                self.down_bytes += len(data)
                for rec in self.server_parser.feed(data):
                    self.server_records.append(rec)
                    if rec[0] == tlsrec.APPLICATION_DATA:
                        self.app_records.append(rec)
                send_frame(self.down, b"D", data, self.down_lock)
        except OSError:
            pass
        self.server_closed.set()
        try:
            send_frame(self.down, b"E", b"", self.down_lock)
        except OSError:
            pass

    def _handoff(self, msg: dict[str, Any]) -> dict[str, Any]:
        """phone から「relay が書く世代」の鍵を受け取り、relay の持ち分を書いて KeyUpdate で閉じる。"""
        key: bytes = bytes.fromhex(msg["key"])
        iv: bytes = bytes.fromhex(msg["iv"])
        self.held_keys.append((key, iv))
        if msg["role"] == "head":
            if self.proved_until is not None and len(self.app_records) != self.proved_until:
                self.late_records = True
            self.proved_until = None
            self.response_start = len(self.app_records)
            content: bytes = self.policy.head(int(msg["middle_len"]))
        elif msg["role"] == "suffix":
            content = self.policy.body_suffix
        else:
            raise ValueError(msg["role"])
        out, seq = tlsrec.seal_many(key, iv, 0, tlsrec.APPLICATION_DATA, content)
        if not msg.get("skip_key_update"):
            out += tlsrec.seal(key, iv, seq, tlsrec.HANDSHAKE, tlsrec.KEY_UPDATE_NOT_REQUESTED)
        for rec in tlsrec.RecordParser().feed(out):
            self.injected_records.append(rec)
        self.send_up(out)
        return {"ok": True, "t": time.time()}

    # ------------------------------------------------------------ usage の証明 ----
    def _judge(self, stmt: dict[str, Any]) -> dict[str, Any]:
        try:
            return self._judge_inner(stmt)
        except Reject as e:
            return {"accepted": False, "reason": str(e)}

    def _judge_inner(self, stmt: dict[str, Any]) -> dict[str, Any]:
        if self.verifier is None:
            raise Reject("no verifier configured")
        if not self.policy.keep_alive and not self.server_closed.wait(timeout=15):
            raise Reject("the response has not ended")
        iv: bytes = bytes.fromhex(stmt["iv"])
        app: list[bytes] = list(self.app_records)
        self.proved_until = len(app)
        opens: list[dict[str, Any]] = stmt["opens"]
        plan: Plan = Plan(iv)
        for o in opens:
            rec: bytes = app[o["record"]]
            plan.add_record(o["record"], int(o["seq"]), len(rec) - 5 - 16, [tuple(r) for r in o["ranges"]])
        outputs, stats = self.verifier(plan.blocks, plan.masks)
        h: bytes = outputs[0]
        opened: dict[int, dict[int, int]] = {}
        for o in opens:
            idx: int = o["record"]
            rec = app[idx]
            ct: bytes = rec[5:-16]
            mask: bytes = outputs[plan.j0_at[idx]]
            if tlsrec.gcm_tag(h, mask, rec[:5], ct) != rec[-16:]:
                raise Reject(f"record {idx}: the authentication tag does not match the recorded ciphertext")
            plain: dict[int, int] = {}
            for (blk, out_i) in plan.ctr_at[idx]:
                ks: bytes = outputs[out_i]
                km: bytes = plan.masks[out_i]
                for b in range(16):
                    pos: int = blk * 16 + b
                    if km[b] == 0xFF and pos < len(ct):
                        plain[pos] = ct[pos] ^ ks[b]
            opened[idx] = plain
        usage: dict[str, Any] = self._read_opened(stmt, app, opened)
        usage["proof"] = stats
        usage["accepted"] = True
        return usage

    def _read_opened(self, stmt: dict[str, Any], app: list[bytes],
                     opened: dict[int, dict[int, int]]) -> dict[str, Any]:
        result: dict[str, Any] = {}
        # 1) 末尾: ある位置から「この応答の最後のレコードの最後のバイト」まで全部開いていること
        tail_from: dict[str, int] = stmt["tail"]
        last: int = len(app) - 1
        stream: bytearray = bytearray()
        alerts: int = 0
        for idx in range(tail_from["record"], last + 1):
            if idx not in opened:
                raise Reject(f"record {idx} after the tail start is not opened")
            inner_len: int = len(app[idx]) - 5 - 16
            start: int = tail_from["offset"] if idx == tail_from["record"] else 0
            try:
                inner: bytes = bytes(opened[idx][p] for p in range(start, inner_len))
            except KeyError:
                raise Reject(f"record {idx} is not opened to its end") from None
            stripped: bytes = inner.rstrip(b"\x00")
            if not stripped:
                raise Reject(f"record {idx}: no content type")
            if stripped[-1] == tlsrec.APPLICATION_DATA:
                stream += stripped[:-1]
            elif stripped[-1] == tlsrec.ALERT and idx != tail_from["record"]:
                alerts += 1
            else:
                raise Reject(f"record {idx}: unexpected inner type {stripped[-1]}")
        if tail_from["record"] < self.response_start:
            raise Reject("the tail starts before this response")
        result["message_delta"] = parse_tail(bytes(stream))
        # 2) 冒頭の message_start(任意)
        ms: dict[str, int] | None = stmt.get("message_start")
        if ms is not None:
            idx = ms["record"]
            if idx < self.response_start or idx not in opened:
                raise Reject("message_start is outside this response")
            try:
                span: bytes = bytes(opened[idx][p] for p in range(ms["start"], ms["end"]))
            except KeyError:
                raise Reject("message_start range is not fully opened") from None
            result["message_start"] = parse_message_start(span)
        return result


class Reject(Exception):
    pass


CHUNK_FRAMING: re.Pattern[bytes] = re.compile(rb"\r\n[0-9a-fA-F]+\r\n")


def strip_chunk_framing(text: bytes) -> bytes:
    """HTTP の chunked の区切り(\\r\\n<16進>\\r\\n)を取り除く。

    SSE の中身には生の CR が現れない(JSON の中では \\r と書かれる)ので、生の CR は区切りにしか出ない。
    """
    text = CHUNK_FRAMING.sub(b"", text)
    if text.endswith(b"\r\n"):
        text = text[:-2]
    if b"\r" in text:
        raise Reject("unexpected CR in the opened text")
    return text


def parse_tail(text: bytes) -> dict[str, Any]:
    """開いた末尾が「生の改行 + message_delta のイベント + message_stop」で終わっていることを確かめる。"""
    text = strip_chunk_framing(text)
    if not text.startswith(b"\nevent: message_delta\ndata: "):
        raise Reject("the tail does not start at a message_delta event")
    events: list[bytes] = [e for e in text[1:].split(b"\n\n") if e and e != b"0"]
    names: list[bytes] = [e.split(b"\n", 1)[0] for e in events]
    wanted: list[bytes] = [n for n in names if n != b"event: ping"]
    if wanted != [b"event: message_delta", b"event: message_stop"]:
        raise Reject(f"the tail holds unexpected events: {names!r}")
    line: bytes = events[0].split(b"\n", 1)[1]
    if not line.startswith(b"data: ") or b"\n" in line:
        raise Reject("message_delta data is not a single line")
    body: dict[str, Any] = json.loads(line[6:])
    if body.get("type") != "message_delta":
        raise Reject("not a message_delta body")
    return {"usage": body.get("usage"), "stop_reason": body.get("delta", {}).get("stop_reason")}


def parse_message_start(text: bytes) -> dict[str, Any]:
    text = strip_chunk_framing(text)
    prefix: bytes = b"\nevent: message_start\ndata: "
    if not text.startswith(prefix) or not text.endswith(b"\n\n"):
        raise Reject("the opened range is not a whole message_start event")
    line: bytes = text[len(prefix):-2]
    if b"\n" in line:
        raise Reject("message_start data is not a single line")
    body: dict[str, Any] = json.loads(line)
    if body.get("type") != "message_start":
        raise Reject("not a message_start body")
    msg: dict[str, Any] = body["message"]
    return {"model": msg.get("model"), "usage": msg.get("usage"), "id": msg.get("id")}


class Plan:
    """開ける範囲から、証明する AES のブロックの一覧を作る。phone と relay が同じ手順で作る。

    blocks[i] は AES に入れる16バイト(公開)、masks[i] は出力のうち relay に見せるバイト(0xFF)の指定。
    先頭は H = AES_K(0)。レコードごとに J0(タグの照合用、全バイト)と、開ける範囲のカウンターブロック。
    """

    def __init__(self, iv: bytes) -> None:
        self.iv: bytes = iv
        self.blocks: list[bytes] = [b"\x00" * 16]
        self.masks: list[bytes] = [b"\xff" * 16]
        self.j0_at: dict[int, int] = {}
        self.ctr_at: dict[int, list[tuple[int, int]]] = {}

    def add_record(self, index: int, seq: int, inner_len: int, ranges: list[tuple[int, int]]) -> None:
        if index in self.j0_at:
            raise Reject("record listed twice")
        self.j0_at[index] = len(self.blocks)
        self.blocks.append(tlsrec.j0(self.iv, seq))
        self.masks.append(b"\xff" * 16)
        want: dict[int, bytearray] = {}
        for start, end in ranges:
            if not 0 <= start < end <= inner_len:
                raise Reject("range outside the record")
            for pos in range(start, end):
                want.setdefault(pos // 16, bytearray(16))[pos % 16] = 0xFF
        self.ctr_at[index] = []
        for blk in sorted(want):
            self.ctr_at[index].append((blk, len(self.blocks)))
            self.blocks.append(tlsrec.ctr_block(self.iv, seq, blk))
            self.masks.append(bytes(want[blk]))


class Relay:
    """外側の TLS で phone を待ち受ける。"""

    def __init__(self, upstream: tuple[str, int], policy: Policy, certfile: str, keyfile: str,
                 verifier: Callable[[list[bytes], list[bytes]], tuple[list[bytes], dict[str, Any]]] | None = None) -> None:
        self.upstream: tuple[str, int] = upstream
        self.policy: Policy = policy
        self.verifier = verifier
        self.ctx: ssl.SSLContext = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        self.ctx.load_cert_chain(certfile, keyfile)
        self.lsock: socket.socket = socket.socket()
        self.lsock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        self.lsock.bind(("127.0.0.1", 0))
        self.lsock.listen(8)
        self.port: int = self.lsock.getsockname()[1]
        self.sessions: list[Session] = []
        threading.Thread(target=self._accept, daemon=True).start()

    def _accept(self) -> None:
        while True:
            try:
                raw, _ = self.lsock.accept()
            except OSError:
                return
            raw.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
            try:
                down: socket.socket = self.ctx.wrap_socket(raw, server_side=True)
                session: Session = Session(down, self.upstream, self.policy, self.verifier)
            except (OSError, ssl.SSLError):
                raw.close()
                continue
            self.sessions.append(session)
            threading.Thread(target=session.run, daemon=True).start()
