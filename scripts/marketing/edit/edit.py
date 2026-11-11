"""宣伝の映像の編集(Claude の環境で動かす。ffmpeg と Pillow が要る)。

    MARKETING_OUT=/tmp/out python3 scripts/marketing/edit/edit.py <take.mp4>

take.mp4 は take.py の録画(可変フレームレート)。最初に 30fps の固定に直してから区間を切り出す(可変のままだと
区間の頭出しがずれる)。場面ごとに1本の mp4 を作り、最後に concat でつなぐ。音は別に作って重ねる。
区間(録画の秒)は take.py の録画を見て決めた値で、録り直したら見直す。
"""
import os, subprocess, sys, math
import numpy as np
from PIL import Image, ImageDraw, ImageFilter
TAKE_SRC = sys.argv[1] if len(sys.argv) > 1 else ""
sys.argv = [sys.argv[0], "noop"]
import scenes as M  # s1, s5, s6 と描画の道具

W, H, FPS = M.W, M.H, M.FPS
TAKE = str(M.OUT / "take30.mp4")
SW, SH = 660, 1434
BZ = 18
PW, PH = SW + 2 * BZ, SH + 2 * BZ
PX, PY = (W - PW) // 2, 330
R = 92

def rmask(w, h, r, ss=3):
    m = Image.new("L", (w * ss, h * ss), 0)
    ImageDraw.Draw(m).rounded_rectangle((0, 0, w * ss - 1, h * ss - 1), r * ss, fill=255)
    return m.resize((w, h), Image.LANCZOS)

SMASK = rmask(SW, SH, R)
BODY = M.rrect((PW, PH), R + BZ, (12, 11, 10), outline=(70, 62, 52), width=3)
sh = Image.new("RGBA", (PW + 200, PH + 200), (0, 0, 0, 0))
ImageDraw.Draw(sh).rounded_rectangle((100, 125, PW + 100, PH + 125), R + 20, fill=(0, 0, 0, 160))
SHADOW = sh.filter(ImageFilter.GaussianBlur(40))

def frames(segments):
    """録画の区間を 30fps・画面の大きさで読み、順につなぐ。"""
    out = []
    for a, b in segments:
        cmd = ["ffmpeg", "-v", "error", "-ss", str(a), "-to", str(b), "-i", TAKE,
               "-vf", f"scale={SW}:{SH}", "-f", "rawvideo", "-pix_fmt", "rgb24", "-"]
        raw = subprocess.run(cmd, capture_output=True).stdout
        n = len(raw) // (SW * SH * 3)
        for i in range(n):
            out.append(raw[i * SW * SH * 3:(i + 1) * SW * SH * 3])
    return out

def phone_scene(segments, caption, sub=None, sub_at=None, rise=False):
    fr = frames(segments)
    dur = len(fr) / FPS
    def draw(t, i):
        img = Image.new("RGBA", (W, H), M.GROUND + (255,))
        M.caption(img, caption, t, 0.05, 66)
        if sub:
            a = M.ease(M.prog(t, sub_at, sub_at + 0.4))
            M.put_text(img, sub, M.F(44, "Medium"), M.TXT2, W // 2, 232, a, int(16 * (1 - a)))
        dy = int(420 * (1 - M.ease(M.prog(t, 0.0, 0.9)))) if rise else 0
        img.alpha_composite(SHADOW, (PX - 100, PY - 100 + dy))
        img.alpha_composite(BODY, (PX, PY + dy))
        scr = Image.frombytes("RGB", (SW, SH), fr[min(i, len(fr) - 1)])
        img.paste(scr, (PX + BZ, PY + BZ + dy), SMASK)
        M.fade_ground(img, t, dur, 0.2, 0.25)
        return img
    return draw, len(fr)

def encode(name, draw, n):
    tmp = f"{M.OUT}/{name}.tmp.mp4"
    p = subprocess.Popen(["ffmpeg", "-y", "-loglevel", "error", "-f", "rawvideo", "-pix_fmt", "rgb24", "-s", f"{W}x{H}",
                          "-r", str(FPS), "-i", "-", "-c:v", "libx264", "-preset", "veryfast", "-crf", "18", "-pix_fmt", "yuv420p", tmp],
                         stdin=subprocess.PIPE)
    for i in range(n):
        p.stdin.write(draw(i / FPS, i).convert("RGB").tobytes())
    p.stdin.close()
    if p.wait() == 0:
        os.replace(tmp, f"{M.OUT}/{name}.mp4")

def still_scene(fn, dur):
    return (lambda t, i: fn(t, dur)), int(round(dur * FPS))

SCENES = {
    "e1": lambda: still_scene(M.s1, 3.2),
    "e2": lambda: phone_scene([(0.0, 3.0)], "開けば、もう1問目がある。", rise=True),
    "e3": lambda: phone_scene([(19.2, 22.8), (29.6, 31.4)], "紙に書いて、撮るだけ。"),
    "e4": lambda: phone_scene([(34.6, 37.4), (58.8, 62.4)], "次の1問が、もう待ってる。", "少しずつ、むずかしく。", 2.9),
    "e5": lambda: still_scene(M.s5, 3.0),
    "e6": lambda: still_scene(M.s6, 3.8),
}

if __name__ == "__main__":
    if TAKE_SRC and not os.path.exists(TAKE):
        subprocess.run(["ffmpeg", "-v", "error", "-y", "-i", TAKE_SRC, "-vf", f"fps={FPS},scale={SW}:{SH}:flags=lanczos",
                        "-c:v", "libx264", "-preset", "veryfast", "-crf", "14", "-g", "30", "-pix_fmt", "yuv420p", TAKE], check=True)
    what = os.environ.get("ONLY")
    if os.environ.get("STILL"):
        name, t = os.environ["STILL"].split("@")
        draw, n = SCENES[name]()
        draw(float(t), int(float(t) * FPS)).convert("RGB").save(f"{M.OUT}/est_{name}_{t}.jpg", quality=88)
    else:
        for name, mk in SCENES.items():
            if what and name not in what.split(","):
                continue
            draw, n = mk()
            encode(name, draw, n)
            print(name, n / FPS)
