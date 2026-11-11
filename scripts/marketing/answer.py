#!/usr/bin/env python3
"""手書き風の答案の写真を作る(宣伝用の収録で、シミュレータのカメラに差し込む)。

    answer.py --font KleeOne-Regular.ttf out.jpg "y = (x-2)^2 + 3" "頂点 (2, 3)"

ノートを斜め上から撮ったような写真にする: 罫線のある紙、行ごとに少しずつずれる字、わずかな傾き・ぼけ・明るさのむら。
字は Klee One(SIL Open Font License、Google Fonts)を想定する。`^2` は上付きの ² に替える。
同じ引数なら同じ画像になる(乱数の種を本文から決める)。Dev Box(Pillow が無い)ではなく Claude の環境で作り、ブランチに置く。
"""
from __future__ import annotations

import argparse
import hashlib
import random

from PIL import Image, ImageDraw, ImageFilter, ImageFont

W, H = 1500, 2000
PAPER = (247, 244, 236)
RULE = (196, 210, 228)
INK = (38, 40, 62)


def render(lines: list[str], font_path: str, size: int = 104) -> Image.Image:
    seed = int(hashlib.sha1("\n".join(lines).encode()).hexdigest()[:8], 16)
    rng = random.Random(seed)
    paper = Image.new("RGB", (W, H), PAPER)
    draw = ImageDraw.Draw(paper)
    pitch = 150
    for y in range(260, H - 80, pitch):
        draw.line((60, y, W - 60, y), fill=RULE, width=3)
    draw.line((190, 0, 190, H), fill=(232, 190, 186), width=3)
    font = ImageFont.truetype(font_path, size)
    y = 260 + pitch - size - 30
    for line in lines:
        text = line.replace("^2", "²").replace("^3", "³").replace("-", "−")
        x = 240 + rng.randint(-10, 16)
        for ch in text:
            # 字ごとに少しずつ上下・大きさをずらす(印刷の並びに見えないように)。
            f = ImageFont.truetype(font_path, size + rng.randint(-5, 4))
            draw.text((x, y + rng.randint(-5, 5)), ch, font=f, fill=INK)
            x += draw.textlength(ch, font=f) + rng.randint(-2, 3)
        y += pitch * (2 if len(lines) <= 3 else 1)
    paper = paper.rotate(rng.uniform(-2.2, 2.2), resample=Image.BICUBIC, expand=False, fillcolor=(120, 112, 100))
    # 明るさのむら(上が明るく、右下が少し暗い)。
    shade = Image.new("L", (W, H))
    shade.putdata([int(34 * (0.55 * x / W + 0.45 * y / H)) for y in range(H) for x in range(W)])
    dark = Image.new("RGB", (W, H), (0, 0, 0))
    paper = Image.composite(dark, paper, shade)
    return paper.filter(ImageFilter.GaussianBlur(0.9))


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--font", required=True)
    parser.add_argument("out")
    parser.add_argument("lines", nargs="+")
    args = parser.parse_args()
    render(args.lines, args.font).save(args.out, quality=88)


if __name__ == "__main__":
    main()
