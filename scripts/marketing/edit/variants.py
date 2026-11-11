"""同じ録画から、切り口の違う宣伝の映像を作る(Claude の環境で動かす)。

    MARKETING_OUT=/tmp/out python3 scripts/marketing/edit/variants.py A take.mp4 textbook.mp4 consult.mp4    # A〜D のどれか

take.mp4 はタイムラインの録画(takes/demo1.json)、textbook.mp4・consult.mp4 は単元づくりの録画(takes/unit-textbook.json・
takes/unit-consult.json)。どの案も最初か途中に「教科書を撮っても、話すだけでも、単元ができる。」の場面を入れる。

A: 最初は拍子抜けするほど簡単 / B: 撮る・○・次のテンポ / C: タイムラインを流すように / D: プロンプトはいらない。
録画の中の出来事の秒(SHUTTER・RESULT・NEXT)と区間は、takes/demo1.json の録画(2026-11-11)を見て決めた値。録り直したら見直す。
"""
import os, sys, subprocess, wave
import numpy as np
from PIL import Image, ImageDraw

which = sys.argv[1]
take_src = sys.argv[2] if len(sys.argv) > 2 else ""
textbook_src = sys.argv[3] if len(sys.argv) > 3 else ""   # takes/unit-textbook.json の録画
consult_src = sys.argv[4] if len(sys.argv) > 4 else ""    # takes/unit-consult.json の録画
sys.argv = [sys.argv[0], take_src]
import edit as E
M = E.M
W, H, FPS = M.W, M.H, M.FPS
OUT = str(M.OUT / "variants")
os.makedirs(OUT, exist_ok=True)

# 録画の中の出来事(秒)
SHUTTER = [3.77, 21.63, 44.5, 68.07, 90.73]
RESULT = [4.67, 30.1, 50.9, 74.53, 93.0]
NEXT = [13.43, 36.07, 59.7, 82.47, 98.6]

# ---------- 共通の部品 ----------
def text_scene(lines, dur, events, offset):
    """lines: [(文, 大きさ, 太さ, 色, y, 出す秒)]"""
    for *_, start in lines:
        events.append(("pluck", offset + start + 0.05))
    def draw(t, i):
        img = Image.new("RGBA", (W, H), M.GROUND + (255,))
        for text, size, weight, color, y, start in lines:
            a = M.ease(M.prog(t, start, start + 0.45))
            M.put_text(img, text, M.F(size, weight), color, W // 2, y, a, int(26 * (1 - a)))
        M.fade_ground(img, t, dur, 0.2, 0.3)
        return img
    return draw, int(round(dur * FPS))

def end_scene(tagline, dur, events, offset):
    events += [("pluck", offset + 0.2), ("pluck", offset + 0.7), ("pluck", offset + 1.35)]
    def draw(t, i):
        img = Image.new("RGBA", (W, H), M.GROUND + (255,))
        a = M.ease(M.prog(t, 0.1, 0.8))
        size = int(300 + 30 * (1 - a))
        lg = M.LOGO.resize((size, size), Image.LANCZOS)
        if a < 1:
            lg.putalpha(lg.getchannel("A").point(lambda v: int(v * a)))
        img.alpha_composite(lg, (W // 2 - size // 2, 560 - (size - 300) // 2))
        b = M.ease(M.prog(t, 0.6, 1.1))
        M.put_text(img, "Struis", M.F(120), M.TXT, W // 2, 920, b, int(20 * (1 - b)))
        c = M.ease(M.prog(t, 1.3, 1.8))
        M.put_text(img, tagline, M.F(52, "Medium"), M.TXT2, W // 2, 1110, c, int(20 * (1 - c)))
        e = M.ease(M.prog(t, 2.0, 2.4))
        M.put_text(img, "iPhone ・ iPad", M.F(38, "Medium"), M.TXT3, W // 2, 1560, e)
        M.fade_ground(img, t, dur, 0.2, 0.5)
        return img
    return draw, int(round(dur * FPS))

def read_frames(a, b, speed):
    raw = E.frames([(a, b)])
    return raw[::speed] if speed > 1 else raw

def phone_scene(segs, caption, events, offset, sub=None, sub_at=None, rise=False, zoom=None, stamp_y=150):
    """segs: [(始め, 終わり, 何倍速, 押印の文字 or None)]。zoom: (始める秒, 終える秒, 倍率, 画面の中の注目の y 0〜1)"""
    frames, marks, local = [], [], 0.0
    for a, b, speed, stamp in segs:
        fr = read_frames(a, b, speed)
        marks.append((len(frames), stamp))
        for kind, times in (("shutter", SHUTTER), ("chime", RESULT), ("whoosh", NEXT)):
            for x in times:
                if a <= x < b:
                    events.append((kind, offset + local + (x - a) / speed))
        if local > 0:
            events.append(("cut", offset + local))
        frames += fr
        local += len(fr) / FPS
    dur = len(frames) / FPS
    phone_layer = Image.new("RGBA", (W, H), (0, 0, 0, 0))

    def draw(t, i):
        img = Image.new("RGBA", (W, H), M.GROUND + (255,))
        layer = phone_layer.copy()
        dy = int(420 * (1 - M.ease(M.prog(t, 0.0, 0.9)))) if rise else 0
        layer.alpha_composite(E.SHADOW, (E.PX - 100, E.PY - 100 + dy))
        layer.alpha_composite(E.BODY, (E.PX, E.PY + dy))
        scr = Image.frombytes("RGB", (E.SW, E.SH), frames[min(i, len(frames) - 1)])
        layer.paste(scr, (E.PX + E.BZ, E.PY + E.BZ + dy), E.SMASK)
        if zoom:
            z0, z1, k, fy = zoom
            p = M.ease_io(M.prog(t, z0, z1))
            scale = 1 + (k - 1) * p
            if scale > 1.001:
                cy = E.PY + E.BZ + fy * E.SH
                target_y = H * 0.56
                big = layer.resize((int(W * scale), int(H * scale)), Image.BICUBIC)
                ox = int(W * scale / 2 - W / 2)
                oy = int(cy * scale - (cy + (target_y - cy) * p))
                layer = big.crop((ox, oy, ox + W, oy + H))
                # 文字の下に帯を敷く(拡大した画面と重なっても読めるように)
                band = Image.new("RGBA", (W, 400), M.GROUND + (0,))
                alpha = Image.new("L", (1, 400))
                alpha.putdata([int(255 * p * (1 if y < 300 else (400 - y) / 100)) for y in range(400)])
                band.putalpha(alpha.resize((W, 400)))
                layer.alpha_composite(band, (0, 0))
        img.alpha_composite(layer)
        if caption:
            M.caption(img, caption, t, 0.05, 66)
        if sub:
            a = M.ease(M.prog(t, sub_at, sub_at + 0.4))
            M.put_text(img, sub, M.F(44, "Medium"), M.TXT2, W // 2, 232, a, int(16 * (1 - a)))
        # 押印(区間ごとの大きな1語)
        idx = max(k for k, (start, _) in enumerate(marks) if start <= i)
        start, stamp = marks[idx]
        if stamp:
            lt = (i - start) / FPS
            pop = M.ease(M.prog(lt, 0.0, 0.18))
            size = int(128 + 40 * (1 - pop))
            M.put_text(img, stamp, M.F(size, "Bold"), M.ACCENT if stamp != "○" else M.GROWTH, W // 2, stamp_y - (size - 128) // 2, min(1, pop * 1.5))
        M.fade_ground(img, t, dur, 0.15, 0.2)
        return img
    return draw, len(frames)

def cfr(path):
    """可変フレームレートの録画を 30fps に直す(元の録画ごとに名前を分け、同じ録画は使い回す)。"""
    st = os.stat(path)
    key = __import__("hashlib").sha1(f"{os.path.abspath(path)}:{st.st_size}:{st.st_mtime_ns}".encode()).hexdigest()[:12]
    out = str(M.OUT / f"take30-{key}.mp4")
    if not os.path.exists(out):
        tmp = out[:-4] + ".tmp.mp4"
        subprocess.run(["ffmpeg", "-v", "error", "-y", "-i", path, "-vf", f"fps={FPS},scale={E.SW}:{E.SH}:flags=lanczos",
                        "-c:v", "libx264", "-preset", "veryfast", "-crf", "14", "-g", "30", "-pix_fmt", "yuv420p", tmp], check=True)
        os.replace(tmp, out)
    return out


def read_src(src, a, b, speed):
    if src is None:
        return read_frames(a, b, speed)
    cmd = ["ffmpeg", "-v", "error", "-ss", str(a), "-to", str(b), "-i", src, "-vf", f"scale={E.SW}:{E.SH}", "-f", "rawvideo", "-pix_fmt", "rgb24", "-"]
    raw = subprocess.run(cmd, capture_output=True).stdout
    n = len(raw) // (E.SW * E.SH * 3)
    fr = [raw[i * E.SW * E.SH * 3:(i + 1) * E.SW * E.SH * 3] for i in range(n)]
    return fr[::speed] if speed > 1 else fr

def unit_scene(events, offset):
    """単元づくり: 教科書を撮っても、話すだけでも、単元ができる。区間ごとに見出しを替える。"""
    tb, cs = cfr(textbook_src), cfr(consult_src)
    segs = [(tb, 1.0, 1.8, "教科書を撮っても、"), (tb, 12.0, 13.2, "教科書を撮っても、"), (tb, 32.2, 32.9, "教科書を撮っても、"),
            (cs, 35.0, 37.4, "話すだけでも、"), (tb, 81.0, 83.6, "単元ができる。")]
    frames, caps = [], []
    for src, a, b, cap in segs:
        fr = read_src(src, a, b, 1)
        if frames:
            events.append(("cut", offset + len(frames) / FPS))
        if src == tb and a == 12.0:
            events.append(("shutter", offset + (len(frames) + len(fr) - 4) / FPS))
        if cap == "単元ができる。":
            events.append(("chime", offset + len(frames) / FPS + 0.2))
        caps += [cap] * len(fr)
        frames += fr
    starts = {}
    for i, c in enumerate(caps):
        starts.setdefault(c, i)
    dur = len(frames) / FPS

    def draw(t, i):
        img = Image.new("RGBA", (W, H), M.GROUND + (255,))
        img.alpha_composite(E.SHADOW, (E.PX - 100, E.PY - 100))
        img.alpha_composite(E.BODY, (E.PX, E.PY))
        scr = Image.frombytes("RGB", (E.SW, E.SH), frames[min(i, len(frames) - 1)])
        img.paste(scr, (E.PX + E.BZ, E.PY + E.BZ), E.SMASK)
        cap = caps[min(i, len(caps) - 1)]
        lt = (i - starts[cap]) / FPS
        a = M.ease(M.prog(lt, 0.0, 0.3))
        M.put_text(img, cap, M.F(66, "Bold"), M.ACCENT if cap == "単元ができる。" else M.TXT, W // 2, 130, a, int(18 * (1 - a)))
        M.fade_ground(img, t, dur, 0.15, 0.2)
        return img
    return draw, len(frames)

# ---------- 音 ----------
def soundtrack(events, D, path):
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

# ---------- 4案 ----------
T, T2, A, G = M.TXT, M.TXT2, M.ACCENT, M.GROWTH

def plan(name, ev):
    s = []  # (builder) を順に。offset は組み立て時に決める
    if name == "A":   # 最初は拍子抜けするほど簡単
        s.append(lambda o: unit_scene(ev, o))
        s.append(lambda o: text_scene([("そして、", 64, "Bold", T2, 780, 0.1), ("最初の問題が、これ。", 72, "Bold", T, 880, 0.5)], 2.2, ev, o))
        s.append(lambda o: phone_scene([(0.1, 3.3, 1, None)], "公式まで書いてある。", ev, o, rise=True))
        s.append(lambda o: phone_scene([(4.4, 7.4, 1, None)], "簡単すぎる？", ev, o, sub="それでいい。", sub_at=1.3))
        s.append(lambda o: phone_scene([(13.3, 14.6, 1, None), (35.9, 37.4, 1, None), (59.6, 61.6, 1, None), (82.4, 83.8, 1, None)],
                                       "1問ずつ、ちょっとだけ先へ。", ev, o))
        s.append(lambda o: text_scene([("気づいたら、", 64, "Bold", T2, 760, 0.1), ("平方完成まで", 96, "Bold", A, 870, 0.6), ("来ていた。", 96, "Bold", A, 1000, 0.9)], 3.0, ev, o))
        s.append(lambda o: end_scene("最初の1問は、簡単でいい。", 3.8, ev, o))
    elif name == "B":  # テンポ
        s.append(lambda o: unit_scene(ev, o))
        s.append(lambda o: phone_scene([(18.4, 21.7, 2, "撮る"), (30.0, 31.5, 1, "○"), (35.6, 36.8, 1, "次"),
                                        (42.0, 44.6, 2, "撮る"), (50.8, 52.1, 1, "○"), (59.2, 60.5, 1, "次"),
                                        (65.6, 68.2, 2, "撮る"), (74.4, 75.6, 1, "○"), (82.0, 83.3, 1, "次")], None, ev, o, rise=False, stamp_y=140))
        s.append(lambda o: text_scene([("考えるのは、", 64, "Bold", T2, 800, 0.1), ("目の前の1問だけ。", 88, "Bold", T, 910, 0.5)], 2.6, ev, o))
        s.append(lambda o: end_scene("撮って、○、次。", 3.6, ev, o))
    elif name == "C":  # タイムライン
        s.append(lambda o: unit_scene(ev, o))
        s.append(lambda o: text_scene([("タイムラインを", 80, "Bold", T, 760, 0.2), ("流すみたいに。", 80, "Bold", T, 880, 0.7)], 2.6, ev, o))
        s.append(lambda o: phone_scene([(35.2, 37.2, 1, None), (59.0, 61.2, 1, None), (81.7, 83.8, 1, None), (97.9, 100.2, 1, None)],
                                       "次の1問が、流れてくる。", ev, o, sub="解いたら、そのまま次へ。", sub_at=2.0, rise=True))
        s.append(lambda o: phone_scene([(83.0, 86.6, 1, None)], "開いたら、もう始まってる。", ev, o))
        s.append(lambda o: end_scene("勉強の、タイムライン。", 3.8, ev, o))
    elif name == "D":  # プロンプトはいらない
        s.append(lambda o: text_scene([("AIに聞くたび、", 72, "Bold", T, 760, 0.2), ("何て聞けばいいか", 72, "Bold", T, 880, 0.8), ("考えてた。", 72, "Bold", T, 1000, 1.2)], 3.4, ev, o))
        s.append(lambda o: text_scene([("もう、書かなくていい。", 84, "Bold", A, 860, 0.15)], 2.0, ev, o))
        s.append(lambda o: unit_scene(ev, o))
        s.append(lambda o: phone_scene([(41.4, 44.9, 1, None), (50.6, 51.6, 1, None)], "答案を撮るだけ。", ev, o, rise=True))
        s.append(lambda o: phone_scene([(51.6, 56.2, 1, None)], "式の変形まで見て、", ev, o, sub="ひとこと返してくれる。", sub_at=1.6, zoom=(0.3, 1.4, 1.55, 0.50)))
        s.append(lambda o: end_scene("プロンプトは、いらない。", 3.8, ev, o))
    return s

def build(name):
    ev = []
    builders = plan(name, ev)
    files, offset = [], 0.0
    for k, b in enumerate(builders):
        draw, n = b(offset)
        part = f"{OUT}/{name}{k}"
        E.encode(f"variants/{name}{k}", draw, n)
        files.append(part + ".mp4")
        offset += n / FPS
    with open(f"{OUT}/{name}.txt", "w") as f:
        f.writelines(f"file '{p}'\n" for p in files)
    subprocess.run(["ffmpeg", "-y", "-loglevel", "error", "-f", "concat", "-safe", "0", "-i", f"{OUT}/{name}.txt", "-c", "copy", f"{OUT}/{name}_silent.mp4"], check=True)
    soundtrack(ev, offset, f"{OUT}/{name}.wav")
    subprocess.run(["ffmpeg", "-y", "-loglevel", "error", "-i", f"{OUT}/{name}_silent.mp4", "-i", f"{OUT}/{name}.wav", "-map", "0:v", "-map", "1:a",
                    "-c:v", "copy", "-c:a", "aac", "-b:a", "192k", "-shortest", f"{OUT}/struis_promo_{name}.mp4"], check=True)
    print(name, round(offset, 2))

if __name__ == "__main__":
    E.ensure_take()
    build(which)
