#!/usr/bin/env python3
"""A logging proxy in front of api.anthropic.com for the Dev Box (claude/real-usage-test only).

    api_proxy.py <dir> [port]

The app is started with STRUIS_ANTHROPIC_BASE_URL=http://127.0.0.1:<port>. Each POST /v1/messages is forwarded
unchanged (headers included) and written to <dir>/<n>.req.json, <n>.resp.sse and <n>.meta.json (times, status).
Headers are never written. If <dir>/model_override holds "from to", that model name is replaced in the body.
"""
from __future__ import annotations

import http.client
import http.server
import json
import pathlib
import sys
import threading
import time

OUT: pathlib.Path = pathlib.Path(sys.argv[1])
PORT: int = int(sys.argv[2]) if len(sys.argv) > 2 else 8787
LOCK: threading.Lock = threading.Lock()
COUNTER: list[int] = [0]
SKIP_REQUEST: set[str] = {"host", "content-length", "accept-encoding", "connection", "proxy-connection"}
SKIP_RESPONSE: set[str] = {"transfer-encoding", "content-length", "content-encoding", "connection"}


class Handler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, format: str, *args: object) -> None:
        return

    def do_POST(self) -> None:
        body: bytes = self.rfile.read(int(self.headers.get("content-length", "0")))
        with LOCK:
            COUNTER[0] += 1
            number: int = COUNTER[0]
        stem: str = f"{number:04d}"
        override: pathlib.Path = OUT / "model_override"
        sent: bytes = body
        if override.exists():
            source, target = override.read_text().split()
            sent = body.replace(f'"{source}"'.encode(), f'"{target}"'.encode())
        (OUT / f"{stem}.req.json").write_bytes(sent)
        headers: dict[str, str] = {k: v for k, v in self.headers.items() if k.lower() not in SKIP_REQUEST}
        headers["accept-encoding"] = "identity"
        started: float = time.time()
        meta: dict[str, object] = {"path": self.path, "started": started, "request_bytes": len(sent)}
        try:
            upstream = http.client.HTTPSConnection("api.anthropic.com", timeout=900)
            upstream.request("POST", self.path, body=sent, headers=headers)
            response = upstream.getresponse()
            meta["status"] = response.status
            self.send_response(response.status)
            for key, value in response.getheaders():
                if key.lower() not in SKIP_RESPONSE:
                    self.send_header(key, value)
            self.send_header("Connection", "close")
            self.end_headers()
            with open(OUT / f"{stem}.resp.sse", "wb") as log:
                while True:
                    chunk: bytes = response.read1(65536)
                    if not chunk:
                        break
                    if "first_byte" not in meta:
                        meta["first_byte"] = time.time() - started
                    log.write(chunk)
                    try:
                        self.wfile.write(chunk)
                        self.wfile.flush()
                    except OSError:
                        meta["client_closed"] = True
                        break
            upstream.close()
        except Exception as error:  # noqa: BLE001
            meta["error"] = repr(error)
        meta["seconds"] = time.time() - started
        (OUT / f"{stem}.meta.json").write_text(json.dumps(meta))
        self.close_connection = True


if __name__ == "__main__":
    OUT.mkdir(parents=True, exist_ok=True)
    http.server.ThreadingHTTPServer(("127.0.0.1", PORT), Handler).serve_forever()
