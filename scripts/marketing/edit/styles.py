"""紹介動画の編集のテイスト違い4案(Claude の環境で動かす。ffmpeg と Pillow が要る)。

    MARKETING_OUT=/tmp/out python3 scripts/marketing/edit/styles.py A <timeline.mp4> <unit.mp4> [KleeOne-SemiBold.ttf]

A テンポ: 画面収録を全画面で、短いカットと大きな1語(選ぶ・撮る・○・次)。ループごとに速くする。
B 等身大: 上の余白に低いテンションの字幕、下に解いた問題数。採点待ちは早送り、○の瞬間だけ等速で寄る。
C 明るい: クリーム色の背景に端末を大きく置き、ゆっくり寄る。見出しは左上。
D ノート: 罫線の紙の背景に手書きの字(Klee One、SIL Open Font License)で答案が書かれ、○が付くと紙にも赤ペンで丸。
録画は intro.py と同じ(takes/demo1.json と takes/unit-select.json、2026-11-14)。最初に 1080 幅・30fps に直してから使う。
下の秒(TL・UNIT)は、30fps に直した録画を見て決めた値。録り直したら見直す。
"""
from __future__ import annotations

import hashlib, math, os, random, subprocess, sys

from PIL import Image, ImageDraw, ImageFilter, ImageFont

STYLE = sys.argv[1]
TL_SRC, UNIT_SRC = sys.argv[2], sys.argv[3]
KLEE = sys.argv[4] if len(sys.argv) > 4 else ""
sys.argv = [sys.argv[0], "noop"]
import scenes as M  # noqa: E402

W, H, FPS = M.W, M.H, M.FPS
OUT = str(M.OUT / "styles")
os.makedirs(OUT, exist_ok=True)
SRC_W, SRC_H = 1080, 2348  # 全画面用に直した録画の大きさ(元は 1206x2622)

# 録画の中の出来事(30fps に直した timeline の秒)。P1〜P5 は1〜5問目。
TL = {
    "p1": 0.0, "shot1": 4.4, "close1": 8.6, "maru1": 16.0, "next1": 27.3,
    "p2": 27.8, "shot2": 35.2, "close2": 37.6, "maru2": 47.9, "next2": 53.7,
    "p3": 54.3, "shot3": 61.2, "close3": 64.5, "maru3": 71.9, "next3": 81.6,
    "p4": 82.1, "shot4": 102.3, "maru4": 114.2, "next4": 124.6, "p5": 125.1,
}
# 単元づくりの録画(30fps に直した unit の秒)
UNIT = {"intent": 2.0, "pick": 5.6, "pick_end": 12.6, "plan": 34.0, "start": 39.5, "unitpage": 43.0}


def cfr(src: str) -> str:
    """可変フレームレートの録画を 1080 幅・30fps に直す(同じ録画は使い回す)。"""
    st = os.stat(src)
    key = hashlib.sha1(f"{os.path.abspath(src)}:{st.st_size}:{st.st_mtime_ns}".encode()).hexdigest()[:12]
    out = str(M.OUT / f"full30-{key}.mp4")
    if not os.path.exists(out):
        tmp = out[:-4] + ".tmp.mp4"
        subprocess.run(["ffmpeg", "-v", "error", "-y", "-i", src, "-vf", f"fps={FPS},scale={SRC_W}:{SRC_H}:flags=lanczos",
                        "-c:v", "libx264", "-preset", "veryfast", "-crf", "15", "-g", "30", "-pix_fmt", "yuv420p", tmp], check=True)
        os.replace(tmp, out)
    return out


SRC = {"tl": TL_SRC, "unit": UNIT_SRC}


def nframes(a: float, b: float, speed: float = 1.0) -> int:
    return max(1, int(round((b - a) / speed * FPS)))


def clip(name: str, a: float, b: float, speed: float = 1.0, w: int = SRC_W, h: int = SRC_H):
    """録画の区間を speed 倍速で、w×h の絵として順に返す(足りない分は最後の絵を繰り返す)。"""
    n = nframes(a, b, speed)
    vf = f"setpts=(PTS-STARTPTS)/{speed},fps={FPS}" + (f",scale={w}:{h}:flags=bicubic" if (w, h) != (SRC_W, SRC_H) else "")
    # 足りた所で ffmpeg を止めるので、止めた時の「Broken pipe」は捨てる。
    p = subprocess.Popen(["ffmpeg", "-v", "error", "-ss", str(a), "-to", str(b), "-i", cfr(SRC[name]), "-vf", vf,
                          "-f", "rawvideo", "-pix_fmt", "rgb24", "-"], stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
    size, last = w * h * 3, None
    try:
        for _ in range(n):
            buf = p.stdout.read(size)
            if len(buf) == size:
                last = Image.frombytes("RGB", (w, h), buf)
            yield last
    finally:
        p.stdout.close()
        p.kill()
        p.wait()


def hold(img, seconds: float):
    for _ in range(int(round(seconds * FPS))):
        yield img


# ---------- 部品 ----------
def font(size, weight="Bold"):
    return M.F(size, weight)


def klee(size):
    return ImageFont.truetype(KLEE, size) if KLEE else M.F(size, "Medium")


def text(img, s, f, color, x, y, alpha=1.0, anchor="center", dy=0):
    if alpha <= 0:
        return
    layer = M.text_layer(s, f, color)
    if alpha < 1:
        layer.putalpha(layer.getchannel("A").point(lambda v: int(v * alpha)))
    px = x - layer.width // 2 if anchor == "center" else x
    img.alpha_composite(layer, (int(px), int(y + dy)))


def rmask(w, h, r, ss=3):
    m = Image.new("L", (w * ss, h * ss), 0)
    ImageDraw.Draw(m).rounded_rectangle((0, 0, w * ss - 1, h * ss - 1), r * ss, fill=255)
    return m.resize((w, h), Image.LANCZOS)


class Phone:
    """端末の枠(画面の大きさ sw×sh)。"""
    def __init__(self, sw, sh, shadow_alpha=160, body=(12, 11, 10), edge=(70, 62, 52)):
        self.sw, self.sh = sw, sh
        self.bz = max(10, sw // 36)
        r = int(sw * 0.14)
        self.mask = rmask(sw, sh, r)
        pw, ph = sw + 2 * self.bz, sh + 2 * self.bz
        self.pw, self.ph = pw, ph
        self.body = M.rrect((pw, ph), r + self.bz, body, outline=edge, width=3)
        sh_img = Image.new("RGBA", (pw + 200, ph + 200), (0, 0, 0, 0))
        ImageDraw.Draw(sh_img).rounded_rectangle((100, 125, pw + 100, ph + 125), r + 20, fill=(0, 0, 0, shadow_alpha))
        self.shadow = sh_img.filter(ImageFilter.GaussianBlur(40))

    def layer(self, screen: Image.Image) -> Image.Image:
        """影ごと描いた端末(左上が影の分 100px ずれる)。"""
        out = Image.new("RGBA", (self.pw + 200, self.ph + 200), (0, 0, 0, 0))
        out.alpha_composite(self.shadow)
        out.alpha_composite(self.body, (100, 100))
        scr = screen if screen.size == (self.sw, self.sh) else screen.resize((self.sw, self.sh), Image.BICUBIC)
        out.paste(scr, (100 + self.bz, 100 + self.bz), self.mask)
        return out


def zoom_crop(img: Image.Image, k: float, fx: float, fy: float, out_size) -> Image.Image:
    """img を k 倍に寄せる。寄る先は (fx, fy)(0〜1)。"""
    w, h = img.size
    cw, ch = w / k, h / k
    x0 = min(max(0, fx * w - cw / 2), w - cw)
    y0 = min(max(0, fy * h - ch / 2), h - ch)
    return img.resize(out_size, Image.BICUBIC, box=(x0, y0, x0 + cw, y0 + ch))


def tinted_logo(color):
    """ロゴの白い部分を color に替える(明るい背景用)。"""
    lg = M.LOGO.copy()
    px = lg.load()
    for y in range(lg.height):
        for x in range(lg.width):
            r, g, b, a = px[x, y]
            if a and min(r, g, b) > 170 and max(r, g, b) - min(r, g, b) < 40:
                px[x, y] = color + (a,)
    return lg


# ---------- 書き出し ----------
class Cut:
    """1つの場面: frames(絵を順に返す)と、場面の頭からの秒で書いた音の出来事。"""
    def __init__(self, frames, n, events=()):
        self.frames, self.n, self.events = frames, n, list(events)


def encode(name: str, cut: Cut) -> None:
    tmp = f"{OUT}/{name}.tmp.mp4"
    p = subprocess.Popen(["ffmpeg", "-y", "-loglevel", "error", "-f", "rawvideo", "-pix_fmt", "rgb24", "-s", f"{W}x{H}",
                          "-r", str(FPS), "-i", "-", "-c:v", "libx264", "-preset", "veryfast", "-crf", "18", "-pix_fmt", "yuv420p", tmp],
                         stdin=subprocess.PIPE)
    k = 0
    for img in cut.frames:
        if k >= cut.n:
            break
        p.stdin.write(img.convert("RGB").tobytes())
        k += 1
    while k < cut.n:  # 足りなければ最後の絵で埋める
        p.stdin.write(img.convert("RGB").tobytes())
        k += 1
    p.stdin.close()
    if p.wait() == 0:
        os.replace(tmp, f"{OUT}/{name}.mp4")


def build(style: str, cuts: list[Cut]) -> None:
    files, events, offset = [], [], 0.0
    only = os.environ.get("ONLY")
    for k, cut in enumerate(cuts):
        if not only or str(k) in only.split(","):
            encode(f"{style}{k}", cut)
        files.append(f"{OUT}/{style}{k}.mp4")
        events += [(kind, offset + t) for kind, t in cut.events]
        offset += cut.n / FPS
    with open(f"{OUT}/{style}.txt", "w") as f:
        f.writelines(f"file '{p}'\n" for p in files)
    silent, audio, final = f"{OUT}/{style}_silent.mp4", f"{OUT}/{style}.wav", f"{OUT}/struis_intro_{style}.mp4"
    subprocess.run(["ffmpeg", "-y", "-loglevel", "error", "-f", "concat", "-safe", "0", "-i", f"{OUT}/{style}.txt", "-c", "copy", silent], check=True)
    M.soundtrack(events, offset, audio)
    subprocess.run(["ffmpeg", "-y", "-loglevel", "error", "-i", silent, "-i", audio, "-map", "0:v", "-map", "1:a",
                    "-c:v", "copy", "-c:a", "aac", "-b:a", "192k", "-shortest", final], check=True)
    print(final, round(offset, 2))


# ---------- A: テンポ ----------
def style_a() -> list[Cut]:
    G = M.GROUND
    shade = Image.new("RGBA", (W, 700), (0, 0, 0, 0))
    shade.putalpha(Image.linear_gradient("L").resize((W, 700)).point(lambda v: int(v * 0.85)))
    shade = Image.composite(Image.new("RGBA", (W, 700), (10, 9, 8, 255)), shade, shade.getchannel("A"))
    beats = [  # (録画, 始め, 終わり, 倍速, 1語, 音)
        ("unit", UNIT["intent"], 3.8, 1.5, "選ぶ", "pluck"), ("unit", UNIT["pick"], 11.6, 3.0, "選ぶ", "cut"),
        ("unit", UNIT["plan"], 35.6, 1.0, "計画", "chime"),
        ("tl", 0.3, 1.5, 1.0, "解く", "pluck"), ("tl", TL["shot1"], 5.4, 1.0, "撮る", "shutter"),
        ("tl", TL["maru1"] + 0.3, 17.6, 1.0, "○", "chime"), ("tl", TL["next1"] - 0.1, 28.4, 1.0, "次", "whoosh"),
        ("tl", TL["shot2"], 36.0, 1.0, "撮る", "shutter"), ("tl", TL["maru2"] + 0.3, 49.1, 1.0, "○", "chime"),
        ("tl", TL["next2"] - 0.1, 54.6, 1.0, "次", "whoosh"),
        ("tl", TL["shot3"] + 0.3, 62.2, 1.0, "撮る", "shutter"), ("tl", TL["maru3"] + 0.3, 72.9, 1.0, "○", "chime"),
        ("tl", TL["next3"], 82.4, 1.0, "次", "whoosh"),
        ("tl", TL["shot4"] + 0.2, 103.1, 1.0, "撮る", "shutter"), ("tl", TL["maru4"] + 0.3, 115.1, 1.0, "○", "chime"),
        ("tl", TL["next4"], 125.3, 1.0, "次", "whoosh"),
    ]

    def frames():
        for name, a, b, speed, word, _ in beats:
            for i, src in enumerate(clip(name, a, b, speed)):
                t = i / FPS
                k = 1.0 + 0.07 * (1 - M.ease(M.prog(t, 0.0, 0.3)))  # 切り替わりで少し寄った所から引く
                img = Image.new("RGBA", (W, H), G + (255,))
                scr = src.crop((0, 0, SRC_W, H)) if k <= 1.001 else zoom_crop(src.crop((0, 0, SRC_W, H)), k, 0.5, 0.45, (W, H))
                img.paste(scr, (0, 0))
                img.alpha_composite(shade, (0, H - 700))
                pop = M.ease(M.prog(t, 0.0, 0.16))
                size = int(170 + 50 * (1 - pop))
                color = M.GROWTH if word == "○" else (M.ACCENT if word in ("撮る", "計画") else M.TXT)
                text(img, word, font(size), color, W // 2, 1560 - (size - 170) // 2, min(1, pop * 1.6))
                yield img

    events, t = [], 0.0
    for name, a, b, speed, word, sound in beats:
        events.append(("cut", t))
        events.append((sound, t + (0.05 if sound != "chime" else 0.25)))
        t += nframes(a, b, speed) / FPS
    body = Cut(frames(), int(round(t * FPS)), events)
    return [body, end_card("撮って、○、次。", M.GROUND, M.TXT, M.TXT2, M.LOGO, 2.8)]


def end_card(tagline, ground, txt, txt2, logo, dur, tagline_font=None, sub="iPhone ・ iPad"):
    def frames():
        for i in range(int(round(dur * FPS))):
            t = i / FPS
            img = Image.new("RGBA", (W, H), ground + (255,))
            a = M.ease(M.prog(t, 0.1, 0.8))
            size = int(300 + 30 * (1 - a))
            lg = logo.resize((size, size), Image.LANCZOS)
            if a < 1:
                lg.putalpha(lg.getchannel("A").point(lambda v: int(v * a)))
            img.alpha_composite(lg, (W // 2 - size // 2, 560 - (size - 300) // 2))
            b = M.ease(M.prog(t, 0.5, 1.0))
            text(img, "Struis", font(120), txt, W // 2, 920, b, dy=int(20 * (1 - b)))
            c = M.ease(M.prog(t, 1.1, 1.6))
            text(img, tagline, tagline_font or font(52, "Medium"), txt2, W // 2, 1110, c, dy=int(20 * (1 - c)))
            e = M.ease(M.prog(t, 1.7, 2.1))
            text(img, sub, font(38, "Medium"), txt2, W // 2, 1560, e * 0.8)
            M.fade_ground(img, t, dur, 0.15, 0.4, color=ground)
            yield img
    return Cut(frames(), int(round(dur * FPS)), [("pluck", 0.2), ("pluck", 0.7), ("pluck", 1.3)])


# ---------- B: 等身大 ----------
def style_b() -> list[Cut]:
    G = M.GROUND
    SW, SH = 740, 1609  # 画面の大きさ(端末の枠は付けない)
    SX, SY = (W - SW) // 2, 170
    mask = rmask(SW, SH, 58)
    shots = [  # (録画, 始め, 終わり, 倍速, 上の字幕, 解いた数, 寄り: (始め, 終わり, 倍率, fx, fy) or None, 音)
        ("tl", 0.0, 2.6, 1, "1問だけ、やるか。", 0, None, []),
        ("tl", TL["shot1"], 6.0, 1, "書いて、撮る。", 0, None, [("shutter", 1.4)]),
        ("tl", TL["close1"], TL["maru1"], 4, "……", 0, None, []),
        ("tl", TL["maru1"], 18.6, 1, "", 1, (0.2, 0.9, 1.55, 0.28, 0.33), [("chime", 0.45)]),
        ("tl", TL["next1"] - 0.2, 29.2, 1, "……もう1問だけ。", 1, None, [("whoosh", 0.2)]),
        ("tl", TL["shot2"], 36.4, 1, "", 1, None, [("shutter", 1.0)]),
        ("tl", TL["close2"] + 0.6, TL["maru2"], 6, "……", 1, None, []),
        ("tl", TL["maru2"], 49.6, 1, "", 2, (0.15, 0.8, 1.5, 0.28, 0.33), [("chime", 0.4)]),
        ("tl", TL["next2"] - 0.2, 55.6, 1, "あと1問。", 2, None, [("whoosh", 0.2)]),
        ("tl", TL["shot3"] + 0.2, 62.6, 1, "", 2, None, [("shutter", 1.0)]),
        ("tl", TL["close3"] + 0.4, TL["maru3"], 5, "……", 2, None, []),
        ("tl", TL["maru3"], 73.6, 1, "", 3, (0.15, 0.8, 1.5, 0.28, 0.33), [("chime", 0.4)]),
        ("tl", TL["next3"] - 0.2, 83.6, 1, "……あと1問だけ。", 3, None, [("whoosh", 0.2)]),
    ]

    def frames():
        last_cap = None
        cap_start = 0.0
        t0 = 0.0
        for name, a, b, speed, cap, solved, zoom, _ in shots:
            if cap and cap != last_cap:
                last_cap, cap_start = cap, t0
            n = nframes(a, b, speed)
            for i, src in enumerate(clip(name, a, b, speed, SRC_W, SRC_H)):
                t = i / FPS
                gt = t0 + t
                img = Image.new("RGBA", (W, H), G + (255,))
                if zoom:
                    z0, z1, k, fx, fy = zoom
                    p = M.ease_io(M.prog(t, z0, z1))
                    scr = zoom_crop(src, 1 + (k - 1) * p, fx, fy, (SW, SH))
                else:
                    scr = src.resize((SW, SH), Image.BICUBIC)
                img.paste(scr, (SX, SY), mask)
                if last_cap:
                    a_ = M.ease(M.prog(gt - cap_start, 0.0, 0.5))
                    text(img, last_cap, font(48, "Medium"), M.TXT2, W // 2, 62, a_, dy=int(10 * (1 - a_)))
                text(img, f"今日 {solved}問", font(36, "Medium"), M.TXT3, W // 2, SY + SH + 42)
                if gt < 0.3:
                    M.fade_ground(img, gt, 99, 0.3, 0.0)
                yield img
            t0 += n / FPS
        # 終わり: 字幕だけ残してロゴへ
    events, t = [], 0.0
    for name, a, b, speed, cap, solved, zoom, ev in shots:
        events += [(k, t + s) for k, s in ev]
        t += nframes(a, b, speed) / FPS
    body = Cut(frames(), int(round(t * FPS)), events)
    return [body, end_card("1問だけ、のつもりで。", G, M.TXT, M.TXT2, M.LOGO, 3.2)]


# ---------- C: 明るい ----------
CREAM = (244, 239, 230)
INK_C = (44, 36, 28)
INK_C2 = (126, 112, 96)
ACC_C = (196, 116, 52)


def style_c() -> list[Cut]:
    phone = Phone(700, 1522, shadow_alpha=70, body=(24, 22, 20), edge=(24, 22, 20))
    scenes = [  # (見出し2行, [(録画, 始め, 終わり, 倍速)], 音)
        (("範囲を、", "選ぶ。"), [("unit", UNIT["intent"], 12.6, 3.0)], [("pluck", 0.3)]),
        (("計画が、", "できる。"), [("unit", UNIT["plan"], 37.4, 1.0)], [("chime", 0.3)]),
        (("開けば、", "1問目。"), [("tl", 0.0, 2.8, 1.0)], [("pluck", 0.3)]),
        (("書いて、", "撮る。"), [("tl", TL["shot1"], 6.4, 1.0), ("tl", TL["close1"], 9.6, 1.0)], [("shutter", 2.4)]),
        (("○が、", "つく。"), [("tl", TL["maru1"] + 0.3, 19.3, 1.0)], [("chime", 0.2)]),
        (("次の1問へ。", ""), [("tl", TL["next1"] - 0.3, 29.4, 1.0), ("tl", TL["next2"] - 0.3, 55.8, 1.0)], [("whoosh", 0.3), ("whoosh", 2.4)]),
    ]
    cuts = []
    for (l1, l2), parts, ev in scenes:
        n = sum(nframes(a, b, s) for _, a, b, s in parts)

        def frames(parts=parts, l1=l1, l2=l2, n=n):
            i = 0
            for name, a, b, s in parts:
                for src in clip(name, a, b, s, 700, 1522):
                    t = i / FPS
                    dur = n / FPS
                    img = Image.new("RGBA", (W, H), CREAM + (255,))
                    a1 = M.ease(M.prog(t, 0.05, 0.5))
                    a2 = M.ease(M.prog(t, 0.25, 0.7))
                    text(img, l1, font(92), INK_C, 96, 150, a1, anchor="left", dy=int(20 * (1 - a1)))
                    if l2:
                        text(img, l2, font(92), ACC_C, 96, 270, a2, anchor="left", dy=int(20 * (1 - a2)))
                    drift = t / max(dur, 0.1)
                    k = 1.0 + 0.05 * drift  # ゆっくり寄る
                    ph = phone.layer(src)
                    pw, phh = int(ph.width * k), int(ph.height * k)
                    ph = ph.resize((pw, phh), Image.BICUBIC)
                    img.alpha_composite(ph, ((W - pw) // 2 + 60, int(480 - 30 * drift) - 100))
                    M.fade_ground(img, t, dur, 0.18, 0.18, color=CREAM)
                    i += 1
                    yield img
        cuts.append(Cut(frames(), n, ev))
    cuts.append(end_card("書いて、撮るだけ。", CREAM, INK_C, INK_C2, tinted_logo(INK_C), 3.2))
    return cuts


# ---------- D: ノート ----------
PAPER = (250, 247, 240)
RULE = (200, 212, 228)
MARGIN = (232, 186, 182)
INK_D = (38, 40, 62)
ANSWERS = [
    ["y = (x−2)² + 3", "頂点 (2, 3)"],
    ["y = (x+3)² − 4", "頂点 (−3, −4)"],
    ["y = x² − 4x + 1", "  = (x−2)² − 4 + 1", "  = (x−2)² − 3", "頂点 (2, −3)"],
]
PITCH = 96


def paper_ground() -> Image.Image:
    img = Image.new("RGBA", (W, H), PAPER + (255,))
    d = ImageDraw.Draw(img)
    for y in range(212, H, PITCH):
        d.line((0, y, W, y), fill=RULE + (255,), width=2)
    d.line((112, 0, 112, H), fill=MARGIN + (255,), width=3)
    return img


class Hand:
    """手書きの字を1字ずつ出す(字ごとに少しずらす)。"""
    def __init__(self, lines, x, y, size, seed):
        rng = random.Random(seed)
        self.glyphs = []
        for row, line in enumerate(lines):
            cx = x + rng.randint(-4, 8)
            for ch in line:
                f = klee(size + rng.randint(-3, 3))
                self.glyphs.append((ch, cx, y + row * PITCH + rng.randint(-3, 3), f))
                cx += f.getlength(ch) + rng.randint(-1, 2)
        self.last_line_box = None
        last_row = len(lines) - 1
        lx0 = x
        lx1 = max(g[1] + g[3].getlength(g[0]) for g in self.glyphs[-len(lines[-1]):]) if lines[-1] else x
        self.last_line_box = (lx0, y + last_row * PITCH, lx1, y + last_row * PITCH + size)

    def draw(self, img, p):
        n = int(len(self.glyphs) * M.clamp(p) + 0.999) if p > 0 else 0
        d = ImageDraw.Draw(img)
        for ch, x, y, f in self.glyphs[:n]:
            d.text((x, y), ch, font=f, fill=INK_D + (255,))


def style_d() -> list[Cut]:
    ground = paper_ground()
    phone = Phone(540, 1174, shadow_alpha=80, body=(24, 22, 20), edge=(24, 22, 20))
    PX, PY = W - phone.pw - 60, 690  # 端末の左上(影の分は layer の中で 100 ずれる)
    caption_y = 86
    probs = [  # (答案, [(区間, 字幕, 書く進み(始め,終わり) or None, 丸(始め,終わり) or None)], 音)
        (0, [((0.0, 2.8, 1), "書いて、", (0.1, 2.6), None),
             ((TL["shot1"], 6.2, 1), "撮って、", None, None),
             ((TL["close1"], 9.6, 1), "撮って、", None, None),
             ((TL["maru1"] - 0.1, 18.8, 1), "○。", None, (0.3, 1.1))],
         [("pluck", 0.2), ("shutter", 4.0), ("chime", 5.4)]),
        (1, [((TL["next1"] - 0.2, 29.6, 1), "もう1問。", (0.2, 1.8), None),
             ((TL["shot2"], 36.4, 1), "撮って、", None, None),
             ((TL["maru2"] - 0.1, 49.6, 1), "○。", None, (0.2, 0.9))],
         [("whoosh", 0.2), ("shutter", 2.6), ("chime", 3.5)]),
        (2, [((TL["next2"] - 0.2, 56.2, 1), "少しずつ、むずかしく。", (0.2, 2.4), None),
             ((TL["shot3"] + 0.2, 62.6, 1), "撮って、", None, None),
             ((TL["maru3"] - 0.1, 73.8, 1), "○。", None, (0.2, 0.9))],
         [("whoosh", 0.2), ("shutter", 3.6), ("chime", 4.5)]),
    ]
    cuts = []
    for idx, parts, ev in probs:
        hand = Hand(ANSWERS[idx], 150, 232, 62, seed=idx + 3)
        n = sum(nframes(a, b, s) for (a, b, s), *_ in parts)

        def frames(parts=parts, hand=hand, n=n):
            i = 0
            written, circled = 0.0, 0.0
            cap_prev, cap_t = None, 0.0
            for (a, b, s), cap, write, maru in parts:
                k0 = i
                for src in clip("tl", a, b, s, 540, 1174):
                    t, lt = i / FPS, (i - k0) / FPS
                    img = ground.copy()
                    if cap != cap_prev:
                        cap_prev, cap_t = cap, t
                    ca = M.ease(M.prog(t - cap_t, 0.0, 0.35))
                    text(img, cap, klee(72), INK_D, 150, caption_y, ca, anchor="left")
                    if write:
                        written = max(written, M.prog(lt, *write))
                    hand.draw(img, written if write or written else 0)
                    if maru:
                        circled = max(circled, M.prog(lt, *maru))
                    if circled > 0:
                        x0, y0, x1, y1 = hand.last_line_box
                        M.red_circle(img, int((x0 + x1) / 2), int((y0 + y1) / 2) + 4, int((x1 - x0) / 2) + 40, 44, circled, width=7)
                    img.alpha_composite(phone.layer(src), (PX - 100, PY - 100))
                    M.fade_ground(img, t, n / FPS, 0.15, 0.2, color=PAPER)
                    i += 1
                    yield img
        cuts.append(Cut(frames(), n, ev))
    logo = tinted_logo(INK_D)
    end = end_card("いつものノートで。", PAPER, INK_D, INK_D, logo, 3.2, tagline_font=klee(60))
    cuts.append(end)
    return cuts


if __name__ == "__main__":
    cuts = {"A": style_a, "B": style_b, "C": style_c, "D": style_d}[STYLE]()
    if os.environ.get("STILL"):
        # STILL=場面@秒 で1枚だけ描く(書き出しの前の確認用)
        k, t = os.environ["STILL"].split("@")
        cut = cuts[int(k)]
        target = int(float(t) * FPS)
        for i, img in enumerate(cut.frames):
            if i == target:
                img.convert("RGB").save(f"{OUT}/still_{STYLE}{k}_{t}.jpg", quality=88)
                break
    else:
        build(STYLE, cuts)
