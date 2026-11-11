"""「秘密の鍵 K で AES-128 をかけると、公開のブロックに対してこの出力になる」ことの非対話の証明。

外部のライブラリを使わない自前の実装(検証用)。方式は VOLE-in-the-Head + QuickSilver で、
NIST の署名候補 FAEST と同じ骨格:
  1. prover が GGM 木で種を作り、全部の種にコミットする(11 回、1回あたり 2^12 か 2^11 枚の葉)。
  2. 葉の種から、秘密のビット列 u と、その MAC(M)を作る。verifier は後で Δ を選び、Δ 番目以外の
     種を教わって K = M + u·Δ を自分で計算できる(Δ 番目の種だけは最後まで知らない)。
  3. 証人(鍵のビット、S-box ごとの出力8ビットと「入力が0でない」1ビット)を u で隠して送る。
  4. AES の S-box は「x·y = t、x·t = x、y·t = y」(GF(2^8)、t は 0 か 1)の3本の2次式で縛り、
     全部の式をまとめて QuickSilver の検査 1 本で確かめる。
  5. Δ は、ここまでの送信内容全部のハッシュから決める(Fiat-Shamir)。prover は Δ を先に知れない。

証明は phone → relay の 1 通。verifier(relay)は、見せると指定されたバイトの AES の出力だけを知る。
"""
from __future__ import annotations

import hashlib
import os
import struct
from typing import Any

import numpy as np

# 繰り返しごとの葉の枚数は 2^k。k の合計が Δ のビット数(128)。FAEST-128s と同じ分け方(12×7 + 11×4)。
# 証明の大きさはおよそ「(繰り返しの回数 - 1) × 証人のビット数」なので、回数が少ないほど小さい。
KS: list[int] = [12] * 7 + [11] * 4
if os.environ.get("SSP_VZK_FAST"):
    KS = [8] * 16        # 証明は大きいが作るのが速い
TAU: int = len(KS)
assert sum(KS) == 128
OFFS: list[int] = [sum(KS[:i]) for i in range(TAU)]
R_PAD: int = 144         # 一貫性の検査のハッシュの行数(128 + 16)
MASK128: int = (1 << 128) - 1

# ------------------------------------------------------------------ GF(2^128) ----
_SPREAD_MASK: int = int.from_bytes(b"\x01" * 128, "big")
_TO_BITS: bytes = bytes([48 + (i & 1) for i in range(256)])


def _spread(a: int) -> int:
    return int.from_bytes(format(a, "0128b").encode(), "big") & _SPREAD_MASK


def gmul(a: int, b: int) -> int:
    """GF(2)[x]/(x^128 + x^7 + x^2 + x + 1) の積。整数の掛け算で桁上がりなしの積を作る。"""
    if a == 0 or b == 0:
        return 0
    p: int = int((_spread(a) * _spread(b)).to_bytes(256, "big").translate(_TO_BITS), 2)
    hi: int = p >> 128
    p = (p & MASK128) ^ hi ^ (hi << 1) ^ (hi << 2) ^ (hi << 7)
    hi = p >> 128
    return (p & MASK128) ^ hi ^ (hi << 1) ^ (hi << 2) ^ (hi << 7)


def gpow(a: int, e: int) -> int:
    r: int = 1
    while e:
        if e & 1:
            r = gmul(r, a)
        a = gmul(a, a)
        e >>= 1
    return r


# ------------------------------------------------------------------ AES の GF(2^8) ----
def _mul8(a: int, b: int) -> int:
    r: int = 0
    for _ in range(8):
        if b & 1:
            r ^= a
        a = ((a << 1) ^ 0x11B) if a & 0x80 else a << 1
        b >>= 1
    return r


INV8: list[int] = [0] * 256
for _a in range(1, 256):
    _x: int = _a
    for _ in range(253):
        _x = _mul8(_x, _a)
    INV8[_a] = _x          # a^254 = a^-1


def affine(y: int) -> int:
    r: int = y
    for s in range(1, 5):
        r ^= ((y << s) | (y >> (8 - s))) & 0xFF
    return r ^ 0x63


def _linear_affine(y: int) -> int:
    return affine(y) ^ 0x63


RCON: list[int] = [0x01, 0x02, 0x04, 0x08, 0x10, 0x20, 0x40, 0x80, 0x1B, 0x36]


def _find_beta() -> int:
    """GF(2^8) ⊂ GF(2^128) への埋め込み: AES の法 x^8+x^4+x^3+x+1 の根 β を GF(2^128) の中に探す。"""
    for g in range(2, 50):
        gamma: int = gpow(g, ((1 << 128) - 1) // 255)
        c: int = 1
        for _ in range(255):
            c = gmul(c, gamma)
            c2: int = gmul(c, c)
            c4: int = gmul(c2, c2)
            if gmul(c4, c4) ^ c4 ^ gmul(c2, c) ^ c ^ 1 == 0:
                return c
    raise RuntimeError("no embedding found")


BETA: int = _find_beta()
_BETA_POW: list[int] = [1]
for _ in range(7):
    _BETA_POW.append(gmul(_BETA_POW[-1], BETA))
PHI: list[int] = [0] * 256          # GF(2^8) の値 → GF(2^128) の元
for _v in range(256):
    _e: int = 0
    for _b in range(8):
        if (_v >> _b) & 1:
            _e ^= _BETA_POW[_b]
    PHI[_v] = _e


def _ctable(c: int) -> list[list[int]]:
    """定数 c を掛ける表(128ビットの値を8ビットずつ16回引く)。"""
    basis: list[int] = [gmul(1 << i, c) for i in range(128)]
    table: list[list[int]] = []
    for pos in range(16):
        row: list[int] = [0] * 256
        for byte in range(1, 256):
            low: int = byte & -byte
            row[byte] = row[byte ^ low] ^ basis[8 * pos + low.bit_length() - 1]
        table.append(row)
    return table


def cmul(table: list[list[int]], m: int) -> int:
    r: int = 0
    for pos, byte in enumerate(m.to_bytes(16, "little")):
        r ^= table[pos][byte]
    return r


T_BIT: list[list[list[int]]] = [_ctable(PHI[1 << b]) for b in range(8)]               # ビット b → バイトの値
T_AFF: list[list[list[int]]] = [_ctable(PHI[_linear_affine(1 << b)]) for b in range(8)]  # ビット b → アフィン変換後
T_TWO: list[list[int]] = _ctable(PHI[2])
T_XPOW: list[list[list[int]]] | None = None


# ------------------------------------------------------------------ 回路(3つの立場で同じ手順を踏む) ----
class Values:
    """値だけで AES を計算し、証人のビット列を記録する(prover の1周目)。"""

    def __init__(self, key: bytes) -> None:
        self.key: bytes = key
        self.witness: list[int] = []
        for byte in key:
            self.witness += [(byte >> b) & 1 for b in range(8)]
        self.outputs: list[int] = []

    def key_bytes(self) -> list[int]:
        return list(self.key)

    def const(self, c: int) -> int:
        return c

    def xor(self, a: int, b: int) -> int:
        return a ^ b

    def mul2(self, a: int) -> int:
        return _mul8(a, 2)

    def sbox(self, x: int) -> int:
        y: int = INV8[x]
        self.witness += [(y >> b) & 1 for b in range(8)]
        self.witness.append(1 if x else 0)
        return affine(y)

    def reveal(self, a: int) -> int:
        self.outputs.append(a)
        return a


class Proving:
    """値と MAC を運ぶ(prover の2周目)。線は (GF(2^8) の値, MAC)。"""

    def __init__(self, witness: list[int], macs: list[int], chi: int) -> None:
        self.w: list[int] = witness
        self.m: list[int] = macs
        self.pos: int = 0
        self.chi: int = chi
        self.acc0: int = 0
        self.acc1: int = 0

    def _bits(self, n: int) -> tuple[list[int], list[int]]:
        p: int = self.pos
        self.pos += n
        return self.w[p:p + n], self.m[p:p + n]

    def key_bytes(self) -> list[tuple[int, int]]:
        out: list[tuple[int, int]] = []
        for _ in range(16):
            bits, macs = self._bits(8)
            val: int = sum(bit << b for b, bit in enumerate(bits))
            mac: int = 0
            for b in range(8):
                mac ^= cmul(T_BIT[b], macs[b])
            out.append((val, mac))
        return out

    def const(self, c: int) -> tuple[int, int]:
        return (c, 0)

    def xor(self, a: tuple[int, int], b: tuple[int, int]) -> tuple[int, int]:
        return (a[0] ^ b[0], a[1] ^ b[1])

    def mul2(self, a: tuple[int, int]) -> tuple[int, int]:
        return (_mul8(a[0], 2), cmul(T_TWO, a[1]))

    def _constrain(self, a: tuple[int, int], b: tuple[int, int], c_mac: int) -> None:
        """a·b + c = 0 の式を1本足す。"""
        a0: int = gmul(a[1], b[1])
        a1: int = gmul(PHI[a[0]], b[1]) ^ gmul(PHI[b[0]], a[1]) ^ c_mac
        self.acc0 = gmul(self.acc0, self.chi) ^ a0
        self.acc1 = gmul(self.acc1, self.chi) ^ a1

    def sbox(self, x: tuple[int, int]) -> tuple[int, int]:
        bits, macs = self._bits(9)
        y: int = sum(bit << b for b, bit in enumerate(bits[:8]))
        my: int = 0
        ms: int = 0
        for b in range(8):
            my ^= cmul(T_BIT[b], macs[b])
            ms ^= cmul(T_AFF[b], macs[b])
        yw: tuple[int, int] = (y, my)
        tw: tuple[int, int] = (bits[8], macs[8])
        self._constrain(x, yw, tw[1])       # x·y = t
        self._constrain(x, tw, x[1])        # x·t = x
        self._constrain(yw, tw, yw[1])      # y·t = y
        return (affine(y), ms)

    def reveal(self, a: tuple[int, int]) -> int:
        # (a + 公開の値) = 0 の1次式。1·c + 0 = 0 の形で同じ検査にまとめる(a0 = 0、a1 = MAC)
        self.acc0 = gmul(self.acc0, self.chi)
        self.acc1 = gmul(self.acc1, self.chi) ^ a[1]
        return a[0]


class Checking:
    """verifier。線は鍵 K = M + 値·Δ だけ。値は見えない。"""

    def __init__(self, keys: list[int], delta: int, chi: int, claimed: list[int]) -> None:
        self.k: list[int] = keys
        self.pos: int = 0
        self.delta: int = delta
        self.chi: int = chi
        self.acc: int = 0
        self.claimed: list[int] = claimed
        self.claim_pos: int = 0
        self._const: dict[int, int] = {}

    def _keys(self, n: int) -> list[int]:
        p: int = self.pos
        self.pos += n
        return self.k[p:p + n]

    def key_bytes(self) -> list[int]:
        out: list[int] = []
        for _ in range(16):
            ks: list[int] = self._keys(8)
            key: int = 0
            for b in range(8):
                key ^= cmul(T_BIT[b], ks[b])
            out.append(key)
        return out

    def const(self, c: int) -> int:
        if c not in self._const:
            self._const[c] = gmul(PHI[c], self.delta)
        return self._const[c]

    def xor(self, a: int, b: int) -> int:
        return a ^ b

    def mul2(self, a: int) -> int:
        return cmul(T_TWO, a)

    def _constrain(self, ka: int, kb: int, kc: int) -> None:
        self.acc = gmul(self.acc, self.chi) ^ gmul(ka, kb) ^ gmul(kc, self.delta)

    def sbox(self, x: int) -> int:
        ks: list[int] = self._keys(9)
        ky: int = 0
        ksb: int = 0
        for b in range(8):
            ky ^= cmul(T_BIT[b], ks[b])
            ksb ^= cmul(T_AFF[b], ks[b])
        kt: int = ks[8]
        self._constrain(x, ky, kt)
        self._constrain(x, kt, x)
        self._constrain(ky, kt, ky)
        return ksb ^ self.const(0x63)

    def reveal(self, a: int) -> int:
        value: int = self.claimed[self.claim_pos]
        self.claim_pos += 1
        kc: int = a ^ self.const(value)          # (a + 公開の値) の鍵
        self.acc = gmul(self.acc, self.chi) ^ gmul(self.delta, kc)
        return value


def _sbox_out(be: Any, x: Any) -> Any:
    s = be.sbox(x)
    # Proving と Values は affine 済みの値を返す。MAC 側は線形部分だけなので定数 0x63 を足す
    if isinstance(be, Proving):
        return (s[0], s[1])
    return s


def run_circuit(be: Any, blocks: list[bytes], masks: list[bytes]) -> list[bytes]:
    """鍵の展開と、各ブロックの暗号化。見せるバイトだけ reveal する。"""
    rk: list[Any] = be.key_bytes()
    for i in range(4, 44):
        prev: list[Any] = rk[4 * (i - 1):4 * i]
        if i % 4 == 0:
            rot: list[Any] = prev[1:] + prev[:1]
            sub: list[Any] = [_sbox_out(be, x) for x in rot]
            sub[0] = be.xor(sub[0], be.const(RCON[i // 4 - 1]))
            prev = sub
        rk += [be.xor(rk[4 * (i - 4) + j], prev[j]) for j in range(4)]
    outs: list[bytes] = []
    for block, mask in zip(blocks, masks):
        st: list[Any] = [be.xor(be.const(block[i]), rk[i]) for i in range(16)]
        for rnd in range(1, 11):
            st = [_sbox_out(be, x) for x in st]
            st = [st[(i + 4 * (i % 4)) % 16] for i in range(16)]          # ShiftRows
            if rnd != 10:
                mixed: list[Any] = []
                for c in range(4):
                    a = st[4 * c:4 * c + 4]
                    for r in range(4):
                        t = be.xor(be.mul2(be.xor(a[r], a[(r + 1) % 4])), a[(r + 1) % 4])
                        mixed.append(be.xor(t, be.xor(a[(r + 2) % 4], a[(r + 3) % 4])))
                st = mixed
            st = [be.xor(st[i], rk[16 * rnd + i]) for i in range(16)]
        out: bytearray = bytearray(16)
        for i in range(16):
            if mask[i] == 0xFF:
                out[i] = be.reveal(st[i])
        outs.append(bytes(out))
    return outs


def witness_bits(n_blocks: int) -> int:
    return 128 + 40 * 9 + n_blocks * 160 * 9


# ------------------------------------------------------------------ VOLE(GGM 木と葉) ----
def _xof(tag: bytes, data: bytes, n: int) -> bytes:
    return hashlib.shake_128(tag + data).digest(n)


def _expand_tree(root: bytes, salt: bytes, depth: int) -> list[bytes]:
    level: list[bytes] = [root]
    for _ in range(depth):
        nxt: list[bytes] = []
        for node in level:
            both: bytes = _xof(b"ggm", salt + node, 32)
            nxt += [both[:16], both[16:]]
        level = nxt
    return level


def _leaf(salt: bytes, rep: int, x: int, node: bytes) -> tuple[bytes, bytes]:
    out: bytes = _xof(b"leaf", salt + struct.pack(">HH", rep, x) + node, 48)
    return out[:16], out[16:]


def _prg(salt: bytes, seed: bytes, nbytes: int) -> int:
    return int.from_bytes(_xof(b"prg", salt + seed, nbytes), "little")


def _hash_rows(chall: bytes, width: int) -> list[int]:
    nb: int = (width + 7) // 8
    lim: int = (1 << width) - 1
    return [int.from_bytes(hashlib.shake_256(b"row" + chall + struct.pack(">H", t)).digest(nb), "little") & lim
            for t in range(R_PAD)]


def _lin_hash(rows: list[int], x: int, width: int) -> int:
    lo: int = x & ((1 << width) - 1)
    out: int = x >> width
    for t, row in enumerate(rows):
        if (lo & row).bit_count() & 1:
            out ^= 1 << t
    return out


def _transpose(planes: list[int], nbits: int) -> list[int]:
    """128 枚のビット列(各 nbits)を、位置ごとの 128 ビットの値に並べ替える。"""
    nb: int = (nbits + 7) // 8
    arr = np.frombuffer(b"".join(p.to_bytes(nb, "little") for p in planes), dtype=np.uint8).reshape(128, nb)
    bits = np.unpackbits(arr, axis=1, bitorder="little")[:, :nbits]
    packed = np.packbits(bits.T, axis=1, bitorder="little")
    raw: bytes = packed.tobytes()
    return [int.from_bytes(raw[i:i + 16], "little") for i in range(0, len(raw), 16)]


def _statement_digest(blocks: list[bytes], masks: list[bytes]) -> bytes:
    h = hashlib.sha256(b"ssp-aes-open-v1" + struct.pack(">I", len(blocks)) + bytes(KS))
    for b, m in zip(blocks, masks):
        h.update(b + m)
    return h.digest()


def prove(key: bytes, blocks: list[bytes], masks: list[bytes], tamper: str | None = None) -> bytes:
    """証明を作る。tamper は検証用(わざと壊す場所の指定)。"""
    n: int = len(blocks)
    lw: int = witness_bits(n)
    lhat: int = lw + 128 + R_PAD
    nb: int = (lhat + 7) // 8
    lim: int = (1 << lhat) - 1
    salt: bytes = os.urandom(16)

    # 1周目: 値だけで計算して証人を得る
    vals: Values = Values(key)
    outs: list[bytes] = run_circuit(vals, blocks, masks)
    witness: list[int] = vals.witness
    assert len(witness) == lw
    if tamper == "witness":
        witness[128 + 40 * 9 + 5] ^= 1
    if tamper == "output":
        for i, m in enumerate(masks):
            if m[0] == 0xFF:
                outs[i] = bytes([outs[i][0] ^ 1]) + outs[i][1:]
                break

    # GGM 木と葉 → u と v
    roots: list[bytes] = [os.urandom(16) for _ in range(TAU)]
    trees: list[list[bytes]] = []
    coms: list[list[bytes]] = []
    us: list[int] = []
    planes: list[int] = []
    h_all = hashlib.sha256()
    for rep in range(TAU):
        kb: int = KS[rep]
        nodes: list[bytes] = _expand_tree(roots[rep], salt, kb)
        trees.append(nodes)
        u: int = 0
        v: list[int] = [0] * kb
        com_list: list[bytes] = []
        for x in range(1 << kb):
            sd, com = _leaf(salt, rep, x, nodes[x])
            com_list.append(com)
            w: int = _prg(salt, sd, nb) & lim
            u ^= w
            b: int = 0
            y: int = x
            while y:
                if y & 1:
                    v[b] ^= w
                y >>= 1
                b += 1
        coms.append(com_list)
        h_all.update(hashlib.sha256(b"".join(com_list)).digest())
        us.append(u)
        planes += v
    h_com: bytes = h_all.digest()
    u = us[0]
    corrections: list[int] = [us[rep] ^ u for rep in range(1, TAU)]
    if tamper == "correction":
        corrections[3] ^= 1 << 7
    corr_bytes: bytes = b"".join(c.to_bytes(nb, "little") for c in corrections)

    stmt: bytes = _statement_digest(blocks, masks)
    chall1: bytes = hashlib.sha256(b"c1" + stmt + salt + h_com + corr_bytes).digest()
    rows: list[int] = _hash_rows(chall1, lhat - R_PAD)
    u_tilde: int = _lin_hash(rows, u, lhat - R_PAD)
    h_v: bytes = hashlib.sha256(b"".join(
        _lin_hash(rows, p, lhat - R_PAD).to_bytes(R_PAD // 8, "little") for p in planes)).digest()

    d: int = 0
    for j, bit in enumerate(witness):
        if bit ^ ((u >> j) & 1):
            d |= 1 << j
    d_bytes: bytes = d.to_bytes((lw + 7) // 8, "little")
    out_bytes: bytes = b"".join(outs)
    chall2: bytes = hashlib.sha256(b"c2" + chall1 + u_tilde.to_bytes(R_PAD // 8, "little") + h_v
                                   + d_bytes + out_bytes).digest()
    chi: int = int.from_bytes(chall2[:16], "little")

    macs: list[int] = _transpose(planes, lhat)
    pr: Proving = Proving(witness, macs, chi)
    run_circuit(pr, blocks, masks)
    assert pr.pos == lw
    # ゼロ知識のための覆い: u の続き 128 ビットから a1*、その MAC から a0*
    a1s: int = (u >> lw) & MASK128
    a0s: int = 0
    xp: int = 1
    for b in range(128):
        a0s ^= gmul(macs[lw + b], xp)
        xp = gmul(xp, 2)
    a0: int = pr.acc0 ^ a0s
    a1: int = pr.acc1 ^ a1s
    a_bytes: bytes = a0.to_bytes(16, "little") + a1.to_bytes(16, "little")

    delta: int = int.from_bytes(hashlib.sha256(b"c3" + chall2 + a_bytes).digest()[:16], "little")
    # Δ 番目以外の種を開ける: 木の道の兄弟(深さの数だけ)と、隠す葉のコミット
    openings: bytearray = bytearray()
    for rep in range(TAU):
        kb = KS[rep]
        hidden: int = (delta >> OFFS[rep]) & ((1 << kb) - 1)
        siblings: list[bytes] = []
        node: bytes = roots[rep]
        for depth in range(kb):
            both: bytes = _xof(b"ggm", salt + node, 32)
            bit: int = (hidden >> (kb - 1 - depth)) & 1
            siblings.append(both[16:] if bit == 0 else both[:16])
            node = both[16:] if bit else both[:16]
        openings += b"".join(siblings) + coms[rep][hidden]
    if tamper == "opening":
        openings[5] ^= 1
    return b"".join([salt, h_com, corr_bytes, u_tilde.to_bytes(R_PAD // 8, "little"), h_v,
                     d_bytes, out_bytes, a_bytes, bytes(openings)])


class Invalid(Exception):
    pass


def verify(proof: bytes, blocks: list[bytes], masks: list[bytes]) -> list[bytes]:
    """証明を確かめ、見せると指定されたバイトの AES の出力を返す。通らなければ Invalid。"""
    n: int = len(blocks)
    lw: int = witness_bits(n)
    lhat: int = lw + 128 + R_PAD
    nb: int = (lhat + 7) // 8
    lim: int = (1 << lhat) - 1
    dn: int = (lw + 7) // 8
    sizes: list[int] = [16, 32, nb * (TAU - 1), R_PAD // 8, 32, dn, 16 * n, 32, sum(16 * k + 32 for k in KS)]
    if len(proof) != sum(sizes):
        raise Invalid("wrong proof length")
    parts: list[bytes] = []
    p: int = 0
    for s in sizes:
        parts.append(proof[p:p + s])
        p += s
    salt, h_com, corr_bytes, ut_b, h_v, d_bytes, out_bytes, a_bytes, openings = parts

    stmt: bytes = _statement_digest(blocks, masks)
    chall1: bytes = hashlib.sha256(b"c1" + stmt + salt + h_com + corr_bytes).digest()
    chall2: bytes = hashlib.sha256(b"c2" + chall1 + ut_b + h_v + d_bytes + out_bytes).digest()
    chi: int = int.from_bytes(chall2[:16], "little")
    delta: int = int.from_bytes(hashlib.sha256(b"c3" + chall2 + a_bytes).digest()[:16], "little")

    # 種を復元して q を作る
    planes: list[int] = []
    h_all = hashlib.sha256()
    cursor: int = 0
    for rep in range(TAU):
        kb: int = KS[rep]
        hidden: int = (delta >> OFFS[rep]) & ((1 << kb) - 1)
        blob: bytes = openings[cursor:cursor + 16 * kb + 32]
        cursor += 16 * kb + 32
        siblings: list[bytes] = [blob[16 * i:16 * i + 16] for i in range(kb)]
        com_hidden: bytes = blob[16 * kb:]
        nodes: dict[int, bytes] = {}
        for depth in range(kb):
            bit: int = (hidden >> (kb - 1 - depth)) & 1
            prefix: int = ((hidden >> (kb - depth)) << 1) | (bit ^ 1)
            level: list[bytes] = [siblings[depth]]
            for _ in range(kb - 1 - depth):
                nxt: list[bytes] = []
                for node in level:
                    both: bytes = _xof(b"ggm", salt + node, 32)
                    nxt += [both[:16], both[16:]]
                level = nxt
            base: int = prefix << (kb - 1 - depth)
            for off, node in enumerate(level):
                nodes[base + off] = node
        if len(nodes) != (1 << kb) - 1 or hidden in nodes:
            raise Invalid("bad opening shape")
        q: list[int] = [0] * kb
        com_list: list[bytes] = []
        for x in range(1 << kb):
            if x == hidden:
                com_list.append(com_hidden)
                continue
            sd, com = _leaf(salt, rep, x, nodes[x])
            com_list.append(com)
            w: int = _prg(salt, sd, nb) & lim
            diff: int = x ^ hidden
            b: int = 0
            while diff:
                if diff & 1:
                    q[b] ^= w
                diff >>= 1
                b += 1
        h_all.update(hashlib.sha256(b"".join(com_list)).digest())
        if rep > 0:
            c: int = int.from_bytes(corr_bytes[(rep - 1) * nb:rep * nb], "little")
            if c >> lhat:
                raise Invalid("correction too long")
            for b in range(kb):
                if (hidden >> b) & 1:
                    q[b] ^= c
        planes += q
    if h_all.digest() != h_com:
        raise Invalid("the opened seeds do not match the commitment")

    # 一貫性の検査: 全部の繰り返しが同じ u を使っていること
    rows: list[int] = _hash_rows(chall1, lhat - R_PAD)
    u_tilde: int = int.from_bytes(ut_b, "little")
    hv = hashlib.sha256()
    for pi, plane in enumerate(planes):
        v_t: int = _lin_hash(rows, plane, lhat - R_PAD)
        if (delta >> pi) & 1:
            v_t ^= u_tilde
        hv.update(v_t.to_bytes(R_PAD // 8, "little"))
    if hv.digest() != h_v:
        raise Invalid("the VOLE consistency check failed")

    keys: list[int] = _transpose(planes, lhat)
    d: int = int.from_bytes(d_bytes, "little")
    if d >> lw:
        raise Invalid("witness mask too long")
    for j in range(lw):
        if (d >> j) & 1:
            keys[j] ^= delta
    claimed_blocks: list[bytes] = [out_bytes[16 * i:16 * i + 16] for i in range(n)]
    claimed: list[int] = []
    for blk, mask in zip(claimed_blocks, masks):
        for i in range(16):
            if mask[i] == 0xFF:
                claimed.append(blk[i])
            elif blk[i] != 0:
                raise Invalid("an unrevealed output byte is not zero")
    ck: Checking = Checking(keys, delta, chi, claimed)
    run_circuit(ck, blocks, masks)
    ks: int = 0
    xp: int = 1
    for b in range(128):
        ks ^= gmul(keys[lw + b], xp)
        xp = gmul(xp, 2)
    a0: int = int.from_bytes(a_bytes[:16], "little")
    a1: int = int.from_bytes(a_bytes[16:], "little")
    if ck.acc ^ ks != a0 ^ gmul(a1, delta):
        raise Invalid("the AES constraints are not satisfied")
    return claimed_blocks
