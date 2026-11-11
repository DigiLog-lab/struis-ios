"""手元で動かすための、Anthropic の Messages API に似せた HTTPS サーバー(OpenSSL、改修なし)。"""
from __future__ import annotations

import json
import os
import socket
import ssl
import subprocess
import tempfile
import threading
import time
from typing import Any


def self_signed(cn: str = "localhost") -> tuple[str, str]:
    d: str = tempfile.mkdtemp()
    subprocess.run(["openssl", "req", "-x509", "-newkey", "ec", "-pkeyopt", "ec_paramgen_curve:P-256",
                    "-nodes", "-keyout", d + "/k.pem", "-out", d + "/c.pem", "-days", "2",
                    "-subj", f"/CN={cn}", "-addext", f"subjectAltName=DNS:{cn}"],
                   check=True, capture_output=True)
    return d + "/c.pem", d + "/k.pem"


class MockAnthropic:
    def __init__(self) -> None:
        self.cert, self.key = self_signed()
        self.ctx: ssl.SSLContext = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        self.ctx.minimum_version = ssl.TLSVersion.TLSv1_3
        self.ctx.load_cert_chain(self.cert, self.key)
        self.ctx.set_alpn_protocols(["http/1.1"])
        self.requests: list[dict[str, Any]] = []
        self.errors: list[str] = []
        self.ls: socket.socket = socket.socket()
        self.ls.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        self.ls.bind(("127.0.0.1", 0))
        self.ls.listen(8)
        self.port: int = self.ls.getsockname()[1]
        threading.Thread(target=self._accept, daemon=True).start()

    def _accept(self) -> None:
        while True:
            raw, _ = self.ls.accept()
            threading.Thread(target=self._serve, args=(raw,), daemon=True).start()

    def _serve(self, raw: socket.socket) -> None:
        try:
            s: ssl.SSLSocket = self.ctx.wrap_socket(raw, server_side=True)
            buf: bytes = b""
            while True:
                while b"\r\n\r\n" not in buf:
                    chunk: bytes = s.recv(65536)
                    if not chunk:
                        return
                    buf += chunk
                head, rest = buf.split(b"\r\n\r\n", 1)
                headers: dict[str, str] = {}
                for line in head.split(b"\r\n")[1:]:
                    k, v = line.split(b":", 1)
                    headers[k.strip().lower().decode()] = v.strip().decode()
                n: int = int(headers.get("content-length", "0"))
                while len(rest) < n:
                    chunk = s.recv(65536)
                    if not chunk:
                        return
                    rest += chunk
                body, buf = rest[:n], rest[n:]
                self.requests.append({"line": head.split(b"\r\n")[0].decode(), "headers": headers,
                                      "body": body.decode()})
                parsed: dict[str, Any] = json.loads(body)
                content: Any = parsed["messages"][-1]["content"]
                said: str = content if isinstance(content, str) else str(content[-1].get("text", ""))
                events: list[str] = [
                    'event: message_start\ndata: ' + json.dumps({"type": "message_start", "message": {
                        "id": "msg_mock", "type": "message", "role": "assistant", "content": [],
                        "model": parsed["model"], "stop_reason": None,
                        "usage": {"input_tokens": 42, "output_tokens": 1}}}) + "\n\n",
                    'event: content_block_start\ndata: {"type":"content_block_start","index":0}\n\n',
                ]
                for word in ("MOCK-ANSWER", "to:", said[-150:]):
                    events.append('event: content_block_delta\ndata: ' + json.dumps(
                        {"type": "content_block_delta", "index": 0,
                         "delta": {"type": "text_delta", "text": word + " "}}) + "\n\n")
                events.append('event: content_block_stop\ndata: {"type":"content_block_stop","index":0}\n\n')
                events.append('event: message_delta\ndata: ' + json.dumps(
                    {"type": "message_delta", "delta": {"stop_reason": "end_turn", "stop_sequence": None},
                     "usage": {"input_tokens": 42, "output_tokens": 7}}) + "\n\n")
                events.append('event: message_stop\ndata: {"type":"message_stop"}\n\n')
                close: bool = headers.get("connection", "").lower() == "close"
                s.sendall(b"HTTP/1.1 200 OK\r\ncontent-type: text/event-stream\r\n"
                          b"transfer-encoding: chunked\r\n" + (b"connection: close\r\n" if close else b"") + b"\r\n")
                for e in events:
                    data: bytes = e.encode()
                    s.sendall(b"%x\r\n" % len(data) + data + b"\r\n")
                    time.sleep(0.01)
                s.sendall(b"0\r\n\r\n")
                if close:
                    s.close()
                    return
        except Exception as e:          # noqa: BLE001
            self.errors.append(repr(e))
            try:
                raw.close()
            except OSError:
                pass
