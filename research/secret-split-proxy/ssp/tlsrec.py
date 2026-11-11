"""TLS 1.3 のレコード(AES-128-GCM)を手で扱うための部品。RFC 8446 5.2/5.3、NIST SP 800-38D。"""
from __future__ import annotations

import struct
from typing import Iterator

from cryptography.hazmat.primitives.ciphers import Cipher, algorithms, modes
from cryptography.hazmat.primitives.ciphers.aead import AESGCM

APPLICATION_DATA: int = 0x17
HANDSHAKE: int = 0x16
ALERT: int = 0x15
# KeyUpdate(update_not_requested): msg_type=24, length=1, request_update=0
KEY_UPDATE_NOT_REQUESTED: bytes = b"\x18\x00\x00\x01\x00"
R: int = 0xE1 << 120


def nonce(iv: bytes, seq: int) -> bytes:
    return bytes(a ^ b for a, b in zip(iv, b"\x00" * 4 + struct.pack(">Q", seq)))


def seal(key: bytes, iv: bytes, seq: int, inner_type: int, content: bytes) -> bytes:
    """1 レコードを作る。平文は content || inner_type。"""
    inner: bytes = content + bytes([inner_type])
    header: bytes = b"\x17\x03\x03" + struct.pack(">H", len(inner) + 16)
    return header + AESGCM(key).encrypt(nonce(iv, seq), inner, header)


def seal_many(key: bytes, iv: bytes, seq: int, inner_type: int, content: bytes) -> tuple[bytes, int]:
    """16KB を超える内容を複数レコードに分ける。戻り値は (バイト列, 次の seq)。"""
    out: bytearray = bytearray()
    for off in range(0, max(len(content), 1), 16000):
        out += seal(key, iv, seq, inner_type, content[off:off + 16000])
        seq += 1
    return bytes(out), seq


def open_record(key: bytes, iv: bytes, seq: int, record: bytes) -> tuple[int, bytes]:
    """(inner_type, content) を返す。鍵か seq が違えば InvalidTag。"""
    inner: bytes = AESGCM(key).decrypt(nonce(iv, seq), record[5:], record[:5])
    stripped: bytes = inner.rstrip(b"\x00")
    return stripped[-1], stripped[:-1]


class RecordParser:
    """バイト列を TLS レコード(ヘッダー5バイト込み)に切り出す。"""

    def __init__(self) -> None:
        self.buf: bytearray = bytearray()

    def feed(self, data: bytes) -> Iterator[bytes]:
        self.buf += data
        while len(self.buf) >= 5:
            n: int = struct.unpack(">H", self.buf[3:5])[0]
            if len(self.buf) < 5 + n:
                return
            rec: bytes = bytes(self.buf[:5 + n])
            del self.buf[:5 + n]
            yield rec


def aes_block(key: bytes, block: bytes) -> bytes:
    enc = Cipher(algorithms.AES(key), modes.ECB()).encryptor()
    return enc.update(block) + enc.finalize()


def gf_mul(x: int, y: int) -> int:
    """GF(2^128) の積(GCM のビット順)。"""
    z: int = 0
    v: int = x
    for i in range(127, -1, -1):
        if (y >> i) & 1:
            z ^= v
        v = (v >> 1) ^ R if v & 1 else v >> 1
    return z


def ghash(h: bytes, aad: bytes, ct: bytes) -> bytes:
    hi: int = int.from_bytes(h, "big")
    y: int = 0

    def blocks(b: bytes) -> Iterator[bytes]:
        for i in range(0, len(b), 16):
            yield b[i:i + 16].ljust(16, b"\x00")

    for blk in list(blocks(aad)) + list(blocks(ct)):
        y = gf_mul(y ^ int.from_bytes(blk, "big"), hi)
    y = gf_mul(y ^ ((len(aad) * 8) << 64 | (len(ct) * 8)), hi)
    return y.to_bytes(16, "big")


def gcm_tag(h: bytes, mask: bytes, aad: bytes, ct: bytes) -> bytes:
    """H = AES_K(0) と mask = AES_K(J0) から認証タグを計算する(鍵そのものは要らない)。"""
    return bytes(a ^ b for a, b in zip(ghash(h, aad, ct), mask))


def j0(iv: bytes, seq: int) -> bytes:
    return nonce(iv, seq) + b"\x00\x00\x00\x01"


def ctr_block(iv: bytes, seq: int, index: int) -> bytes:
    """平文の index 番目(0始まり)の16バイトに使うカウンターブロック。"""
    return nonce(iv, seq) + struct.pack(">I", index + 2)
