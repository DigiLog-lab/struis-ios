"""端末(phone)。本文を持ち、Anthropic との TLS 1.3 を自分で張る。API キーは知らない。"""
from __future__ import annotations

import json
import socket
import ssl
import struct
import time
from typing import Any

from cryptography.exceptions import InvalidTag
from tlslite import TLSConnection
from tlslite.constants import KeyUpdateMessageType
from tlslite.handshakesettings import HandshakeSettings
from tlslite.mathtls import HKDF_expand_label

from . import tlsrec, vzk
from .channel import Tunnel, send_frame
from .relay import Plan
from .util import HttpReader


def key_iv(secret: bytes) -> tuple[bytes, bytes]:
    return (bytes(HKDF_expand_label(secret, b"key", b"", 16, "sha256")),
            bytes(HKDF_expand_label(secret, b"iv", b"", 12, "sha256")))


class Phone:
    def __init__(self, relay_port: int, outer_ca: str, sni: str) -> None:
        self.sni: str = sni
        self.t0: float = time.time()
        raw: socket.socket = socket.create_connection(("127.0.0.1", relay_port))
        raw.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
        ctx: ssl.SSLContext = ssl.create_default_context(cafile=outer_ca)
        self.outer: ssl.SSLSocket = ctx.wrap_socket(raw, server_hostname="localhost")
        self.tunnel: Tunnel = Tunnel(self.outer)
        self.conn: TLSConnection = TLSConnection(self.tunnel)
        self.server_key: bytes = b""
        self.server_iv: bytes = b""
        self.handed: list[tuple[bytes, bytes]] = []     # relay に渡した鍵(検証用の記録)
        self.kept: list[tuple[bytes, bytes]] = []       # phone だけが持つ世代の鍵(検証用の記録)
        self.t_handshake: float = 0.0
        self.t_first_text: float | None = None
        self.t_end: float = 0.0
        self.http: HttpReader = HttpReader(lambda: bytes(self.conn.read(max=65536, min=1)))
        self.response_first_record: int = 0     # いまの応答が始まるレコードの番号(relay と同じ数え方)

    def handshake(self) -> None:
        st: HandshakeSettings = HandshakeSettings()
        st.minVersion = (3, 4)
        st.maxVersion = (3, 4)
        st.cipherNames = ["aes128gcm"]
        self.conn.handshakeClientCert(settings=st, serverName=self.sni, alpn=[b"http/1.1"])
        assert self.conn.version == (3, 4)
        self.server_key, self.server_iv = key_iv(bytes(self.conn.session.sr_app_secret))
        self.t_handshake = time.time()

    def server_chain_der(self) -> list[bytes]:
        return [bytes(c.bytes) for c in self.conn.session.serverCertChain.x509List]

    def verify_server_chain(self, cafile: str | None = None) -> str:
        """相手の証明書の鎖を公開の認証局まで確かめる(署名の検証は tlslite がハンドシェイクで済ませている)。"""
        from cryptography import x509
        from cryptography.x509.verification import PolicyBuilder, Store
        import certifi
        pem: bytes = open(cafile or certifi.where(), "rb").read()
        store = Store(x509.load_pem_x509_certificates(pem))
        chain = [x509.load_der_x509_certificate(d) for d in self.server_chain_der()]
        verifier = PolicyBuilder().store(store).build_server_verifier(x509.DNSName(self.sni))
        verifier.verify(chain[0], chain[1:])
        return chain[0].issuer.rfc4514_string()

    # --- 送信鍵の世代 ---
    def _advance_locally(self) -> None:
        """KeyUpdate を送らずに自分の送信鍵だけ次の世代へ進める(KeyUpdate は relay が書いた)。"""
        s = self.conn.session
        s.cl_app_secret, s.sr_app_secret = self.conn._recordLayer.calcTLS1_3KeyUpdate_reciever(
            s.cipherSuite, s.cl_app_secret, s.sr_app_secret)

    def _hand_current_generation(self, role: str, **extra: Any) -> None:
        key, iv = key_iv(bytes(self.conn.session.cl_app_secret))
        self.handed.append((key, iv))
        # 返事を待たずに続きを送る。relay は届いた順に処理するので、順番は保たれる
        send_frame(self.outer, b"H", json.dumps({"role": role, "key": key.hex(), "iv": iv.hex(), **extra}).encode(),
                   self.tunnel.lock)
        self._advance_locally()
        self.kept.append(key_iv(bytes(self.conn.session.cl_app_secret)))

    def send_request(self, middle: bytes, with_suffix: bool) -> None:
        """relay が先頭(と末尾)を書き、phone は真ん中だけを自分の鍵で送る。"""
        self.response_first_record = sum(
            1 for r in tlsrec.RecordParser().feed(bytes(self.tunnel.inbound)) if r[0] == tlsrec.APPLICATION_DATA)
        self.http.t_first_text = None
        self._hand_current_generation("head", middle_len=len(middle))
        self.conn.write(middle)
        if with_suffix:
            for _ in self.conn.send_keyupdate_request(KeyUpdateMessageType.update_not_requested):
                pass
            self._hand_current_generation("suffix")

    def send_keyupdate(self) -> None:
        """同じ接続で次のリクエストを送る前に、relay に渡す新しい世代へ進む。"""
        for _ in self.conn.send_keyupdate_request(KeyUpdateMessageType.update_not_requested):
            pass

    # --- 受信 ---
    def read_response(self) -> tuple[int, dict[str, str], bytes]:
        """HTTP/1.1 の応答を 1 つ読む。(ステータス, ヘッダー, 本文) を返す。"""
        out = self.http.response()
        self.t_first_text = self.http.t_first_text
        self.t_end = self.http.t_end
        return out

    def drain(self) -> None:
        """サーバーが接続を閉じるまで読む(connection: close の後始末)。"""
        try:
            while self.conn.read(max=65536, min=1):
                pass
        except Exception:               # noqa: BLE001
            pass

    # --- usage の証明 ---
    def app_stream(self) -> list[tuple[int, int, bytes, bytes]]:
        """受け取ったレコードのうちアプリ用の鍵のもの。(relay での番号, seq, レコード, 平文 inner)。"""
        out: list[tuple[int, int, bytes, bytes]] = []
        seq: int = 0
        index: int = -1
        for rec in tlsrec.RecordParser().feed(bytes(self.tunnel.inbound)):
            if rec[0] != tlsrec.APPLICATION_DATA:
                continue
            index += 1
            try:
                from cryptography.hazmat.primitives.ciphers.aead import AESGCM
                inner: bytes = AESGCM(self.server_key).decrypt(
                    tlsrec.nonce(self.server_iv, seq), rec[5:], rec[:5])
            except InvalidTag:
                continue                 # ハンドシェイク用の鍵のレコード
            out.append((index, seq, rec, inner))
            seq += 1
        return out

    def build_statement(self, include_message_start: bool = True,
                        tail_from: int | None = None) -> dict[str, Any]:
        """開ける範囲の申告を作る。tail_from は検証用(末尾の開始位置を偽る)。"""
        records = [r for r in self.app_stream() if r[0] >= self.response_first_record]
        # アプリデータの通し位置 → (レコード, レコード内の位置)
        flat: bytearray = bytearray()
        where: list[tuple[int, int]] = []
        for i, (_, _, _, inner) in enumerate(records):
            stripped: bytes = inner.rstrip(b"\x00")
            if stripped[-1] == tlsrec.APPLICATION_DATA:
                for off in range(len(stripped) - 1):
                    where.append((i, off))
                flat += stripped[:-1]
        text: bytes = bytes(flat)
        self.last_app_text = text
        pos: int = text.rfind(b"\nevent: message_delta\n") if tail_from is None else tail_from
        if pos < 0:
            raise RuntimeError("no message_delta in the response")
        ti, toff = where[pos]
        opens: dict[int, dict[str, Any]] = {}
        for i in range(ti, len(records)):
            index, seq, rec, inner = records[i]
            start: int = toff if i == ti else 0
            opens[index] = {"record": index, "seq": seq, "ranges": [[start, len(inner)]]}
        stmt: dict[str, Any] = {"iv": self.server_iv.hex(),
                                "tail": {"record": records[ti][0], "offset": toff}}
        if include_message_start:
            a: int = text.find(b"\nevent: message_start\n")
            b: int = text.find(b"\n\n", a + 1) + 2
            ai, aoff = where[a]
            bi, boff = where[b - 1]
            if ai != bi:
                raise RuntimeError("message_start spans two records (not handled in this PoC)")
            index, seq, rec, inner = records[ai]
            entry = opens.setdefault(index, {"record": index, "seq": seq, "ranges": []})
            entry["ranges"].append([aoff, boff + 1])
            stmt["message_start"] = {"record": index, "start": aoff, "end": boff + 1}
        stmt["opens"] = [opens[k] for k in sorted(opens)]
        return stmt

    def plan_for(self, stmt: dict[str, Any]) -> Plan:
        by_index = {r[0]: r for r in self.app_stream()}
        plan: Plan = Plan(bytes.fromhex(stmt["iv"]))
        for o in stmt["opens"]:
            rec: bytes = by_index[o["record"]][2]
            plan.add_record(o["record"], int(o["seq"]), len(rec) - 5 - 16, [tuple(r) for r in o["ranges"]])
        return plan

    def prove(self, stmt: dict[str, Any], key: bytes | None = None, tamper: str | None = None,
              ) -> tuple[dict[str, Any], dict[str, Any]]:
        """申告と証明を 1 通で送る。(relay の判定, 証明側の計測) を返す。key と tamper は検証用。"""
        plan: Plan = self.plan_for(stmt)
        t0: float = time.time()
        proof: bytes = vzk.prove(key or self.server_key, plan.blocks, plan.masks, tamper=tamper)
        stats: dict[str, Any] = {"prove_s": round(time.time() - t0, 3), "proof_bytes": len(proof),
                                 "aes_blocks": len(plan.blocks)}
        body: bytes = json.dumps(stmt).encode()
        send_frame(self.outer, b"P", struct.pack(">I", len(body)) + body + proof, self.tunnel.lock)
        kind, verdict = self.tunnel.ctrl.get(timeout=120.0)
        assert kind == b"R"
        return verdict, stats

    def close(self) -> None:
        try:
            self.outer.close()
        except OSError:
            pass
