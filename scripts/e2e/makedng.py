#!/usr/bin/env python3
"""makedng.py out.dng [width height] : ProRAW の代わりに、LinearRaw の非圧縮 DNG(16bit RGB)を作る。
文字を書いた画像を線形の値にして入れる。4032×3024 で約 73MB(ProRAW 1 枚と同じくらい)。"""
import struct, sys
from PIL import Image, ImageDraw, ImageFont

out = sys.argv[1]
W = int(sys.argv[2]) if len(sys.argv) > 2 else 4032
H = int(sys.argv[3]) if len(sys.argv) > 3 else 3024
im = Image.new("RGB", (W, H), (235, 232, 225))
d = ImageDraw.Draw(im)
f = ImageFont.truetype("/System/Library/Fonts/ヒラギノ角ゴシック W3.ttc", max(40, H // 20))
for k, line in enumerate(["DNG test", "問1 x^2 - 9 = 0 を解け", "問2 y = (x-1)^2 + 3 の頂点"]):
    d.text((W // 12, H // 6 + k * H // 6), line, font=f, fill=(20, 20, 30))
# sRGB(ガンマ)→ 線形 16bit
lut = [int(((v / 255) / 12.92 if v / 255 <= 0.04045 else (((v / 255) + 0.055) / 1.055) ** 2.4) * 65535) for v in range(256)]
raw = bytearray(W * H * 6)
px = im.tobytes()
for i in range(W * H * 3):
    struct.pack_into("<H", raw, i * 2, lut[px[i]])

entries = []
def tag(code, typ, count, value):
    entries.append((code, typ, count, value))
SHORT, LONG, RATIONAL, SRATIONAL, BYTE, ASCII = 3, 4, 5, 10, 1, 2
model = b"Struis LinearRaw Test\x00"
# 付属データ(BitsPerSample、文字列、行列)を IFD の後ろに置く
ifd_count = 18
ifd_start = 8
ifd_size = 2 + ifd_count * 12 + 4
extra = bytearray()
def put(data):
    off = ifd_start + ifd_size + len(extra)
    extra.extend(data)
    if len(extra) % 2: extra.append(0)
    return off
bps = put(struct.pack("<3H", 16, 16, 16))
model_off = put(model)
cm = [3.2406, -1.5372, -0.4986, -0.9689, 1.8758, 0.0415, 0.0557, -0.2040, 1.0570]  # XYZ→sRGB
cm_off = put(b"".join(struct.pack("<ii", int(v * 10000), 10000) for v in cm))
neutral_off = put(b"".join(struct.pack("<II", 1, 1) for _ in range(3)))
data_off = ifd_start + ifd_size + len(extra)
tag(254, LONG, 1, 0)                 # NewSubfileType
tag(256, LONG, 1, W)
tag(257, LONG, 1, H)
tag(258, SHORT, 3, bps)              # BitsPerSample
tag(259, SHORT, 1, 1)                # Compression none
tag(262, SHORT, 1, 34892)            # LinearRaw
tag(273, LONG, 1, data_off)          # StripOffsets
tag(274, SHORT, 1, 1)                # Orientation
tag(277, SHORT, 1, 3)                # SamplesPerPixel
tag(278, LONG, 1, H)                 # RowsPerStrip
tag(279, LONG, 1, len(raw))          # StripByteCounts
tag(284, SHORT, 1, 1)                # PlanarConfiguration
tag(50706, BYTE, 4, struct.unpack("<I", bytes([1, 4, 0, 0]))[0])  # DNGVersion 1.4
tag(50708, ASCII, len(model), model_off)                           # UniqueCameraModel
tag(50717, LONG, 3, None)            # WhiteLevel(下で埋める)
tag(50721, SRATIONAL, 9, cm_off)     # ColorMatrix1
tag(50728, RATIONAL, 3, neutral_off) # AsShotNeutral
tag(50778, SHORT, 1, 21)             # CalibrationIlluminant1 = D65
white_off = put(struct.pack("<3I", 65535, 65535, 65535))
data_off = ifd_start + ifd_size + len(extra)
entries = [(c, t, n, (data_off if c == 273 else white_off if c == 50717 else v)) for c, t, n, v in entries]
assert len(entries) == ifd_count
with open(out, "wb") as fh:
    fh.write(b"II*\x00" + struct.pack("<I", ifd_start))
    fh.write(struct.pack("<H", ifd_count))
    for code, typ, count, value in sorted(entries):
        if typ == SHORT and count == 1:
            fh.write(struct.pack("<HHIHH", code, typ, count, value, 0))
        elif typ == BYTE and count == 4:
            fh.write(struct.pack("<HHII", code, typ, count, value))
        else:
            fh.write(struct.pack("<HHII", code, typ, count, value))
    fh.write(struct.pack("<I", 0))
    fh.write(extra)
    fh.write(raw)
print(out, W, H, data_off + len(raw), "bytes")
