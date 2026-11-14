"""Struis の紹介動画(縦 1080x1920、約35秒)を作る(Claude の環境で動かす)。

    MARKETING_OUT=/tmp/out python3 scripts/marketing/edit/intro.py <timeline.mp4> <unit.mp4>

timeline.mp4 は takes/demo1.json の録画、unit.mp4 は takes/unit-select.json の録画(どちらも 2026-11-14、main 36693fb)。
流れ: 「やらなきゃ。わかってる。でも、身体が動かない。」→ 単元を選ぶと計画ができる → 開けば1問目 → ノートに書いて撮るだけ
→ 次の1問 →「考えるのは、目の前の1問だけ。」→ ロゴ。
録画の中の出来事の秒(SHUTTER・RESULT・NEXT)と区間は、上の録画を 30fps に直したものを見て決めた値。録り直したら見直す。
"""
import os, subprocess, sys

from PIL import Image

tl_src = sys.argv[1]
unit_src = sys.argv[2]
sys.argv = [sys.argv[0], "intro", tl_src]
import variants as V  # noqa: E402  (phone_scene・text_scene・end_scene と音)

E, M = V.E, V.M
W, H, FPS = M.W, M.H, M.FPS
OUT = str(M.OUT / "intro")
os.makedirs(OUT, exist_ok=True)

# timeline.mp4(30fps に直した後)の出来事の秒
V.SHUTTER = [9.0, 38.1]
V.RESULT = [16.7, 48.3]
V.NEXT = [27.4, 53.8]


def unit_frames(src, a, b, speed):
    """区間を読み、speed 倍速に間引く(小数の倍速も可)。"""
    cmd = ["ffmpeg", "-v", "error", "-ss", str(a), "-to", str(b), "-i", src, "-vf", f"scale={E.SW}:{E.SH}",
           "-f", "rawvideo", "-pix_fmt", "rgb24", "-"]
    raw = subprocess.run(cmd, capture_output=True).stdout
    size = E.SW * E.SH * 3
    fr = [raw[i * size:(i + 1) * size] for i in range(len(raw) // size)]
    if speed == 1:
        return fr
    n = int(len(fr) / speed)
    return [fr[min(len(fr) - 1, int(k * speed))] for k in range(n)]


def unit_scene(events, offset):
    """単元づくり: 選ぶ(早送り)→ 計画のカード → 単元の画面。見出しは区間ごとに替える。"""
    src = V.cfr(unit_src)
    # (始め, 終わり, 倍速, 見出し, 最後の絵を止める秒)
    segs = [(0.8, 4.2, 2.0, "やる範囲を選ぶと、", 0), (5.6, 13.0, 2.5, "やる範囲を選ぶと、", 0),
            (33.8, 36.6, 1.0, "計画ができる。", 0), (43.0, 43.5, 1.0, "計画ができる。", 1.0)]
    frames, caps = [], []
    for a, b, speed, cap, hold in segs:
        fr = unit_frames(src, a, b, speed)
        fr += [fr[-1]] * int(hold * FPS)
        if frames:
            events.append(("cut", offset + len(frames) / FPS))
        if cap == "計画ができる。" and a == 33.8:
            events.append(("chime", offset + len(frames) / FPS + 0.25))
        caps += [cap] * len(fr)
        frames += fr
    starts = {}
    for i, c in enumerate(caps):
        starts.setdefault(c, i)
    dur = len(frames) / FPS

    def draw(t, i):
        img = Image.new("RGBA", (W, H), M.GROUND + (255,))
        dy = int(420 * (1 - M.ease(M.prog(t, 0.0, 0.9))))
        img.alpha_composite(E.SHADOW, (E.PX - 100, E.PY - 100 + dy))
        img.alpha_composite(E.BODY, (E.PX, E.PY + dy))
        scr = Image.frombytes("RGB", (E.SW, E.SH), frames[min(i, len(frames) - 1)])
        img.paste(scr, (E.PX + E.BZ, E.PY + E.BZ + dy), E.SMASK)
        cap = caps[min(i, len(caps) - 1)]
        lt = (i - starts[cap]) / FPS
        a = M.ease(M.prog(lt, 0.0, 0.35))
        color = M.ACCENT if cap == "計画ができる。" else M.TXT
        M.put_text(img, cap, M.F(66, "Bold"), color, W // 2, 130, a, int(18 * (1 - a)))
        M.fade_ground(img, t, dur, 0.15, 0.2)
        return img
    return draw, len(frames)


def hook_scene(events, offset):
    dur = 3.2
    events += [("pluck", offset + 0.3), ("pluck", offset + 1.0), ("pluck", offset + 1.9)]
    return (lambda t, i: M.s1(t, dur)), int(round(dur * FPS))


T, T2, A = M.TXT, M.TXT2, M.ACCENT


def plan(ev):
    return [
        lambda o: hook_scene(ev, o),
        lambda o: unit_scene(ev, o),
        lambda o: V.phone_scene([(0.0, 2.8, 1, None)], "開けば、もう1問目がある。", ev, o, rise=True),
        lambda o: V.phone_scene([(4.2, 6.2, 1, None), (8.4, 9.8, 1, None), (15.9, 19.0, 1, None)],
                                "ノートに書いて、撮るだけ。", ev, o),
        lambda o: V.phone_scene([(26.9, 29.4, 1, None), (53.3, 56.0, 1, None)],
                                "次の1問が、もう待ってる。", ev, o, sub="少しずつ、むずかしく。", sub_at=2.4),
        lambda o: V.text_scene([("考えるのは、", 64, "Bold", T2, 800, 0.1), ("目の前の1問だけ。", 88, "Bold", T, 910, 0.5)], 2.6, ev, o),
        lambda o: V.end_scene("やる気は、あとからついてくる。", 3.8, ev, o),
    ]


def build():
    ev = []
    files, offset = [], 0.0
    only = os.environ.get("ONLY")
    for k, b in enumerate(plan(ev)):
        draw, n = b(offset)
        if not only or str(k) in only.split(","):
            E.encode(f"intro/s{k}", draw, n)
        files.append(f"{OUT}/s{k}.mp4")
        offset += n / FPS
    if os.environ.get("STILL"):
        return
    with open(f"{OUT}/list.txt", "w") as f:
        f.writelines(f"file '{p}'\n" for p in files)
    subprocess.run(["ffmpeg", "-y", "-loglevel", "error", "-f", "concat", "-safe", "0", "-i", f"{OUT}/list.txt", "-c", "copy",
                    f"{OUT}/silent.mp4"], check=True)
    V.soundtrack(ev, offset, f"{OUT}/audio.wav")
    subprocess.run(["ffmpeg", "-y", "-loglevel", "error", "-i", f"{OUT}/silent.mp4", "-i", f"{OUT}/audio.wav", "-map", "0:v", "-map", "1:a",
                    "-c:v", "copy", "-c:a", "aac", "-b:a", "192k", "-shortest", f"{OUT}/struis_intro.mp4"], check=True)
    print(f"{OUT}/struis_intro.mp4", round(offset, 2))


if __name__ == "__main__":
    E.ensure_take()
    if os.environ.get("STILL"):
        # STILL=場面の番号@秒 で1枚だけ描く(書き出しの前の確認用)
        k, t = os.environ["STILL"].split("@")
        ev = []
        draw, n = plan(ev)[int(k)](0.0)
        draw(float(t), int(float(t) * FPS)).convert("RGB").save(f"{OUT}/still_{k}_{t}.jpg", quality=88)
    else:
        build()
