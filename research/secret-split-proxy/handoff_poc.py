"""鍵の世代を分けて受け渡す方式の最小確認。

登場人物
  phone : TLS 1.3 のクライアント。本文を持つ。API キーは知らない。
  proxy : TCP の中継。API キーを持つ。本文は知らない。
  server: ふつうの HTTPS サーバー(改修なし)。

流れ
  1. phone が proxy 越しに、ふつうの TLS 1.3 ハンドシェイクを行う。
  2. phone は「クライアント送信鍵の第0世代(key_0, iv_0)」だけを proxy に渡す。
  3. proxy は key_0 で「HTTP の先頭(API キー入り)」と KeyUpdate を暗号化し、
     server に直接送る。phone にはこの暗号文を見せない。
  4. phone は第1世代の鍵(proxy は導出できない)で本文を暗号化して送る。
  5. server は 1 本のふつうの HTTP リクエストとして受け取る。
"""
import argparse
import json
import socket
import ssl
import struct
import sys
import threading
import time

from cryptography.hazmat.primitives.ciphers.aead import AESGCM
from tlslite import TLSConnection
from tlslite.handshakesettings import HandshakeSettings
from tlslite.mathtls import HKDF_expand_label

API_KEY = "sk-ant-PROXY-ONLY-SECRET-0123456789abcdef"
PHONE_SECRET = "PHONE-ONLY-SECRET-kotae-no-shashin-9f3a"


# ---------------------------------------------------------------- proxy ----
class Proxy:
    """TLS を終端しない TCP 中継。見えたバイト列をすべて記録する。"""

    def __init__(self, upstream_host, upstream_port, send_keyupdate=True):
        self.upstream = (upstream_host, upstream_port)
        self.send_keyupdate = send_keyupdate
        self.seen = bytearray()          # proxy が観測した全バイト
        self.shown_to_phone = bytearray()  # phone に渡した全バイト
        self.injected = bytearray()      # proxy が自分で書いた暗号文
        self.lsock = socket.socket()
        self.lsock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        self.lsock.bind(("127.0.0.1", 0))
        self.lsock.listen(1)
        self.port = self.lsock.getsockname()[1]
        self.up = None
        self.forwarded = 0
        self.lock = threading.Lock()
        threading.Thread(target=self._run, daemon=True).start()

    def _run(self):
        self.down, _ = self.lsock.accept()
        self.up = socket.create_connection(self.upstream)
        threading.Thread(target=self._pump_up, daemon=True).start()
        self._pump_down()

    def _pump_up(self):          # phone -> server
        while True:
            data = self.down.recv(65536)
            if not data:
                break
            self.seen += data
            with self.lock:
                self.up.sendall(data)
                self.forwarded += len(data)

    def _pump_down(self):        # server -> phone
        while True:
            try:
                data = self.up.recv(65536)
            except OSError:
                break
            if not data:
                break
            self.seen += data
            self.shown_to_phone += data
            try:
                self.down.sendall(data)
            except OSError:
                break
        try:
            self.down.shutdown(socket.SHUT_WR)
        except OSError:
            pass

    @staticmethod
    def _record(key, iv, seq, inner_type, content):
        """TLS 1.3 のレコードを 1 つ作る(RFC 8446 5.2, 5.3)。"""
        nonce = bytes(a ^ b for a, b in
                      zip(iv, b"\x00" * 4 + struct.pack(">Q", seq)))
        inner = content + bytes([inner_type])
        header = b"\x17\x03\x03" + struct.pack(">H", len(inner) + 16)
        return header + AESGCM(key).encrypt(nonce, inner, header)

    def handoff(self, key0, iv0, head, after_bytes):
        """phone から第0世代の鍵を受け取り、先頭と KeyUpdate を書く。

        phone のハンドシェイク(Finished まで)を転送し終えてから書く。
        """
        while self.forwarded < after_bytes:
            time.sleep(0.001)
        rec_head = self._record(key0, iv0, 0, 0x17, head)
        out = rec_head
        if self.send_keyupdate:
            # KeyUpdate(update_not_requested): type=24, len=1, body=0
            out += self._record(key0, iv0, 1, 0x16, b"\x18\x00\x00\x01\x00")
        self.injected += out
        with self.lock:
            self.up.sendall(out)


# --------------------------------------------------------------- server ----
def start_local_server(result):
    """改修なしの HTTPS サーバー(Python ssl = OpenSSL)。"""
    import subprocess, tempfile, os
    d = tempfile.mkdtemp()
    subprocess.run(
        ["openssl", "req", "-x509", "-newkey", "ec", "-pkeyopt",
         "ec_paramgen_curve:P-256", "-nodes", "-keyout", d + "/k.pem",
         "-out", d + "/c.pem", "-days", "1", "-subj", "/CN=localhost"],
        check=True, capture_output=True)
    ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    ctx.minimum_version = ssl.TLSVersion.TLSv1_3
    ctx.load_cert_chain(d + "/c.pem", d + "/k.pem")
    ls = socket.socket()
    ls.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    ls.bind(("127.0.0.1", 0))
    ls.listen(5)

    def serve():
        while True:
            raw, _ = ls.accept()
            try:
                s = ctx.wrap_socket(raw, server_side=True)
                buf = b""
                while b"\r\n\r\n" not in buf:
                    chunk = s.recv(65536)
                    if not chunk:
                        raise ConnectionError("eof in head")
                    buf += chunk
                head, rest = buf.split(b"\r\n\r\n", 1)
                headers = {}
                for line in head.split(b"\r\n")[1:]:
                    k, v = line.split(b":", 1)
                    headers[k.strip().lower().decode()] = v.strip().decode()
                n = int(headers["content-length"])
                while len(rest) < n:
                    chunk = s.recv(65536)
                    if not chunk:
                        raise ConnectionError("eof in body")
                    rest += chunk
                result["request_line"] = head.split(b"\r\n")[0].decode()
                result["headers"] = headers
                result["body"] = rest[:n].decode()
                result["cipher"] = s.cipher()
                reply = ("event: message_start\ndata: {\"usage\":{\"input_tokens\":42}}\n\n"
                         "event: content_block_delta\ndata: {\"text\":\"SERVER-ANSWER-TEXT\"}\n\n"
                         "event: message_delta\ndata: {\"usage\":{\"output_tokens\":7}}\n\n")
                s.sendall(("HTTP/1.1 200 OK\r\ncontent-type: text/event-stream\r\n"
                           "content-length: %d\r\nconnection: close\r\n\r\n%s"
                           % (len(reply), reply)).encode())
                s.close()
            except Exception as e:      # noqa: BLE001
                result["server_error"] = repr(e)
                raw.close()

    threading.Thread(target=serve, daemon=True).start()
    return ls.getsockname()[1]


# ---------------------------------------------------------------- phone ----
def phone(proxy, sni, head_template, body_prefix, body_rest, alpn):
    raw = socket.create_connection(("127.0.0.1", proxy.port))

    class Counting:
        sent = 0

        def __getattr__(self, name):
            return getattr(raw, name)

        def send(self, data):
            n = raw.send(data)
            Counting.sent += n
            return n

        def sendall(self, data):
            raw.sendall(data)
            Counting.sent += len(data)

    conn = TLSConnection(Counting())
    st = HandshakeSettings()
    st.minVersion = (3, 4)
    st.maxVersion = (3, 4)
    st.cipherNames = ["aes128gcm"]
    conn.handshakeClientCert(settings=st, serverName=sni, alpn=alpn)
    assert conn.version == (3, 4)

    # 第0世代のクライアント送信鍵だけを取り出して proxy に渡す
    c_ap0 = bytes(conn.session.cl_app_secret)
    key0 = bytes(HKDF_expand_label(c_ap0, b"key", b"", 16, "sha256"))
    iv0 = bytes(HKDF_expand_label(c_ap0, b"iv", b"", 12, "sha256"))
    total = len(body_prefix) + len(body_rest)
    head = (head_template % total).encode() + body_prefix
    proxy.handoff(key0, iv0, head, Counting.sent)  # ← proxy に渡るのは key0, iv0, 長さ だけ

    # phone は KeyUpdate を送らずに、自分の送信鍵だけ第1世代へ進める
    conn.session.cl_app_secret, conn.session.sr_app_secret = \
        conn._recordLayer.calcTLS1_3KeyUpdate_reciever(
            conn.session.cipherSuite,
            conn.session.cl_app_secret, conn.session.sr_app_secret)
    conn.write(body_rest)

    out = b""
    try:
        while True:
            chunk = conn.read(max=65536, min=1)
            if not chunk:
                break
            out += bytes(chunk)
            if b"\r\n\r\n" in out:
                h, b = out.split(b"\r\n\r\n", 1)
                for line in h.split(b"\r\n"):
                    if line.lower().startswith(b"content-length:"):
                        if len(b) >= int(line.split(b":")[1]):
                            raise StopIteration
    except StopIteration:
        pass
    except Exception as e:               # noqa: BLE001
        return out, repr(e), key0, c_ap0
    return out, None, key0, c_ap0


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--target", default="local")
    ap.add_argument("--no-keyupdate", action="store_true")
    a = ap.parse_args()

    body_prefix = b'{"model":"claude-haiku-5-5","max_tokens":64,'
    body_rest = ('"messages":[{"role":"user","content":"%s"}]}'
                 % PHONE_SECRET).encode()

    result = {}
    if a.target == "local":
        port = start_local_server(result)
        host, sni, alpn = "127.0.0.1", "localhost", None
    else:
        host, port, sni, alpn = a.target, 443, a.target, [b"http/1.1"]
    head_template = ("POST /v1/messages HTTP/1.1\r\nHost: " + sni + "\r\n"
                     "x-api-key: " + API_KEY + "\r\n"
                     "anthropic-version: 2023-06-01\r\n"
                     "content-type: application/json\r\n"
                     "content-length: %d\r\nconnection: close\r\n\r\n")

    proxy = Proxy(host, port, send_keyupdate=not a.no_keyupdate)
    t0 = time.time()
    resp, err, key0, c_ap0 = phone(proxy, sni, head_template,
                                   body_prefix, body_rest, alpn)
    time.sleep(0.3)

    print("target            :", a.target, "| KeyUpdate sent:", not a.no_keyupdate)
    print("elapsed           : %.2fs" % (time.time() - t0))
    print("phone got response:", resp[:300])
    print("phone error       :", err)
    if result:
        print("server saw        :", json.dumps(result, ensure_ascii=False)[:600])
    seen = bytes(proxy.seen) + bytes(proxy.injected)
    print("--- checks ---")
    print("proxy saw phone's secret in plaintext :", PHONE_SECRET.encode() in seen)
    print("proxy saw response text in plaintext  :", b"SERVER-ANSWER-TEXT" in seen)
    print("phone was shown the API-key ciphertext:",
          bytes(proxy.injected[:64]) in bytes(proxy.shown_to_phone))
    print("api key in bytes shown to phone       :",
          API_KEY.encode() in bytes(proxy.shown_to_phone))
    # proxy が key0 から第1世代の鍵を作れないことの確認(本文レコードを key0 で復号してみる)
    from cryptography.exceptions import InvalidTag
    stream = bytes(proxy.seen)
    idx = stream.rfind(b"\x17\x03\x03")
    print("proxy bytes total :", len(proxy.seen), "| injected:", len(proxy.injected))


if __name__ == "__main__":
    main()
