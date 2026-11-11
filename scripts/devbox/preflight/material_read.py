#!/usr/bin/env python3
"""範囲の読み取り(#132)の事前検証: 写真もどきを本物の Claude に読ませ、返した値と費用を出す。

Dev Box で動かす: python3 scripts/devbox/preflight/material_read.py <model> <grade> <image>...
API キーは $DEVBOX_ANTHROPIC_KEY_FILE から読み、表示しない。
"""
import base64, json, os, pathlib, sys, time, urllib.request

ROOT = pathlib.Path(__file__).resolve().parents[3]
PROMPTS = ROOT / "strius/Resources/Prompts"
RATES = {"claude-sonnet-5-5": (2, 10), "claude-haiku-5-5": (0.10, 0.50), "claude-opus-5-5": (4, 20)}
UNITS = {
    "高1": ["数と式", "二次関数", "二次不等式", "図形と計量(三角比)", "データの分析", "場合の数と確率", "整数の性質", "図形の性質"],
    "高2": ["式と証明", "複素数と方程式", "図形と方程式", "三角関数", "指数関数・対数関数", "微分法", "積分法", "数列", "統計的な推測"],
    "大学生・それ以外": [],
}

def main(model, grade, images):
    key = pathlib.Path(os.environ["DEVBOX_ANTHROPIC_KEY_FILE"]).read_text().strip()
    schema = json.loads((PROMPTS / "material_read.json").read_text())
    system = (PROMPTS / "material_read_instructions.md").read_text() + "\n\nAnswer only with one JSON object matching this JSON Schema:\n" + json.dumps(schema, ensure_ascii=False)
    request = {"task": "read_material", "grade": grade, "units": UNITS.get(grade, []), "today": "2026-11-11"}
    content = [{"type": "image", "source": {"type": "base64", "media_type": "image/jpeg", "data": base64.b64encode(pathlib.Path(p).read_bytes()).decode()}} for p in images]
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
    print(json.dumps({"model": model, "grade": grade, "images": [pathlib.Path(p).name for p in images], "seconds": round(time.time() - started, 1),
                      "input_tokens": usage.get("input_tokens"), "output_tokens": usage.get("output_tokens"), "usd": round(usd, 4),
                      "yen": round(usd * 160, 2)}, ensure_ascii=False))
    print(text)

if __name__ == "__main__":
    main(sys.argv[1], sys.argv[2], sys.argv[3:])
