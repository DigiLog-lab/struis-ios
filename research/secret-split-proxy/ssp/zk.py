"""「この鍵で AES をかけるとこの出力になる」ことの証明の実行役。

EmpZk が本物(emp-zk の QuickSilver。zk/aes_open.cpp)。ClearStandIn は配線の開発用で、証明ではない。
"""
from __future__ import annotations

import json
import os
import socket
import subprocess
import tempfile
import time
from typing import Any

from . import tlsrec


def free_port() -> int:
    s: socket.socket = socket.socket()
    s.bind(("127.0.0.1", 0))
    port: int = s.getsockname()[1]
    s.close()
    return port


class ClearStandIn:
    """証明ではない。prover が出力をそのまま送るだけ。ローカルでの配線の確認にだけ使う。"""
    is_proof: bool = False

    def __init__(self) -> None:
        self.port: int = free_port()

    def prover(self, key: bytes, blocks: list[bytes], masks: list[bytes]) -> dict[str, Any]:
        ls: socket.socket = socket.socket()
        ls.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        ls.bind(("127.0.0.1", self.port))
        ls.listen(1)
        c, _ = ls.accept()
        out: bytes = b"".join(bytes(a & b for a, b in zip(tlsrec.aes_block(key, blk), m))
                              for blk, m in zip(blocks, masks))
        c.sendall(out)
        c.close()
        ls.close()
        return {"sent": len(out)}

    def verifier(self, blocks: list[bytes], masks: list[bytes]) -> tuple[list[bytes], dict[str, Any]]:
        for _ in range(200):
            try:
                c: socket.socket = socket.create_connection(("127.0.0.1", self.port))
                break
            except OSError:
                time.sleep(0.01)
        buf: bytearray = bytearray()
        while len(buf) < 16 * len(blocks):
            chunk: bytes = c.recv(65536)
            if not chunk:
                break
            buf += chunk
        c.close()
        return [bytes(buf[i:i + 16]) for i in range(0, len(buf), 16)], {"engine": "stand-in (not a proof)"}


class EmpZk:
    """emp-zk(QuickSilver)で証明する。prover と verifier は別プロセスで、TCP で話す。"""
    is_proof: bool = True

    def __init__(self, binary: str, circuit: str) -> None:
        self.binary: str = binary
        self.circuit: str = circuit
        self.port: int = free_port()

    def _job(self, blocks: list[bytes], masks: list[bytes]) -> str:
        fd, path = tempfile.mkstemp(suffix=".job")
        with os.fdopen(fd, "w") as f:
            f.write(f"{len(blocks)}\n")
            for b, m in zip(blocks, masks):
                f.write(f"{b.hex()} {m.hex()}\n")
        return path

    def _run(self, party: int, job: str, key: bytes | None) -> dict[str, Any]:
        t0: float = time.time()
        proc = subprocess.run([self.binary, str(party), str(self.port), self.circuit, job],
                              input=(key.hex() + "\n").encode() if key else b"",
                              capture_output=True, timeout=170)
        os.unlink(job)
        result: dict[str, Any] = {"wall_s": round(time.time() - t0, 3), "exit": proc.returncode}
        for line in proc.stdout.decode().splitlines():
            if line.startswith("STATS "):
                result.update(json.loads(line[6:]))
            elif line.startswith("OUT "):
                result.setdefault("outputs", []).append(bytes.fromhex(line[4:]))
        if proc.returncode != 0:
            result["stderr"] = proc.stderr.decode()[-400:]
        return result

    def prover(self, key: bytes, blocks: list[bytes], masks: list[bytes]) -> dict[str, Any]:
        return self._run(1, self._job(blocks, masks), key)

    def verifier(self, blocks: list[bytes], masks: list[bytes]) -> tuple[list[bytes], dict[str, Any]]:
        r: dict[str, Any] = self._run(2, self._job(blocks, masks), None)
        outputs: list[bytes] = r.pop("outputs", [])
        if r["exit"] != 0 or len(outputs) != len(blocks):
            from .relay import Reject
            raise Reject(f"the proof was not accepted by the verifier: {r}")
        return outputs, r
