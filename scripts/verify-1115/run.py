"""2026-11-15 のタイムライン検証(一時スクリプト。マージしない)。

Dev Box で実行する。入力(答案の写真・問題)は暗号化して渡され、作業フォルダの外で復号したものを読む。
標準出力には件数と費用の集計だけを出し、答案の中身は出さない(公開リポジトリの結果ブランチに載るため)。

使い方: python3 run.py <復号したフォルダ> <出力 JSON> <上限ドル>
"""
import concurrent.futures as cf
import base64
import json
import os
import subprocess
import sys
import threading
import time
import urllib.error
import urllib.request

PRICES = {  # 100 万トークンあたりのドル(strius/Runtime/Claude/ClaudeUsageLog.swift と同じ)
    "claude-opus-5-5": dict(input=4, w5=5, w1=8, read=0.20, out=20),
    "claude-sonnet-5-5": dict(input=2, w5=2.5, w1=4, read=0.10, out=10),
    "claude-haiku-5-5": dict(input=0.10, w5=0.125, w1=0.20, read=0.01, out=0.50),
}

lock = threading.Lock()
spent = 0.0
calls = 0


def cost(model: str, usage: dict) -> float:
    p = PRICES[model]
    cc = usage.get("cache_creation") or {}
    w1 = cc.get("ephemeral_1h_input_tokens", 0)
    w5 = cc.get("ephemeral_5m_input_tokens", usage.get("cache_creation_input_tokens", 0) - w1)
    return (usage.get("input_tokens", 0) * p["input"] + w5 * p["w5"] + w1 * p["w1"]
            + usage.get("cache_read_input_tokens", 0) * p["read"] + usage.get("output_tokens", 0) * p["out"]) / 1e6


def call(key: str, body: dict, limit: float) -> dict:
    global spent, calls
    with lock:
        if spent >= limit:
            return {"skipped": "budget"}
    data = json.dumps(body).encode()
    req = urllib.request.Request("https://api.anthropic.com/v1/messages", data=data, method="POST", headers={
        "content-type": "application/json", "anthropic-version": "2023-06-01", "x-api-key": key})
    started = time.time()
    for attempt in range(3):
        try:
            with urllib.request.urlopen(req, timeout=300) as r:
                res = json.load(r)
            break
        except urllib.error.HTTPError as e:
            msg = e.read().decode(errors="replace")[:300]
            if e.code in (429, 500, 529) and attempt < 2:
                time.sleep(10 * (attempt + 1))
                continue
            return {"error": f"HTTP {e.code}: {msg}"}
        except Exception as e:  # noqa: BLE001
            if attempt < 2:
                time.sleep(5)
                continue
            return {"error": str(e)[:300]}
    c = cost(body["model"], res.get("usage", {}))
    with lock:
        spent += c
        calls += 1
    text = "".join(b.get("text", "") for b in res.get("content", []) if b.get("type") == "text")
    return {"text": text, "usage": res.get("usage", {}), "cost": c, "seconds": round(time.time() - started, 1),
            "stop_reason": res.get("stop_reason")}


def parse_json(text: str):
    s, e = text.find("{"), text.rfind("}")
    if s < 0 or e < 0:
        return None
    try:
        return json.loads(text[s:e + 1])
    except json.JSONDecodeError:
        return None


def main() -> None:
    src, out_path, limit = sys.argv[1], sys.argv[2], float(sys.argv[3])
    key = open(os.environ["DEVBOX_ANTHROPIC_KEY_FILE"]).read().strip()
    items = json.load(open(os.path.join(src, "items.json")))
    prompts = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "strius", "Resources", "Prompts")
    base = open(os.path.join(prompts, "base_instructions.md")).read()
    shared = open(os.path.join(prompts, "timeline_shared.md")).read()
    task = open(os.path.join(prompts, "timeline_grading_instructions.md")).read()
    schema = json.load(open(os.path.join(prompts, "timeline_grading.json")))
    schema_text = ("Answer with exactly one JSON object and nothing else. It must validate against this JSON Schema:\n"
                   + json.dumps(schema, sort_keys=True, ensure_ascii=False))
    system = [{"type": "text", "text": base + "\n\n" + shared + "\n\n" + task + "\n\n" + schema_text,
               "cache_control": {"type": "ephemeral"}}]

    # 写真をアプリと同じ長い辺 1,092 ピクセルに縮める(macOS の sips)。
    small = os.path.join(src, "small")
    os.makedirs(small, exist_ok=True)
    for it in items:
        dst = os.path.join(small, it["n"] + ".jpg")
        if not os.path.exists(dst):
            subprocess.run(["sips", "-Z", "1092", os.path.join(src, "img", it["n"] + ".jpg"), "--out", dst],
                           check=True, capture_output=True)

    def grading_body(model: str, it: dict) -> dict:
        materials = {"answer_key": it["answer_key"], "kind": it["card_kind"], "math": it["math"], "problem": it["prompt"],
                     "question": it["question"], "steps_for_reference": it["steps"]}
        img = base64.b64encode(open(os.path.join(small, it["n"] + ".jpg"), "rb").read()).decode()
        return {"model": model, "max_tokens": 8000, "system": system,
                "thinking": {"type": "adaptive"}, "output_config": {"effort": "medium"},
                "messages": [{"role": "user", "content": [
                    {"type": "image", "source": {"type": "base64", "media_type": "image/jpeg", "data": img}},
                    {"type": "text", "text": "# 今回の仕事: 採点\n\n上の出力の形で採点してください。\n\n# 今回の材料\n\n"
                     + json.dumps(materials, ensure_ascii=False)}]}]}

    results = {"grading": {}, "opus": [], "errors": []}
    jobs = [(m, it) for it in items for m in ("claude-sonnet-5-5", "claude-haiku-5-5")]
    # 同じモデルの system を先に 1 回書いてキャッシュを温める(以降は読むだけ)。
    for m in ("claude-sonnet-5-5", "claude-haiku-5-5"):
        first = [j for j in jobs if j[0] == m][0]
        jobs.remove(first)
        r = call(key, grading_body(*first), limit)
        results["grading"][f"{first[1]['n']}|{m}"] = {**r, "parsed": parse_json(r.get("text", ""))}
    with cf.ThreadPoolExecutor(max_workers=4) as ex:
        futs = {ex.submit(call, key, grading_body(m, it), limit): (m, it["n"]) for m, it in jobs}
        for f in cf.as_completed(futs):
            m, n = futs[f]
            r = f.result()
            results["grading"][f"{n}|{m}"] = {**r, "parsed": parse_json(r.get("text", ""))}
            if "error" in r:
                results["errors"].append(f"{n}|{m}: {r['error'][:120]}")
    print(f"grading done: calls={calls} spent=${spent:.3f}", flush=True)

    # Opus の計画(2 回)。
    log = open(os.path.join(src, "opus_log.md")).read()
    plan_task = open(os.path.join(src, "opus_task.md")).read()
    for i in range(2):
        r = call(key, {"model": "claude-opus-5-5", "max_tokens": 16000, "thinking": {"type": "adaptive"},
                       "output_config": {"effort": "medium"},
                       "system": [{"type": "text", "text": base + "\n\n" + shared, "cache_control": {"type": "ephemeral"}}],
                       "messages": [{"role": "user", "content": [{"type": "text", "text": log + "\n\n" + plan_task}]}]}, limit)
        results["opus"].append(r)
        print(f"opus {i + 1}: spent=${spent:.3f}", flush=True)

    results["spent"] = spent
    results["calls"] = calls
    json.dump(results, open(out_path, "w"), ensure_ascii=False)
    print(f"total calls={calls} spent=${spent:.3f} errors={len(results['errors'])}", flush=True)
    for e in results["errors"][:5]:
        print("error:", e.split(":")[0], flush=True)


if __name__ == "__main__":
    main()
