#!/usr/bin/env python3
"""撮り足し(#132)の事前検証: 作ってある単元の小単元と写真もどきを本物の Claude に渡し、割り当てと費用を出す。

Dev Box で動かす: python3 scripts/devbox/preflight/material_attach.py <model>
API キーは $DEVBOX_ANTHROPIC_KEY_FILE から読み、表示しない。
"""
import base64, json, os, pathlib, sys, time, urllib.request

HERE = pathlib.Path(__file__).resolve().parent
PROMPTS = HERE.parents[2] / "strius/Resources/Prompts"
RATES = {"claude-sonnet-5-5": (2, 10), "claude-haiku-5-5": (0.10, 0.50), "claude-opus-5-5": (4, 20)}

QUAD = [("s1", "二次関数のグラフと平行移動", "y=a(x-p)²+q のグラフをかける", ""),
        ("s2", "二次関数の最大・最小", "頂点と定義域から最大値・最小値を求められる", ""),
        ("s3", "二次方程式と判別式", "二次方程式を解き、実数解の個数を判別式で調べられる", ""),
        ("s4", "グラフとx軸の位置関係", "グラフとx軸の共有点の個数と座標を求められる", ""),
        ("s5", "二次不等式", "グラフを使って二次不等式を解ける", "")]
LINALG = [("u1", "線形写像と表現行列", "線形写像を基底について行列で表せる", "第1〜3回"),
          ("u2", "核と像・次元定理", "核と像の基底を求め、次元定理を使える", "第4回"),
          ("u3", "固有値と固有ベクトル", "固有値と固有ベクトルを求められる", "第5回"),
          ("u4", "対角化", "対角化できるかを判定し、対角化できる", "第6〜7回")]
CASES = [
    ("高校・目次", "二次関数", False, QUAD, ["toc.jpg"]),
    ("高校・1ページ", "二次関数", False, QUAD, ["page_074.jpg"]),
    ("大学・次の回のスライド", "線形代数Ⅱ", True, LINALG, ["slide_09.jpg"]),
    ("大学・シラバス", "線形代数Ⅱ", True, LINALG, ["syllabus.jpg"]),
    ("高校・関係ない写真", "二次関数", False, QUAD, ["slide_09.jpg"]),
]

def run(model, key, system, name, title, course, subunits, images):
    request = {"task": "attach_material", "unit_title": title, "is_course": course,
               "subunits": [{"id": i, "title": t, "outcome": o, "ref": r} for i, t, o, r in subunits]}
    content = [{"type": "image", "source": {"type": "base64", "media_type": "image/jpeg", "data": base64.b64encode((HERE / p).read_bytes()).decode()}} for p in images]
    content.append({"type": "text", "text": "# 今回の材料\n\n" + json.dumps(request, ensure_ascii=False)})
    body = {"model": model, "max_tokens": 2000, "system": system, "messages": [{"role": "user", "content": content}]}
    req = urllib.request.Request("https://api.anthropic.com/v1/messages", data=json.dumps(body).encode(),
                                 headers={"x-api-key": key, "anthropic-version": "2023-06-01", "content-type": "application/json"})
    started = time.time()
    with urllib.request.urlopen(req, timeout=180) as r:
        reply = json.loads(r.read())
    usage = reply.get("usage", {})
    rin, rout = RATES[model]
    usd = usage.get("input_tokens", 0) * rin / 1e6 + usage.get("output_tokens", 0) * rout / 1e6
    text = "".join(block.get("text", "") for block in reply.get("content", []) if block.get("type") == "text")
    print(f"## {name} ({model}, {round(time.time() - started, 1)}秒, {round(usd * 160, 2)}円)")
    print(text.strip())
    print()

def main(model):
    key = pathlib.Path(os.environ["DEVBOX_ANTHROPIC_KEY_FILE"]).read_text().strip()
    schema = json.loads((PROMPTS / "material_attach.json").read_text())
    system = (PROMPTS / "material_attach_instructions.md").read_text() + "\n\nAnswer only with one JSON object matching this JSON Schema:\n" + json.dumps(schema, ensure_ascii=False)
    for case in CASES:
        run(model, key, system, *case)

if __name__ == "__main__":
    main(sys.argv[1])
