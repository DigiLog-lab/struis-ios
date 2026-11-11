"""宣伝の映像の場面(文字だけの場面と、ロゴの場面)と描画の道具。edit.py から使う。"""
import math, subprocess, sys, os, wave
import numpy as np
from pathlib import Path
ROOT = Path(__file__).resolve().parents[3]
OUT = Path(os.environ.get("MARKETING_OUT", "/tmp/marketing-edit"))
OUT.mkdir(parents=True, exist_ok=True)
from PIL import Image, ImageDraw, ImageFont, ImageFilter

W, H, FPS = 1080, 1920, 30
FONTDIR = str(ROOT / "strius/Resources/Fonts") + "/"
def F(size, w="Bold"):
    return ImageFont.truetype(FONTDIR + f"ZenKakuGothicNew-{w}.ttf", size)

GROUND = (29, 25, 21)
CARD = (45, 40, 33)
CARD_LOW = (39, 34, 28)
TXT = (239, 229, 210)
TXT2 = (174, 161, 140)
TXT3 = (124, 113, 97)
ACCENT = (212, 148, 90)
GROWTH = (127, 191, 149)
PAPER = (250, 246, 238)
INK = (52, 52, 58)
RED = (214, 23, 26)

def clamp(x, a=0.0, b=1.0): return max(a, min(b, x))
def ease(t): t = clamp(t); return 1 - (1 - t) ** 3
def ease_io(t): t = clamp(t); return t * t * (3 - 2 * t)
def prog(t, a, b): return clamp((t - a) / (b - a))

def text_layer(txt, font, color, alpha=1.0):
    bbox = font.getbbox(txt)
    w, h = bbox[2] - bbox[0], bbox[3] - bbox[1]
    im = Image.new("RGBA", (w + 20, h + 20), (0, 0, 0, 0))
    ImageDraw.Draw(im).text((10 - bbox[0], 10 - bbox[1]), txt, font=font, fill=color + (int(255 * alpha),))
    return im

def put_text(img, txt, font, color, cx, y, alpha=1.0, dy=0, anchor="center"):
    if alpha <= 0: return
    layer = text_layer(txt, font, color)
    if alpha < 1:
        a = layer.getchannel("A").point(lambda v: int(v * alpha))
        layer.putalpha(a)
    x = cx - layer.width // 2 if anchor == "center" else cx
    img.alpha_composite(layer, (int(x), int(y + dy)))

def rrect(size, radius, fill, ss=3, outline=None, width=0):
    w, h = size
    im = Image.new("RGBA", (w * ss, h * ss), (0, 0, 0, 0))
    ImageDraw.Draw(im).rounded_rectangle((0, 0, w * ss - 1, h * ss - 1), radius * ss, fill=fill,
                                         outline=outline, width=width * ss)
    return im.resize((w, h), Image.LANCZOS)

def circle(d, fill, ss=3, outline=None, width=0):
    im = Image.new("RGBA", (d * ss, d * ss), (0, 0, 0, 0))
    ImageDraw.Draw(im).ellipse((0, 0, d * ss - 1, d * ss - 1), fill=fill, outline=outline, width=width * ss)
    return im.resize((d, d), Image.LANCZOS)

def fade_ground(img, t, dur, fin=0.25, fout=0.25, color=GROUND):
    a = 0.0
    if t < fin: a = 1 - t / fin
    elif t > dur - fout: a = (t - (dur - fout)) / fout
    if a > 0:
        ov = Image.new("RGBA", img.size, color + (int(255 * clamp(a)),))
        img.alpha_composite(ov)

# ---------- logo ----------
icon = Image.open(str(ROOT / "strius/Assets.xcassets/AppIcon.appiconset/app-icon-1024.png")).convert("RGBA")
bg = (33, 25, 20)
px = icon.load()
for yy in range(icon.height):
    for xx in range(icon.width):
        r, g, b, _ = px[xx, yy]
        d = max(abs(r - bg[0]), abs(g - bg[1]), abs(b - bg[2]))
        px[xx, yy] = (r, g, b, int(clamp(d / 60) * 255))
LOGO = icon.crop((150, 150, 874, 874))

# ---------- phone screens ----------
PW, PH = 720, 1440
SW, SH = PW - 36, PH - 36
SCREEN_R = 78

def screen(problem_lines, num, hint, tag):
    s = Image.new("RGBA", (SW, SH), GROUND + (255,))
    d = ImageDraw.Draw(s)
    # tag chip
    chip = text_layer(tag, F(24, "Medium"), ACCENT)
    s.alpha_composite(rrect((chip.width + 28, 50), 25, (60, 46, 34)), (40, 200))
    s.alpha_composite(chip, (54, 205))
    # problem (top-aligned)
    y = 290
    for ln in problem_lines:
        put_text(s, ln, F(50, "Bold"), TXT, 44, y, anchor="left")
        y += 82
    put_text(s, hint, F(28, "Regular"), TXT3, 44, y + 18, anchor="left")
    # writing area hint
    for gy in range(y + 120, SH - 260, 64):
        d.line((44, gy, SW - 150, gy), fill=(52, 46, 39), width=2)
    return s

def chrome():
    s = Image.new("RGBA", (SW, SH), (0, 0, 0, 0))
    s.alpha_composite(rrect((132, 56), 28, CARD), (32, 92))
    put_text(s, "単元", F(26, "Medium"), TXT2, 32 + 66, 98)
    # right-bottom vertical buttons
    bx = SW - 92
    for i, lab in enumerate(["質問", "解説", "スキップ"]):
        cy = SH - 640 + i * 150
        s.alpha_composite(circle(84, CARD), (bx - 42, cy))
        dd = ImageDraw.Draw(s)
        if i == 0:
            dd.rounded_rectangle((bx - 18, cy + 26, bx + 18, cy + 52), 8, outline=TXT2, width=4)
        elif i == 1:
            dd.rectangle((bx - 16, cy + 24, bx + 16, cy + 58), outline=TXT2, width=4)
            dd.line((bx - 8, cy + 36, bx + 8, cy + 36), fill=TXT2, width=3)
        else:
            dd.line((bx, cy + 24, bx, cy + 58), fill=TXT2, width=5)
            dd.line((bx - 12, cy + 46, bx, cy + 58), fill=TXT2, width=5)
            dd.line((bx + 12, cy + 46, bx, cy + 58), fill=TXT2, width=5)
        put_text(s, lab, F(22, "Medium"), TXT2, bx, cy + 88)
    # camera button
    s.alpha_composite(circle(132, ACCENT), (SW // 2 - 66, SH - 200))
    dd = ImageDraw.Draw(s)
    cx, cy = SW // 2, SH - 134
    dd.rounded_rectangle((cx - 30, cy - 18, cx + 30, cy + 22), 8, outline=GROUND, width=5)
    dd.ellipse((cx - 11, cy - 7, cx + 11, cy + 15), outline=GROUND, width=5)
    dd.rectangle((cx - 12, cy - 26, cx + 8, cy - 18), fill=GROUND)
    return s

CHROME = chrome()
SCREENS = [
    screen(["2x + 3 = 11 を", "満たす x を求めなさい。"], 1, "1分くらい", "一次方程式"),
    screen(["x² − 5x + 6 = 0 を", "解きなさい。"], 2, "2分くらい", "二次方程式"),
    screen(["x² − 5x + 6 < 0 を", "満たす x の範囲を", "求めなさい。"], 3, "3分くらい", "二次不等式"),
]

mask = Image.new("L", (SW * 3, SH * 3), 0)
ImageDraw.Draw(mask).rounded_rectangle((0, 0, SW * 3 - 1, SH * 3 - 1), SCREEN_R * 3, fill=255)
SMASK = mask.resize((SW, SH), Image.LANCZOS)
BODY = rrect((PW, PH), SCREEN_R + 18, (12, 11, 10), outline=(70, 62, 52), width=3)
shadow = Image.new("RGBA", (PW + 200, PH + 200), (0, 0, 0, 0))
ImageDraw.Draw(shadow).rounded_rectangle((100, 120, PW + 100, PH + 120), 90, fill=(0, 0, 0, 150))
SHADOW = shadow.filter(ImageFilter.GaussianBlur(40))

def phone(scroll=0.0, a_idx=0, b_idx=1, mark=None):
    """scroll in [0,1]: A moves up and B comes from below."""
    sc = Image.new("RGBA", (SW, SH), GROUND + (255,))
    off = int(SH * scroll)
    sc.alpha_composite(SCREENS[a_idx], (0, -off)) if off < SH else None
    if scroll > 0:
        sc.alpha_composite(SCREENS[b_idx], (0, SH - off))
    sc.alpha_composite(CHROME)
    cnt = a_idx + 1 if scroll < 0.5 else b_idx + 1
    put_text(sc, f"{cnt}問目", F(26, "Medium"), TXT3, SW - 32 - 70, 100)
    p = Image.new("RGBA", (PW + 200, PH + 200), (0, 0, 0, 0))
    p.alpha_composite(SHADOW)
    p.alpha_composite(BODY, (100, 100))
    sc.putalpha(SMASK)
    p.alpha_composite(sc, (118, 118))
    # dynamic island
    p.alpha_composite(rrect((200, 58), 29, (0, 0, 0)), (100 + PW // 2 - 100, 140))
    return p

PHONE_X = (W - PW - 200) // 2
PHONE_Y = 250

def caption(img, txt, t, start=0.0, size=72, y=130, color=TXT):
    a = ease(prog(t, start, start + 0.45))
    put_text(img, txt, F(size, "Bold"), color, W // 2, y, alpha=a, dy=int(24 * (1 - a)))

# ---------- scenes ----------
def s1(t, dur):
    img = Image.new("RGBA", (W, H), GROUND + (255,))
    a1 = ease(prog(t, 0.2, 0.7)); a2 = ease(prog(t, 0.9, 1.4)); a3 = ease(prog(t, 1.8, 2.3))
    put_text(img, "やらなきゃ。", F(96), TXT, W // 2, 720, a1, int(30 * (1 - a1)))
    put_text(img, "わかってる。", F(96), TXT, W // 2, 860, a2, int(30 * (1 - a2)))
    put_text(img, "でも、身体が動かない。", F(56, "Medium"), TXT2, W // 2, 1060, a3, int(24 * (1 - a3)))
    fade_ground(img, t, dur, 0.2, 0.3)
    return img

def s2(t, dur):
    img = Image.new("RGBA", (W, H), GROUND + (255,))
    caption(img, "開けば、もう1問目がある。", t, 0.1, 68)
    rise = ease(prog(t, 0.3, 1.2))
    p = phone()
    img.alpha_composite(p, (PHONE_X, PHONE_Y + int(500 * (1 - rise))))
    fade_ground(img, t, dur, 0.15, 0.3)
    return img

HAND = F(92, "Medium")
def hand_line(img, txt, x, y, reveal, rot=-2.5):
    if reveal <= 0: return
    layer = text_layer(txt, HAND, INK)
    w = int(layer.width * reveal)
    m = Image.new("L", layer.size, 0)
    ImageDraw.Draw(m).rectangle((0, 0, w, layer.height), fill=255)
    a = Image.composite(layer.getchannel("A"), Image.new("L", layer.size, 0), m)
    layer.putalpha(a)
    layer = layer.rotate(rot, resample=Image.BICUBIC, expand=True)
    img.alpha_composite(layer, (x, y))

def red_circle(img, cx, cy, rx, ry, p, width=11):
    if p <= 0: return
    ss = 3
    layer = Image.new("RGBA", (W * ss // 3, H * ss // 3), (0, 0, 0, 0))
    big = Image.new("RGBA", ((2 * rx + 60) * ss, (2 * ry + 60) * ss), (0, 0, 0, 0))
    d = ImageDraw.Draw(big)
    n = int(80 * p)
    pts = []
    for i in range(n + 1):
        th = math.radians(-120 + 380 * i / 80)
        r_j = 1 + 0.03 * math.sin(i / 7)
        pts.append(((rx + 30 + rx * r_j * math.cos(th)) * ss, (ry + 30 + ry * r_j * math.sin(th)) * ss))
    if len(pts) > 1:
        d.line(pts, fill=RED + (235,), width=width * ss, joint="curve")
    big = big.resize((2 * rx + 60, 2 * ry + 60), Image.LANCZOS)
    img.alpha_composite(big, (cx - rx - 30, cy - ry - 30))

def s3(t, dur):
    img = Image.new("RGBA", (W, H), PAPER + (255,))
    d = ImageDraw.Draw(img)
    for gy in range(560, H, 90):
        d.line((0, gy, W, gy), fill=(222, 214, 200), width=2)
    d.line((150, 0, 150, H), fill=(236, 196, 190), width=3)
    a = ease(prog(t, 0.05, 0.45))
    put_text(img, "紙に書いて、撮るだけ。", F(72), (40, 34, 28), W // 2, 200, a, int(24 * (1 - a)))
    put_text(img, "2x + 3 = 11", F(54, "Medium"), (120, 110, 98), 200, 470, ease(prog(t, 0.2, 0.5)), anchor="left")
    hand_line(img, "2x = 8", 220, 760, ease_io(prog(t, 0.5, 1.2)))
    hand_line(img, "x = 4", 250, 960, ease_io(prog(t, 1.3, 1.9)))
    # viewfinder
    vp = ease(prog(t, 2.0, 2.45))
    if vp > 0 and t < 3.0:
        box = (150, 640, 930, 1200)
        grow = int(140 * (1 - vp))
        x0, y0, x1, y1 = box[0] - grow, box[1] - grow, box[2] + grow, box[3] + grow
        L = 90; c = (40, 34, 28, int(230 * vp))
        ov = Image.new("RGBA", img.size, (0, 0, 0, 0)); od = ImageDraw.Draw(ov)
        for (sx, sy, dx, dy) in [(x0, y0, 1, 1), (x1, y0, -1, 1), (x0, y1, 1, -1), (x1, y1, -1, -1)]:
            od.line((sx, sy, sx + dx * L, sy), fill=c, width=10)
            od.line((sx, sy, sx, sy + dy * L), fill=c, width=10)
        img.alpha_composite(ov)
    # flash
    fp = prog(t, 2.55, 2.95)
    if 0 < fp < 1:
        img.alpha_composite(Image.new("RGBA", img.size, (255, 255, 255, int(235 * (1 - fp)))))
    # red circle on the answer + check text
    red_circle(img, 420, 1035, 230, 110, ease_io(prog(t, 3.0, 3.6)))
    put_text(img, "正解", F(64), RED, 820, 990, ease(prog(t, 3.5, 3.8)), anchor="left")
    fade_ground(img, t, dur, 0.25, 0.3)
    return img

def s4(t, dur):
    img = Image.new("RGBA", (W, H), GROUND + (255,))
    caption(img, "次の1問が、もう待ってる。", t, 0.05, 68)
    # two swipes: 0->1 at 0.8-1.3, 1->2 at 2.3-2.8
    if t < 2.3:
        p = phone(ease_io(prog(t, 0.8, 1.35)), 0, 1)
    else:
        p = phone(ease_io(prog(t, 2.3, 2.85)), 1, 2)
    img.alpha_composite(p, (PHONE_X, PHONE_Y))
    put_text(img, "少しずつ、むずかしく。", F(44, "Medium"), TXT2, W // 2, 240, ease(prog(t, 1.6, 2.0)))
    fade_ground(img, t, dur, 0.25, 0.3)
    return img

DOT = circle(46, None, outline=GROWTH, width=6)
def s5(t, dur):
    img = Image.new("RGBA", (W, H), GROUND + (255,))
    n = int(round(50 * ease_io(prog(t, 0.4, 2.2))))
    # grid of marks
    for i in range(n):
        r, c = divmod(i, 10)
        img.alpha_composite(DOT, (115 + c * 88, 1180 + r * 88))
    a = ease(prog(t, 0.05, 0.4))
    put_text(img, "気づいたら、", F(64), TXT2, W // 2, 520, a, int(20 * (1 - a)))
    num = text_layer(str(max(n, 1)), F(260), ACCENT)
    unit = text_layer("問", F(110), ACCENT)
    tot = num.width + unit.width - 10
    x0 = W // 2 - tot // 2
    img.alpha_composite(num, (x0, 690))
    img.alpha_composite(unit, (x0 + num.width - 10, 690 + num.height - unit.height - 22))
    fade_ground(img, t, dur, 0.25, 0.35)
    return img

def s6(t, dur):
    img = Image.new("RGBA", (W, H), GROUND + (255,))
    a = ease(prog(t, 0.1, 0.8))
    size = int(300 + 30 * (1 - a))
    lg = LOGO.resize((size, size), Image.LANCZOS)
    if a < 1:
        lg.putalpha(lg.getchannel("A").point(lambda v: int(v * a)))
    img.alpha_composite(lg, (W // 2 - size // 2, 560 - (size - 300) // 2))
    b = ease(prog(t, 0.6, 1.1))
    put_text(img, "Struis", F(120), TXT, W // 2, 920, b, int(20 * (1 - b)))
    c = ease(prog(t, 1.3, 1.8))
    put_text(img, "やる気は、あとからついてくる。", F(52, "Medium"), TXT2, W // 2, 1110, c, int(20 * (1 - c)))
    e = ease(prog(t, 2.0, 2.4))
    put_text(img, "iPhone ・ iPad", F(38, "Medium"), TXT3, W // 2, 1560, e)
    fade_ground(img, t, dur, 0.2, 0.5)
    return img

SCENES = [(s1, 3.2), (s2, 3.0), (s3, 4.4), (s4, 4.0), (s5, 3.0), (s6, 3.8)]

def render(i):
    fn, dur = SCENES[i]
    n = int(round(dur * FPS))
    tmp = f"{OUT}/scene{i}.tmp.mp4"
    cmd = ["ffmpeg", "-y", "-loglevel", "error", "-f", "rawvideo", "-pix_fmt", "rgb24", "-s", f"{W}x{H}",
           "-r", str(FPS), "-i", "-", "-c:v", "libx264", "-preset", "veryfast", "-crf", "18",
           "-pix_fmt", "yuv420p", tmp]
    p = subprocess.Popen(cmd, stdin=subprocess.PIPE)
    for f in range(n):
        p.stdin.write(fn(f / FPS, dur).convert("RGB").tobytes())
    p.stdin.close()
    if p.wait() == 0:
        os.replace(tmp, f"{OUT}/scene{i}.mp4")

if __name__ == "__main__":
    if sys.argv[1] == "still":
        i, t = int(sys.argv[2]), float(sys.argv[3])
        fn, dur = SCENES[i]
        fn(t, dur).convert("RGB").save(f"{OUT}/still_{i}_{t}.jpg", quality=90)
    else:
        render(int(sys.argv[2]))


def soundtrack(events, D, path):
    """効果音と和音の下地を作って WAV に書く。events: [(種類, 秒)]。種類は pluck・chime・shutter・whoosh・cut。"""
    SR = 48000; n = int(SR * D); t = np.arange(n) / SR
    out = np.zeros(n); rng = np.random.default_rng(1)
    def pad(freqs, a, b, vol):
        m = (t >= a) & (t < b); tt = t[m] - a; L = b - a
        env = np.minimum(1, tt / 1.2) * np.minimum(1, (L - tt) / 1.2); s = np.zeros(m.sum())
        for k, f in enumerate(freqs):
            s += np.sin(2 * np.pi * f * tt + k) * (1 + 0.15 * np.sin(2 * np.pi * 0.3 * tt + k)) + 0.25 * np.sin(2 * np.pi * 2 * f * tt)
        out[m] += vol * env * s / len(freqs)
    pad([87.31, 174.61, 220, 261.63, 329.63, 392], 0, D - 3.4, 0.16)
    pad([116.54, 233.08, 293.66, 349.23, 440, 523.25], D - 4.0, D, 0.16)
    def pluck(at, f, vol=0.12):
        m = (t >= at) & (t < at + 1.2); tt = t[m] - at
        out[m] += vol * np.exp(-tt * 5) * (np.sin(2 * np.pi * f * tt) + 0.3 * np.sin(2 * np.pi * 2 * f * tt))
    scale = [523.25, 587.33, 659.25, 698.46, 783.99, 880, 1046.5]
    k = 0
    for kind, at in sorted(events, key=lambda e: e[1]):
        if at >= D: continue
        if kind == "pluck":
            pluck(at, scale[k % len(scale)]); k += 1
        elif kind == "chime":
            pluck(at, 783.99, 0.11); pluck(at + 0.12, 1046.5, 0.11)
        elif kind == "shutter":
            for off, amp, dec in [(0, 0.35, 60), (0.06, 0.25, 70)]:
                m = (t >= at + off) & (t < at + off + 0.12); tt = t[m] - at - off
                out[m] += amp * rng.standard_normal(m.sum()) * np.exp(-tt * dec)
        elif kind == "whoosh":
            L = 0.45; m = (t >= at - 0.15) & (t < at - 0.15 + L); tt = t[m] - at + 0.15
            nz = np.convolve(rng.standard_normal(m.sum()), np.ones(30) / 30, "same"); out[m] += 0.8 * nz * np.sin(np.pi * tt / L) ** 2
        elif kind == "cut":
            m = (t >= at) & (t < at + 0.05); tt = t[m] - at
            out[m] += 0.12 * rng.standard_normal(m.sum()) * np.exp(-tt * 120)
    out = out / np.max(np.abs(out)) * 0.7; fo = int(SR * 0.6); out[-fo:] *= np.linspace(1, 0, fo)
    pcm = (out * 32767).astype(np.int16)
    w = wave.open(path, "wb"); w.setnchannels(2); w.setsampwidth(2); w.setframerate(SR); w.writeframes(np.stack([pcm, pcm], 1).tobytes()); w.close()
