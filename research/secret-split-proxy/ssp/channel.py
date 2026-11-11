"""phone と relay の間の経路。外側は TLS、内側は「種類1バイト + 長さ4バイト + 中身」の枠。

種類:
  D  内側の TLS(phone と Anthropic の間)のバイト列。relay は中身を読めない。
  H  phone → relay: 鍵の受け渡し(JSON)。
  A  relay → phone: H への返事(JSON)。
  P  phone → relay: usage の証明の申告(JSON)。
  R  relay → phone: 証明の判定(JSON)。
  E  relay → phone: Anthropic 側が接続を閉じた。
"""
from __future__ import annotations

import json
import queue
import socket
import struct
import threading
from typing import Any


def send_frame(sock: socket.socket, kind: bytes, payload: bytes, lock: threading.Lock | None = None) -> None:
    data: bytes = kind + struct.pack(">I", len(payload)) + payload
    if lock is None:
        sock.sendall(data)
    else:
        with lock:
            sock.sendall(data)


def recv_exact(sock: socket.socket, n: int) -> bytes:
    buf: bytearray = bytearray()
    while len(buf) < n:
        chunk: bytes = sock.recv(n - len(buf))
        if not chunk:
            raise ConnectionError("channel closed")
        buf += chunk
    return bytes(buf)


def recv_frame(sock: socket.socket) -> tuple[bytes, bytes]:
    head: bytes = recv_exact(sock, 5)
    return head[:1], recv_exact(sock, struct.unpack(">I", head[1:])[0])


class Tunnel:
    """phone 側。tlslite にはソケットとして見せ、制御の枠は別の待ち行列に分ける。"""

    def __init__(self, sock: socket.socket) -> None:
        self.sock: socket.socket = sock
        self.lock: threading.Lock = threading.Lock()
        self.data: queue.Queue[bytes | None] = queue.Queue()
        self.ctrl: queue.Queue[tuple[bytes, Any]] = queue.Queue()
        self.pending: bytearray = bytearray()
        self.inbound: bytearray = bytearray()   # 受け取った内側 TLS の全バイト(証明の材料)
        self.eof: bool = False
        threading.Thread(target=self._reader, daemon=True).start()

    def _reader(self) -> None:
        try:
            while True:
                kind, payload = recv_frame(self.sock)
                if kind == b"D":
                    self.inbound += payload
                    self.data.put(payload)
                elif kind == b"E":
                    self.data.put(None)
                else:
                    self.ctrl.put((kind, json.loads(payload)))
        except (ConnectionError, OSError):
            self.data.put(None)

    # --- tlslite が使うソケットの口 ---
    def send(self, data: bytes) -> int:
        send_frame(self.sock, b"D", bytes(data), self.lock)
        return len(data)

    def sendall(self, data: bytes) -> None:
        self.send(data)

    def recv(self, n: int) -> bytes:
        if not self.pending:
            if self.eof:
                return b""
            item: bytes | None = self.data.get()
            if item is None:
                self.eof = True
                return b""
            self.pending += item
        out: bytes = bytes(self.pending[:n])
        del self.pending[:n]
        return out

    def close(self) -> None:
        # 内側の TLS が閉じても、外側の経路は証明のやり取りに使うので閉じない(Phone.close が閉じる)
        pass

    def shutdown(self, how: int) -> None:
        pass

    # --- 制御 ---
    def call(self, kind: bytes, message: dict[str, Any], reply: bytes, timeout: float = 60.0) -> Any:
        send_frame(self.sock, kind, json.dumps(message).encode(), self.lock)
        got, body = self.ctrl.get(timeout=timeout)
        if got != reply:
            raise RuntimeError(f"expected {reply!r}, got {got!r}: {body}")
        return body


class Meter:
    """TCP の中継をしながら、両方向のバイト数を数える(回線に流れた量の実測用)。"""

    def __init__(self, target: tuple[str, int], delay: float = 0.0) -> None:
        self.target: tuple[str, int] = target
        self.delay: float = delay   # 片道の遅延(秒)。回線の遅さを模す
        self.up: int = 0      # 接続した側 → target
        self.down: int = 0    # target → 接続した側
        self.lsock: socket.socket = socket.socket()
        self.lsock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        self.lsock.bind(("127.0.0.1", 0))
        self.lsock.listen(8)
        self.port: int = self.lsock.getsockname()[1]
        threading.Thread(target=self._accept, daemon=True).start()

    def _accept(self) -> None:
        while True:
            try:
                a, _ = self.lsock.accept()
            except OSError:
                return
            b: socket.socket = socket.create_connection(self.target)
            for s in (a, b):
                s.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
            threading.Thread(target=self._pump, args=(a, b, True), daemon=True).start()
            threading.Thread(target=self._pump, args=(b, a, False), daemon=True).start()

    def _pump(self, src: socket.socket, dst: socket.socket, upward: bool) -> None:
        import time
        q: queue.Queue[tuple[float, bytes | None]] = queue.Queue()

        def sender() -> None:
            while True:
                due, data = q.get()
                wait: float = due - time.time()
                if wait > 0:
                    time.sleep(wait)
                try:
                    if data is None:
                        dst.shutdown(socket.SHUT_WR)
                        return
                    dst.sendall(data)
                except OSError:
                    return

        threading.Thread(target=sender, daemon=True).start()
        try:
            while True:
                data: bytes = src.recv(65536)
                if not data:
                    break
                if upward:
                    self.up += len(data)
                else:
                    self.down += len(data)
                q.put((time.time() + self.delay, data))
        except OSError:
            pass
        q.put((time.time() + self.delay, None))

    def reset(self) -> None:
        self.up = 0
        self.down = 0
