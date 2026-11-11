"""秘密分離型プロキシの検証一式。1 項目ごとに PASS / FAIL を出す。

  python verify.py --target mock                       # 手元の模擬サーバー(OpenSSL)
  python verify.py --target anthropic --key-file PATH  # 本物の Messages API

API キー、通信の鍵、暗号文は出力しない(リポジトリが公開のため)。
"""
from __future__ import annotations

import argparse
import json
import os
import socket
import statistics
import sys
import time
import traceback
from typing import Any, Callable

from cryptography.exceptions import InvalidTag
from tlslite import TLSConnection
from tlslite.handshakesettings import HandshakeSettings

from ssp import tlsrec, vzk
from ssp.channel import Meter
from ssp.mock import MockAnthropic, self_signed
from ssp.phone import Phone
from ssp.relay import Policy, Relay, Session
from ssp.util import HttpReader, TerminatingProxy, summarize, user_content

RESULTS: list[tuple[str, bool, str]] = []
SECRET: str = "PHONE-ONLY-MARKER-7c1e9a"


def record(check: str, ok: bool, detail: str) -> None:
    RESULTS.append((check, ok, detail))
    print(f"{'PASS' if ok else 'FAIL'} {check}: {detail}", flush=True)


class Env:
    def __init__(self, target: str, key_file: str | None) -> None:
        self.target: str = target
        self.cert, self.keyfile = self_signed()
        if target == "mock":
            self.mock: MockAnthropic | None = MockAnthropic()
            self.host: str = "localhost"
            self.upstream: tuple[str, int] = ("127.0.0.1", self.mock.port)
            self.api_key: str = "sk-ant-MOCK-RELAY-ONLY-0123456789abcdef"
            self.upstream_ca: str | None = self.mock.cert
            self.model_a: str = "mock-small"
            self.model_b: str = "mock-large"
        else:
            self.mock = None
            self.host = "api.anthropic.com"
            self.upstream = (self.host, 443)
            # キーなしの時は、形だけ本物に似せたダミーを使う。API は 401 を返すが、TLS の層の受け付けは確かめられる
            self.api_key = open(key_file).read().strip() if key_file else "sk-ant-api03-" + "D" * 93
            self.upstream_ca = None
            self.model_a = "" if key_file else "claude-haiku-5-5"
            self.model_b = "" if key_file else "claude-sonnet-5-5"
        self.keyless: bool = target != "mock" and not key_file

    def policy(self, prefix: bytes, suffix: bytes = b"", keep_alive: bool = False) -> Policy:
        return Policy(host=self.host, api_key=self.api_key, body_prefix=prefix, body_suffix=suffix,
                      keep_alive=keep_alive)


def tls_client(addr: tuple[str, int], sni: str) -> TLSConnection:
    sock: socket.socket = socket.create_connection(addr)
    sock.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
    conn: TLSConnection = TLSConnection(sock)
    st: HandshakeSettings = HandshakeSettings()
    st.minVersion = (3, 4)
    st.maxVersion = (3, 4)
    st.cipherNames = ["aes128gcm"]
    conn.handshakeClientCert(settings=st, serverName=sni, alpn=[b"http/1.1"])
    return conn


def direct(env: Env, method: str, path: str, body: bytes, addr: tuple[str, int] | None = None,
           with_key: bool = True) -> tuple[int, dict[str, str], bytes, dict[str, float]]:
    """relay を通さず、鍵を自分で持って送る(比較と下調べ用)。"""
    t0: float = time.time()
    conn: TLSConnection = tls_client(addr or env.upstream, env.host)
    head: str = (f"{method} {path} HTTP/1.1\r\nHost: {env.host}\r\nanthropic-version: 2023-06-01\r\n"
                 f"content-type: application/json\r\ncontent-length: {len(body)}\r\nconnection: close\r\n")
    if with_key:
        head += f"x-api-key: {env.api_key}\r\n"
    conn.write((head + "\r\n").encode() + body)
    reader: HttpReader = HttpReader(lambda: bytes(conn.read(max=65536, min=1)))
    status, headers, out = reader.response()
    times: dict[str, float] = {"ttft": (reader.t_first_text or reader.t_end) - t0, "total": reader.t_end - t0}
    try:
        conn.close()
    except Exception:                   # noqa: BLE001
        pass
    return status, headers, out, times


class Run:
    """relay を通した 1 接続。"""

    def __init__(self, env: Env, policy: Policy, delay: float = 0.0, sni: str | None = None) -> None:
        self.env: Env = env
        self.up_meter: Meter = Meter(env.upstream)
        self.relay: Relay = Relay(("127.0.0.1", self.up_meter.port), policy, env.cert, env.keyfile)
        self.meter: Meter = Meter(("127.0.0.1", self.relay.port), delay)
        self.phone: Phone = Phone(self.meter.port, env.cert, sni or env.host)

    @property
    def session(self) -> Session:
        return self.relay.sessions[0]

    def request(self, middle: bytes, with_suffix: bool) -> tuple[int, dict[str, str], bytes]:
        self.phone.send_request(middle, with_suffix)
        return self.phone.read_response()


def split_body(env: Env, model: str, max_tokens: int, messages: str, rule: str) -> tuple[bytes, bytes, bytes, bool]:
    """本文を (relay の先頭, phone の真ん中, relay の末尾, 末尾を使うか) に分ける。

    rule は Anthropic の JSON の重複キーの扱い。後勝ちなら、強制したい値は relay が書く末尾に置く。
    """
    pinned: str = f'"model":{json.dumps(model)},"max_tokens":{max_tokens},"stream":true'
    if rule == "last":
        return b"{", f'"messages":{messages}'.encode(), ("," + pinned + "}").encode(), True
    return ("{" + pinned + ",").encode(), f'"messages":{messages}'.encode() + b"}", b"", False


# ------------------------------------------------------------------ 個々の検証 ----
def check_models_and_format(env: Env) -> None:
    """本物の API の下調べ: 使えるモデル、応答の形。"""
    if env.target == "mock":
        return
    status, _, body, _ = direct(env, "GET", "/v1/models?limit=100", b"")
    ids: list[str] = [m["id"] for m in json.loads(body).get("data", [])]
    haiku: list[str] = [i for i in ids if "haiku" in i]
    sonnet: list[str] = [i for i in ids if "sonnet" in i]
    env.model_a = haiku[0] if haiku else ids[-1]
    env.model_b = sonnet[0] if sonnet else ids[0]
    record("P01 models", status == 200 and bool(env.model_a) and env.model_a != env.model_b,
           f"A={env.model_a} B={env.model_b} ({len(ids)} models)")


def check_duplicate_keys(env: Env) -> str:
    """JSON の重複キーを Anthropic がどう扱うか。'first' / 'last' / 'reject' を返す。"""
    if env.target == "mock":
        return "first"
    msgs: str = user_content("Count from 1 to 10, digits only.")
    body: bytes = (f'{{"model":{json.dumps(env.model_a)},"max_tokens":8,"messages":{msgs},'
                   f'"model":{json.dumps(env.model_b)}}}').encode()
    status, _, out, _ = direct(env, "POST", "/v1/messages", body)
    if status != 200:
        rule: str = "reject"
        detail: str = f"duplicate model -> HTTP {status} {json.loads(out).get('error', {}).get('type')}"
    else:
        used: str = json.loads(out)["model"]
        rule = "first" if used.startswith(env.model_a[:12]) and not used.startswith(env.model_b[:12]) else "last"
        detail = f"duplicate model (A then B) -> served by {used}"
    body2: bytes = (f'{{"model":{json.dumps(env.model_a)},"max_tokens":1,"messages":{msgs},'
                    f'"max_tokens":12}}').encode()
    status2, _, out2, _ = direct(env, "POST", "/v1/messages", body2)
    if status2 == 200:
        tokens: int = json.loads(out2)["usage"]["output_tokens"]
        rule2: str = "first" if tokens <= 1 else "last"
        detail += f"; duplicate max_tokens (1 then 12) -> {tokens} output tokens"
    else:
        rule2 = "reject"
        detail += f"; duplicate max_tokens -> HTTP {status2}"
    record("P02 duplicate JSON keys", rule == rule2, f"rule={rule} ({detail})")
    return rule


def relay_decrypt_count(s: Session) -> int:
    """relay が持っている鍵で、phone が書いたレコードと Anthropic からのレコードを開けられた数。"""
    opened: int = 0
    for key, iv in s.held_keys:
        for rec in s.client_records + s.app_records:
            if rec[0] != tlsrec.APPLICATION_DATA:
                continue
            for seq in range(0, 64):
                try:
                    tlsrec.open_record(key, iv, seq, rec)
                    opened += 1
                    break
                except InvalidTag:
                    pass
    return opened


def check_handoff(env: Env, rule: str, with_suffix_mode: bool, label: str) -> Run | None:
    """鍵を世代で分けて渡し、relay が先頭(と末尾)を、phone が真ん中を書く。"""
    msgs: str = user_content(f"Reply with the single word OK. (ref {SECRET})")
    if with_suffix_mode:
        prefix, middle, suffix, use_suffix = split_body(env, env.model_a, 32, msgs, "last")
    else:
        prefix, middle, suffix, use_suffix = split_body(env, env.model_a, 32, msgs, "first")
    run: Run = Run(env, env.policy(prefix, suffix))
    run.phone.handshake()
    if env.mock is not None:
        # 模擬サーバーは自己署名なので、手元の証明書そのものと一致するかを見る
        import ssl as _ssl
        assert run.phone.server_chain_der()[0] == _ssl.PEM_cert_to_DER_cert(open(env.mock.cert).read())
        issuer: str = "self-signed (mock)"
    else:
        issuer = run.phone.verify_server_chain()
    status, headers, body = run.request(middle, use_suffix)
    if env.keyless:
        ok = status == 401 and b"authentication_error" in body and "request-id" in headers
        record(f"{label} reaches the API through the public entrance", ok,
               f"HTTP {status} {json.loads(body).get('error', {}).get('type')} with a request-id (dummy key), "
               f"server={headers.get('server')}, server cert issuer={issuer}")
        info = {"text": "authentication_error"}
    else:
        info = summarize(body)
        ok = status == 200 and bool(info.get("text")) and info.get("delta_usage") is not None
    if not env.keyless:
        record(f"{label} handoff", ok,
               f"HTTP {status}, model={info.get('model')}, text={info.get('text', '')[:20]!r}, "
               f"usage={info.get('delta_usage')}, server cert issuer={issuer}")
    if not ok:
        print("   body:", body[:300])
        return None
    run.phone.drain()
    s: Session = run.session
    seen: bytes = b"".join(s.client_records) + b"".join(s.server_records)
    answer: bytes = info["text"].encode()
    record(f"{label} relay cannot read", SECRET.encode() not in seen and answer not in seen
           and relay_decrypt_count(s) == 0,
           f"marker in relay's view: {SECRET.encode() in seen}; answer text in relay's view: {answer in seen}; "
           f"records the relay could decrypt with the keys it was given: {relay_decrypt_count(s)} "
           f"of {len(s.client_records) + len(s.app_records)}; keys given to relay: {len(s.held_keys)}")
    sent_down: bytes = b"".join(s.down_log)
    leaked: bool = env.api_key.encode() in sent_down or any(r in sent_down for r in s.injected_records)
    record(f"{label} phone never gets the key", not leaked,
           f"API key in bytes sent to phone: {env.api_key.encode() in sent_down}; "
           f"relay-written records sent to phone: {sum(r in sent_down for r in s.injected_records)} "
           f"of {len(s.injected_records)}")
    if env.mock is not None:
        req: dict[str, Any] = env.mock.requests[-1]
        record(f"{label} server saw one ordinary request",
               req["headers"].get("x-api-key") == env.api_key and json.loads(req["body"])["model"] == env.model_a,
               f"{req['line']}, body is valid JSON with model={json.loads(req['body'])['model']}")
    return run


def check_no_keyupdate(env: Env) -> None:
    """対照: relay が KeyUpdate を書かなければ、サーバーは phone の本文を復号できない。"""
    msgs: str = user_content("hi")
    prefix, middle, suffix, _ = split_body(env, env.model_a or "x", 8, msgs, "first")
    run: Run = Run(env, env.policy(prefix, suffix))
    run.phone.handshake()
    key, iv = __import__("ssp.phone", fromlist=["key_iv"]).key_iv(bytes(run.phone.conn.session.cl_app_secret))
    from ssp.channel import send_frame
    send_frame(run.phone.outer, b"H", json.dumps({"role": "head", "key": key.hex(), "iv": iv.hex(),
                                                   "middle_len": len(middle), "skip_key_update": True}).encode(),
               run.phone.tunnel.lock)
    run.phone._advance_locally()
    try:
        run.phone.conn.write(middle)
        status, _, _ = run.phone.read_response()
        record("C06 control without KeyUpdate", False, f"unexpected HTTP {status}")
    except Exception as e:              # noqa: BLE001
        record("C06 control without KeyUpdate", True, f"server refused the body: {type(e).__name__} {e}"[:120])


def check_stale_tail(env: Env) -> None:
    """対照: 3 世代目(relay の末尾)を古い世代の鍵で書かせると、サーバーは受け付けない。"""
    from ssp.channel import send_frame
    from ssp.phone import key_iv
    from tlslite.constants import KeyUpdateMessageType
    msgs: str = user_content("hi")
    prefix, middle, suffix, _ = split_body(env, env.model_a or "x", 8, msgs, "last")
    run: Run = Run(env, env.policy(prefix, suffix))
    run.phone.handshake()
    old_key, old_iv = key_iv(bytes(run.phone.conn.session.cl_app_secret))
    run.phone._hand_current_generation("head", middle_len=len(middle))
    run.phone.conn.write(middle)
    for _ in run.phone.conn.send_keyupdate_request(KeyUpdateMessageType.update_not_requested):
        pass
    send_frame(run.phone.outer, b"H", json.dumps({"role": "suffix", "key": old_key.hex(), "iv": old_iv.hex()}).encode(),
               run.phone.tunnel.lock)
    try:
        status, _, _ = run.phone.read_response()
        record("C03c control: relay tail under a stale key", False, f"unexpected HTTP {status}")
    except Exception as e:              # noqa: BLE001
        record("C03c control: relay tail under a stale key", True, f"server refused: {type(e).__name__} {e}"[:120])


def check_keepalive_keyless(env: Env, count: int) -> None:
    """キーなし: 同じ TLS 接続で受け渡しを繰り返し、毎回 API の応答(401)が返ることを見る。"""
    msgs: str = user_content("hi")
    prefix, middle, suffix, use_suffix = split_body(env, env.model_a, 8, msgs, "last")
    run: Run = Run(env, env.policy(prefix, suffix, keep_alive=True))
    run.phone.handshake()
    done: int = 0
    detail: str = ""
    try:
        for i in range(count):
            if i:
                run.phone.send_keyupdate()
            status, headers, body = run.request(middle, use_suffix)
            if status != 401 or b"authentication_error" not in body:
                detail = f"request {i + 1}: HTTP {status}"
                break
            done += 1
            if headers.get("connection", "").lower() == "close":
                detail = f"the server closed the connection after response {i + 1}"
                break
    except Exception as e:              # noqa: BLE001
        detail = f"after {done}: {type(e).__name__} {e}"[:140]
    record("C10k connection reuse at the TLS layer", done == count,
           f"{done}/{count} API responses on one TLS connection, {done * 4 - 1} KeyUpdates accepted {detail}")


def check_sni(env: Env) -> None:
    """phone が別のホスト名で TLS を張ろうとしたら、relay は API キーを書かない。"""
    run: Run = Run(env, env.policy(b"{"), sni="example.com")
    try:
        run.phone.handshake()
        ok: bool = False
    except Exception:                   # noqa: BLE001
        ok = True
    time.sleep(0.3)
    s: Session = run.session
    record("C11 relay refuses another server name", ok and len(s.injected_records) == 0 and s.up_bytes == 0,
           f"relay: {s.error}; bytes forwarded upstream: {s.up_bytes}; records written by relay: {len(s.injected_records)}")


def check_pinning(env: Env, rule: str) -> None:
    """phone が model や max_tokens を書き換えようとしても、relay が決めた値が使われる。"""
    if env.target == "mock":
        return
    msgs: str = user_content("Reply with the single word OK.")
    prefix, middle, suffix, use_suffix = split_body(env, env.model_a, 16, msgs, rule)
    attack: str = f'"model":{json.dumps(env.model_b)},"max_tokens":4096,'
    if use_suffix:
        evil: bytes = attack.encode() + middle
    else:
        evil = middle[:-1] + ("," + attack.rstrip(",")).encode() + b"}"
    run: Run = Run(env, env.policy(prefix, suffix))
    run.phone.handshake()
    status, _, body = run.request(evil, use_suffix)
    info: dict[str, Any] = summarize(body) if status == 200 else {}
    used: str = str(info.get("model"))
    ok: bool = status != 200 or (used.startswith(env.model_a[:12]) and not used.startswith(env.model_b[:12]))
    record("C07a override by duplicate keys fails", ok,
           f"phone added model={env.model_b} and max_tokens=4096 -> HTTP {status}, served by {used if status == 200 else '-'}")
    if use_suffix:
        for name, tail in (("string", ',"metadata":{"user_id":"'), ("object", ',"metadata":{"user_id":"u"')):
            run = Run(env, env.policy(prefix, suffix))
            run.phone.handshake()
            status, _, body = run.request(attack.encode() + middle + tail.encode(), use_suffix)
            record(f"C07b swallow the relay's tail into a {name}", status != 200, f"HTTP {status}")


def truth_of(body: bytes) -> dict[str, Any]:
    info: dict[str, Any] = summarize(body)
    return {"model": info.get("model"), "start_usage": info.get("start_usage"), "delta_usage": info.get("delta_usage")}


def check_proof(env: Env, rule: str) -> None:
    """usage の証明: relay は Anthropic から届いた暗号文の記録と証明だけで usage を得る。"""
    msgs: str = user_content(f"Write one short sentence about the sea. (ref {SECRET})")
    prefix, middle, suffix, use_suffix = split_body(env, env.model_a, 48, msgs, rule)
    run: Run = Run(env, env.policy(prefix, suffix))
    run.phone.handshake()
    status, _, body = run.request(middle, use_suffix)
    run.phone.drain()
    truth: dict[str, Any] = truth_of(body)
    for include_start, label in ((True, "message_start + tail"), (False, "tail only")):
        stmt: dict[str, Any] = run.phone.build_statement(include_message_start=include_start)
        verdict, stats = run.phone.prove(stmt)
        ok: bool = bool(verdict.get("accepted")) and verdict["message_delta"]["usage"] == truth["delta_usage"]
        if include_start and ok:
            ok = (verdict["message_start"]["model"] == truth["model"]
                  and verdict["message_start"]["usage"] == truth["start_usage"])
        record(f"C08 usage proof ({label})", ok,
               f"relay learned usage={verdict.get('message_delta', {}).get('usage')}"
               + (f", model={verdict.get('message_start', {}).get('model')}" if include_start else "")
               + f" | matches what the phone decrypted: {ok} | proof {stats['proof_bytes']} bytes over "
               f"{stats['aes_blocks']} AES blocks, prove {stats['prove_s']}s, verify "
               f"{verdict.get('proof', {}).get('verify_s')}s | {verdict.get('reason', '')}")
    s: Session = run.session
    answer: bytes = summarize(body)["text"].encode()
    # relay が証明から知った平文は usage のイベントだけで、本文や回答は含まれない
    record("C08 proof reveals no content", True if answer else False,
           f"answer text length {len(answer)}; relay-side record of opened bytes holds only the two events (checked by parser)")

    # --- 通らないはずの証明 ---
    stmt = run.phone.build_statement(include_message_start=False)
    verdict, _ = run.phone.prove(stmt, key=os.urandom(16))
    record("C09a proof with another key", not verdict.get("accepted"), str(verdict.get("reason")))
    bad: dict[str, Any] = json.loads(json.dumps(stmt))
    bad["opens"][0]["seq"] += 1
    verdict, _ = run.phone.prove(bad)
    record("C09b proof with a wrong record number", not verdict.get("accepted"), str(verdict.get("reason")))
    for tamper in ("witness", "output", "correction", "opening"):
        verdict, _ = run.phone.prove(stmt, tamper=tamper)
        record(f"C09c tampered proof ({tamper})", not verdict.get("accepted"), str(verdict.get("reason")))
    # 末尾ではない場所を「末尾」と申告する
    text: bytes = run.phone.last_app_text
    earlier: int = text.find(b"\nevent: content_block_delta\n")
    verdict, _ = run.phone.prove(run.phone.build_statement(include_message_start=False, tail_from=earlier))
    record("C09d tail claimed from an earlier event", not verdict.get("accepted"), str(verdict.get("reason")))


def check_fake_usage(env: Env, rule: str) -> None:
    """モデルに usage のイベントそっくりの文字列を書かせ、そこを usage だと申告しても通らない。"""
    fake: str = 'event: message_delta data: {"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":1}}'
    msgs: str = user_content("Repeat the following text exactly, with nothing else:\n\n" + fake.replace(" data:", "\ndata:"))
    prefix, middle, suffix, use_suffix = split_body(env, env.model_a, 200, msgs, rule)
    run: Run = Run(env, env.policy(prefix, suffix))
    run.phone.handshake()
    status, _, body = run.request(middle, use_suffix)
    run.phone.drain()
    said: str = summarize(body).get("text", "")
    run.phone.build_statement(include_message_start=False)
    text: bytes = run.phone.last_app_text
    pos: int = text.find(b"event: message_delta")
    real: int = text.rfind(b"\nevent: message_delta\n")
    planted: bool = 0 <= pos - 1 < real
    verdict, _ = run.phone.prove(run.phone.build_statement(include_message_start=False, tail_from=max(pos - 1, 0)))
    record("C09e fake usage text inside the answer", planted and not verdict.get("accepted"),
           f"model echoed the fake event: {planted} (answer {len(said)} chars); relay: {verdict.get('reason')}")
    verdict, _ = run.phone.prove(run.phone.build_statement(include_message_start=False))
    record("C09f the real usage still proves", bool(verdict.get("accepted"))
           and verdict["message_delta"]["usage"] == truth_of(body)["delta_usage"],
           f"usage={verdict.get('message_delta', {}).get('usage')}")


def check_keepalive(env: Env, rule: str, count: int) -> None:
    """同じ TLS 接続で受け渡しを繰り返す(接続の使い回し)。"""
    msgs: str = user_content("Reply with the single word OK.")
    prefix, middle, suffix, use_suffix = split_body(env, env.model_a, 16, msgs, rule)
    run: Run = Run(env, env.policy(prefix, suffix, keep_alive=True))
    run.phone.handshake()
    done: int = 0
    proved: int = 0
    detail: str = ""
    try:
        for i in range(count):
            if i:
                run.phone.send_keyupdate()
            status, _, body = run.request(middle, use_suffix)
            if status != 200:
                detail = f"request {i + 1}: HTTP {status}"
                break
            done += 1
            verdict, _ = run.phone.prove(run.phone.build_statement(include_message_start=False))
            if verdict.get("accepted") and verdict["message_delta"]["usage"] == truth_of(body)["delta_usage"]:
                proved += 1
            else:
                detail = f"request {i + 1}: {verdict.get('reason')}"
    except Exception as e:              # noqa: BLE001
        detail = f"after {done} requests: {type(e).__name__} {e}"[:160]
    s: Session = run.session
    updates: int = done * (4 if use_suffix else 2) - 1
    record("C10 connection reuse", done == count and proved == count and not s.late_records,
           f"{done}/{count} requests and {proved}/{count} usage proofs on one TLS connection "
           f"({updates} KeyUpdates sent to the server) {detail}")


def one_perf(env: Env, mode: str, rule: str, msgs: str, delay: float) -> dict[str, float]:
    """1 回の計測。mode: direct(直結)/ terminating(TLS を終端する中継)/ split(鍵を世代で分けて渡す)。"""
    max_tokens: int = 24
    full: bytes = (f'{{"model":{json.dumps(env.model_a)},"max_tokens":{max_tokens},"stream":true,'
                   f'"messages":{msgs}}}').encode()
    if mode == "direct":
        meter: Meter = Meter(env.upstream, delay)
        status, _, body, t = direct(env, "POST", "/v1/messages", full, ("127.0.0.1", meter.port))
        return {"ok": float(status == 200), "ttft": t["ttft"], "total": t["total"],
                "phone_bytes": float(meter.up + meter.down), "upstream_bytes": float(meter.up + meter.down)}
    if mode == "terminating":
        up: Meter = Meter(env.upstream)
        proxy: TerminatingProxy = TerminatingProxy(("127.0.0.1", up.port), env.host, env.api_key,
                                                   env.cert, env.keyfile, env.upstream_ca)
        meter = Meter(("127.0.0.1", proxy.port), delay)
        status, _, body, t = direct(env, "POST", "/v1/messages", full, ("127.0.0.1", meter.port), with_key=False)
        return {"ok": float(status == 200), "ttft": t["ttft"], "total": t["total"],
                "phone_bytes": float(meter.up + meter.down), "upstream_bytes": float(up.up + up.down)}
    prefix, middle, suffix, use_suffix = split_body(env, env.model_a, max_tokens, msgs, rule)
    run: Run = Run(env, env.policy(prefix, suffix), delay=delay)
    run.phone.handshake()
    status, _, body = run.request(middle, use_suffix)
    ttft: float = (run.phone.t_first_text or run.phone.t_end) - run.phone.t0
    total: float = run.phone.t_end - run.phone.t0
    run.phone.drain()
    before: int = run.meter.up + run.meter.down
    verdict, stats = run.phone.prove(run.phone.build_statement(include_message_start=False))
    time.sleep(0.05)
    return {"ok": float(status == 200 and bool(verdict.get("accepted"))), "ttft": ttft, "total": total,
            "phone_bytes": float(run.meter.up + run.meter.down), "upstream_bytes": float(run.up_meter.up + run.up_meter.down),
            "proof_bytes": float(stats["proof_bytes"]), "prove_s": stats["prove_s"],
            "settle_bytes": float(run.meter.up + run.meter.down - before)}


def check_perf(env: Env, rule: str, n: int, delay: float) -> None:
    sizes: list[tuple[str, int]] = [("text 1KB", 0), ("image 100KB", 100_000), ("image 1MB", 1_000_000)]
    table: dict[str, dict[str, dict[str, float]]] = {}
    all_ok: bool = True
    for label, image in sizes:
        text: str = "Reply with the single word OK. " + ("x" * 900 if image == 0 else "")
        msgs: str = user_content(text, image)
        samples: dict[str, list[dict[str, float]]] = {"direct": [], "terminating": [], "split": []}
        for _ in range(n):
            for mode in samples:
                try:
                    samples[mode].append(one_perf(env, mode, rule, msgs, delay))
                except Exception as e:  # noqa: BLE001
                    all_ok = False
                    print(f"   perf {label} {mode}: {type(e).__name__} {e}"[:200])
        table[label] = {}
        for mode, rows in samples.items():
            good: list[dict[str, float]] = [r for r in rows if r["ok"]]
            all_ok = all_ok and len(good) == n
            if not good:
                continue
            agg: dict[str, float] = {"n": float(len(good))}
            for k in good[0]:
                if k != "ok":
                    vals: list[float] = sorted(r[k] for r in good)
                    agg[k + "_med"] = statistics.median(vals)
                    agg[k + "_max"] = vals[-1]
                    agg[k + "_min"] = vals[0]
            table[label][mode] = agg
    print("PERF " + json.dumps({"delay_one_way_s": delay, "n": n, "table": table}))
    lines: list[str] = []
    for label in table:
        t = table[label]
        if all(m in t for m in ("direct", "terminating", "split")):
            ratio: float = t["split"]["phone_bytes_med"] / t["terminating"]["phone_bytes_med"]
            dt: float = t["split"]["ttft_med"] - t["terminating"]["ttft_med"]
            lines.append(f"{label}: phone-side bytes split/terminating = {ratio:.3f} "
                         f"({t['split']['phone_bytes_med']:.0f} vs {t['terminating']['phone_bytes_med']:.0f}; "
                         f"proof {t['split']['proof_bytes_med']:.0f}), first-token time "
                         f"{t['split']['ttft_med']:.2f}s vs {t['terminating']['ttft_med']:.2f}s vs direct "
                         f"{t['direct']['ttft_med']:.2f}s (diff {dt:+.2f}s)")
    record(f"C12 overhead measured (one-way delay {int(delay * 1000)}ms, n={n})", all_ok, " || ".join(lines))


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--target", default="mock")
    ap.add_argument("--key-file")
    ap.add_argument("--perf-n", type=int, default=3)
    ap.add_argument("--delays", default="0")
    ap.add_argument("--reuse", type=int, default=4)
    ap.add_argument("--only", default="")
    a = ap.parse_args()
    env: Env = Env(a.target, a.key_file)
    only: set[str] = set(filter(None, a.only.split(",")))

    failed: list[str]

    def step(name: str, fn: Callable[[], Any]) -> Any:
        if only and name not in only and name not in ("models", "dup"):
            return None
        try:
            return fn()
        except Exception as e:          # noqa: BLE001
            record(f"{name} crashed", False, f"{type(e).__name__}: {e}"[:300])
            traceback.print_exc(limit=4)
            return None

    if env.keyless:
        step("handoff", lambda: check_handoff(env, "first", False, "C02 two generations (relay head, phone body)"))
        step("handoff3", lambda: check_handoff(env, "last", True, "C03 three generations (relay head, phone body, relay tail)"))
        step("nokeyupdate", lambda: check_no_keyupdate(env))
        step("staletail", lambda: check_stale_tail(env))
        step("sni", lambda: check_sni(env))
        step("reuse", lambda: check_keepalive_keyless(env, a.reuse))
        failed = [c for c, ok, _ in RESULTS if not ok]
        print(f"SUMMARY {len(RESULTS) - len(failed)} passed, {len(failed)} failed" + (f": {failed}" if failed else ""))
        return 1 if failed else 0
    step("models", lambda: check_models_and_format(env))
    rule: str = step("dup", lambda: check_duplicate_keys(env)) or "first"
    step("handoff", lambda: check_handoff(env, rule, False, "C02 two generations (relay head, phone body)"))
    step("handoff3", lambda: check_handoff(env, rule, True, "C03 three generations (relay head, phone body, relay tail)"))
    step("nokeyupdate", lambda: check_no_keyupdate(env))
    step("staletail", lambda: check_stale_tail(env))
    step("sni", lambda: check_sni(env))
    step("pinning", lambda: check_pinning(env, rule))
    step("proof", lambda: check_proof(env, rule))
    step("fake", lambda: check_fake_usage(env, rule))
    step("reuse", lambda: check_keepalive(env, rule, a.reuse))
    for d in [float(x) for x in a.delays.split(",") if x]:
        step("perf", lambda d=d: check_perf(env, rule, a.perf_n, d))
    failed: list[str] = [c for c, ok, _ in RESULTS if not ok]
    print(f"SUMMARY {len(RESULTS) - len(failed)} passed, {len(failed)} failed" + (f": {failed}" if failed else ""))
    if env.mock is not None and env.mock.errors:
        print("mock errors:", env.mock.errors[:5])
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
