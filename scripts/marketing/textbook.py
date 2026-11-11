#!/usr/bin/env python3
"""教科書風のページの写真を作る(宣伝用の収録で、単元づくりの会話のカメラに差し込む)。

    textbook.py --serif NotoSerifCJK-Regular.ttc --serif-bold NotoSerifCJK-Bold.ttc --sans ZenKakuGothicNew-Bold.ttf out.jpg

実在の教科書は出版社の著作物で宣伝の映像に映せないので、文・例題・図はここで書いたもの(二次関数の最大・最小)。
机に置いたページを斜め上から撮ったように、傾き・影・明るさのむらを付ける。Claude の環境で作り、ブランチに置く。
"""
from __future__ import annotations

import argparse
import math

from PIL import Image, ImageDraw, ImageFilter, ImageFont

PW, PH = 1700, 2300
PAPER = (250, 248, 242)
INK = (30, 30, 34)
ACCENT = (38, 92, 160)
SOFT = (226, 236, 248)


def page(serif: str, serif_bold: str, sans: str) -> Image.Image:
    im = Image.new("RGB", (PW, PH), PAPER)
    d = ImageDraw.Draw(im)
    body = ImageFont.truetype(serif, 46)
    bold = ImageFont.truetype(serif_bold, 46)
    head = ImageFont.truetype(sans, 64)
    tag = ImageFont.truetype(sans, 40)
    small = ImageFont.truetype(serif, 36)

    d.rectangle((0, 0, PW, 130), fill=ACCENT)
    d.text((110, 34), "第3章  2次関数", font=ImageFont.truetype(sans, 52), fill=(255, 255, 255))
    d.text((110, 190), "3  2次関数の最大・最小", font=head, fill=ACCENT)
    d.line((110, 280, PW - 110, 280), fill=ACCENT, width=4)

    y = 320
    for line in ["2次関数 y = a(x − p)² + q のグラフは、a > 0 の", "とき下に凸の放物線である。このとき、y は頂点", "(p, q) で最も小さい値をとる。"]:
        d.text((110, y), line, font=body, fill=INK)
        y += 74

    # 図: 下に凸の放物線と頂点
    gx, gy, gw, gh = 1040, 560, 520, 480
    d.rounded_rectangle((gx, gy, gx + gw, gy + gh), 18, outline=(200, 205, 215), width=3)
    ox, oy = gx + 110, gy + gh - 90
    d.line((gx + 30, oy, gx + gw - 30, oy), fill=INK, width=3)
    d.line((ox, gy + 30, ox, gy + gh - 30), fill=INK, width=3)
    pts = []
    for i in range(-60, 61):
        x = i / 20
        px, py = ox + 190 + x * 80, oy - 60 - 0,
        pts.append((ox + 190 + x * 80, oy - 60 - (x * x) * 70 + 0))
    d.line([p for p in pts if p[1] > gy + 20], fill=ACCENT, width=6)
    d.ellipse((ox + 190 - 10, oy - 60 - 10, ox + 190 + 10, oy - 60 + 10), fill=ACCENT)
    d.line((ox + 190, gy + 40, ox + 190, oy), fill=(150, 160, 180), width=2)
    d.text((ox + 205, oy - 52), "(p, q)", font=small, fill=INK)
    d.text((ox + 196, oy + 6), "p", font=small, fill=INK)
    d.text((gx + gw - 60, oy + 6), "x", font=small, fill=INK)
    d.text((ox - 40, gy + 30), "y", font=small, fill=INK)

    def boxed(title: str, y0: int, lines: list[str], answer: list[str]) -> int:
        d.rounded_rectangle((110, y0, 980, y0 + 64), 12, fill=SOFT)
        d.text((134, y0 + 8), title, font=tag, fill=ACCENT)
        y1 = y0 + 92
        for line in lines:
            d.text((134, y1), line, font=body, fill=INK)
            y1 += 72
        for k, line in enumerate(answer):
            if k == 0:
                d.text((134, y1), "解", font=bold, fill=ACCENT)
            d.text((214, y1), line, font=body, fill=INK)
            y1 += 72
        return y1 + 30

    y = boxed("例題 5", 600, ["y = x² − 6x + 5 の最小値を求めよ。"],
              ["y = (x − 3)² − 4", "よって x = 3 のとき 最小値 −4", "最大値はない。"])
    y = max(y, gy + gh + 40)
    for line in ["定義域が決められているときは、頂点が定義域に", "含まれるかどうかを確かめ、端の値と比べる。"]:
        d.text((110, y), line, font=body, fill=INK)
        y += 74
    y = boxed("例題 6", y + 30, ["y = x² − 4x + 1 (0 ≦ x ≦ 3) の", "最大値と最小値を求めよ。"],
              ["y = (x − 2)² − 3", "x = 0 のとき 最大値 1", "x = 2 のとき 最小値 −3"])
    d.rounded_rectangle((110, y, PW - 110, y + 64), 12, outline=ACCENT, width=3)
    d.text((134, y + 8), "練習 10", font=tag, fill=ACCENT)
    d.text((330, y + 6), "次の2次関数の最大値・最小値を求めよ。", font=body, fill=INK)
    y += 96
    d.text((134, y), "(1) y = x² + 2x − 3", font=body, fill=INK)
    d.text((834, y), "(2) y = −x² + 4x (1 ≦ x ≦ 4)", font=body, fill=INK)
    d.text((PW // 2 - 20, PH - 90), "84", font=small, fill=(120, 120, 120))
    return im


def photo(im: Image.Image) -> Image.Image:
    """机に置いたページを撮った写真にする(縦 3:4)。"""
    W, H = 1500, 2000
    desk = Image.new("RGB", (W, H), (92, 78, 64))
    # 机の木目のむら
    dd = ImageDraw.Draw(desk)
    for y in range(0, H, 6):
        tone = int(10 * math.sin(y / 37) + 6 * math.sin(y / 11))
        dd.line((0, y, W, y), fill=(92 + tone, 78 + tone, 64 + tone), width=6)
    pg = im.resize((1360, 1840), Image.LANCZOS).rotate(-1.6, resample=Image.BICUBIC, expand=True, fillcolor=(0, 0, 0))
    mask = Image.new("L", (1360, 1840), 255).rotate(-1.6, resample=Image.BICUBIC, expand=True, fillcolor=0)
    shadow = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    shadow.paste(Image.new("RGBA", pg.size, (0, 0, 0, 120)), (78, 102), mask)
    desk = Image.alpha_composite(desk.convert("RGBA"), shadow.filter(ImageFilter.GaussianBlur(18))).convert("RGB")
    desk.paste(pg, (60, 70), mask)
    shade = Image.new("L", (W, H))
    shade.putdata([int(40 * (0.5 * x / W + 0.5 * y / H)) for y in range(H) for x in range(W)])
    desk = Image.composite(Image.new("RGB", (W, H), (0, 0, 0)), desk, shade)
    return desk.filter(ImageFilter.GaussianBlur(0.7))


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--serif", required=True)
    parser.add_argument("--serif-bold", required=True)
    parser.add_argument("--sans", required=True)
    parser.add_argument("out")
    args = parser.parse_args()
    photo(page(args.serif, args.serif_bold, args.sans)).save(args.out, quality=90)


if __name__ == "__main__":
    main()
