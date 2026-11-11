"""検証で使う小物: HTTP の応答の読み取り、SSE の分解、比較用の経路(直結・TLS を終端する中継)。"""
from __future__ import annotations

import base64
import json
import os
import socket
import ssl
import struct
import threading
import time
import zlib
from typing import Any, Callable


class HttpReader:
    """read() で届くバイト列から HTTP/1.1 の応答を 1 つずつ取り出す。"""

    def __init__(self, read: Callable[[], bytes]) -> None:
        self.read: Callable[[], bytes] = read
        self.buf: bytearray = bytearray()
        self.t_first_text: float | None = None
        self.t_end: float = 0.0

    def _more(self) -> bool:
        try:
            chunk: bytes = self.read()
        except Exception:               # noqa: BLE001  接続の終わり
            return False
        if not chunk:
            return False
        self.buf.extend(chunk)
        if self.t_first_text is None and b"content_block_delta" in self.buf:
            self.t_first_text = time.time()
        return True

    def response(self) -> tuple[int, dict[str, str], bytes]:
        buf: bytearray = self.buf
        while b"\r\n\r\n" not in buf:
            if not self._more():
                raise ConnectionError(f"connection ended before the response head ({len(buf)} bytes)")
        head, _, rest = bytes(buf).partition(b"\r\n\r\n")
        lines: list[bytes] = head.split(b"\r\n")
        status: int = int(lines[0].split()[1])
        headers: dict[str, str] = {}
        for line in lines[1:]:
            k, _, v = line.partition(b":")
            headers[k.strip().lower().decode()] = v.strip().decode()
        buf[:] = rest
        body: bytearray = bytearray()
        if headers.get("transfer-encoding", "").lower() == "chunked":
            while True:
                while b"\r\n" not in buf:
                    if not self._more():
                        raise ConnectionError("connection ended inside a chunk header")
                size_line, _, after = bytes(buf).partition(b"\r\n")
                size: int = int(size_line.split(b";")[0], 16)
                buf[:] = after
                while len(buf) < size + 2:
                    if not self._more():
                        raise ConnectionError("connection ended inside a chunk")
                body += buf[:size]
                del buf[:size + 2]
                if size == 0:
                    break
        elif "content-length" in headers:
            n: int = int(headers["content-length"])
            while len(buf) < n:
                if not self._more():
                    raise ConnectionError("connection ended inside the body")
            body += buf[:n]
            del buf[:n]
        else:
            while self._more():
                pass
            body += buf
            buf.clear()
        self.t_end = time.time()
        return status, headers, bytes(body)


def sse_events(body: bytes) -> list[tuple[str, dict[str, Any]]]:
    out: list[tuple[str, dict[str, Any]]] = []
    for chunk in body.decode("utf-8", "replace").split("\n\n"):
        name: str = ""
        data: str = ""
        for line in chunk.split("\n"):
            if line.startswith("event: "):
                name = line[7:]
            elif line.startswith("data: "):
                data = line[6:]
        if name and data:
            out.append((name, json.loads(data)))
    return out


def summarize(body: bytes) -> dict[str, Any]:
    """SSE の本文から、モデル名・usage・生成された文章を取り出す(phone が見ている正解)。"""
    info: dict[str, Any] = {"text": ""}
    for name, data in sse_events(body):
        if name == "message_start":
            info["model"] = data["message"].get("model")
            info["start_usage"] = data["message"].get("usage")
        elif name == "content_block_delta" and data.get("delta", {}).get("type") == "text_delta":
            info["text"] += data["delta"]["text"]
        elif name == "message_delta":
            info["delta_usage"] = data.get("usage")
            info["stop_reason"] = data.get("delta", {}).get("stop_reason")
        elif name == "error":
            info["error"] = data
    return info


def noise_png(target_bytes: int) -> bytes:
    """指定の大きさに近い、圧縮の効かない PNG(答案の写真の代わり)。"""
    side: int = max(8, int((target_bytes / 3) ** 0.5))
    raw: bytes = b"".join(b"\x00" + os.urandom(side * 3) for _ in range(side))

    def chunk(tag: bytes, data: bytes) -> bytes:
        return struct.pack(">I", len(data)) + tag + data + struct.pack(">I", zlib.crc32(tag + data))

    return (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", side, side, 8, 2, 0, 0, 0))
            + chunk(b"IDAT", zlib.compress(raw, 1)) + chunk(b"IEND", b""))


def user_content(text: str, image_bytes: int = 0) -> str:
    """messages の中身(JSON の断片)。image_bytes > 0 なら画像を1枚付ける。"""
    if image_bytes <= 0:
        return json.dumps([{"role": "user", "content": text}])
    png: bytes = noise_png(image_bytes)
    return json.dumps([{"role": "user", "content": [
        {"type": "image", "source": {"type": "base64", "media_type": "image/png",
                                     "data": base64.b64encode(png).decode()}},
        {"type": "text", "text": text}]}])


class TerminatingProxy:
    """比較用: TLS を終端し、API キーを足して転送する、ふつうの中継。本文も応答も平文で見える。"""

    def __init__(self, upstream: tuple[str, int], host: str, api_key: str, certfile: str, keyfile: str,
                 upstream_ca: str | None) -> None:
        self.upstream: tuple[str, int] = upstream
        self.host: str = host
        self.api_key: str = api_key
        self.ctx: ssl.SSLContext = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        self.ctx.load_cert_chain(certfile, keyfile)
        self.up_ctx: ssl.SSLContext = ssl.create_default_context(cafile=upstream_ca)
        self.lsock: socket.socket = socket.socket()
        self.lsock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        self.lsock.bind(("127.0.0.1", 0))
        self.lsock.listen(8)
        self.port: int = self.lsock.getsockname()[1]
        threading.Thread(target=self._accept, daemon=True).start()

    def _accept(self) -> None:
        while True:
            try:
                raw, _ = self.lsock.accept()
            except OSError:
                return
            threading.Thread(target=self._serve, args=(raw,), daemon=True).start()

    def _serve(self, raw: socket.socket) -> None:
        try:
            raw.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
            down: ssl.SSLSocket = self.ctx.wrap_socket(raw, server_side=True)
            buf: bytes = b""
            while b"\r\n\r\n" not in buf:
                buf += down.recv(65536)
            head, rest = buf.split(b"\r\n\r\n", 1)
            n: int = 0
            for line in head.split(b"\r\n")[1:]:
                if line.lower().startswith(b"content-length:"):
                    n = int(line.split(b":")[1])
            while len(rest) < n:
                rest += down.recv(65536)
            up: ssl.SSLSocket = self.up_ctx.wrap_socket(socket.create_connection(self.upstream),
                                                        server_hostname=self.host)
            up.sendall(head + b"\r\nx-api-key: " + self.api_key.encode() + b"\r\n\r\n" + rest)
            while True:
                data: bytes = up.recv(65536)
                if not data:
                    break
                down.sendall(data)
            down.close()
        except (OSError, ssl.SSLError):
            pass
