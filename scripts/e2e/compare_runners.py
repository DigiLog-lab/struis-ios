#!/usr/bin/env python3
"""Codex 版と Claude 直結版の比較をまとめる(`RunnerComparisonLiveTests` の結果を読む)。

    python3 scripts/e2e/compare_runners.py --server <dir>/server --outcomes <dir>/outcomes --out <dir>/report

- 届いた要求: 同じ場面・同じ順番の要求を、ID や時刻など毎回変わるものを揃えて比べる。Codex だけが足す権限の注記と環境情報は
  `allowed` として分けて数え、それ以外の違いはすべて `differences` に出す。
- 結果・時間・故障時・メモリを版ごとに並べる。時間は同じ計算機の時計で測った模擬サーバーの到着時刻を使う。

標準ライブラリだけで動く。結果は `summary.json` と `report.md`。
"""
from __future__ import annotations

import argparse
import json
import re
import statistics
from pathlib import Path

CODEX_ONLY = ("<permissions instructions>", "<environment_context>", "<apps_instructions>", "<skills_instructions>")
TOP_LEVEL = ("model", "max_tokens", "stream", "thinking", "output_config", "tool_choice", "cache_control", "tools")
UUID = re.compile(r"[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}", re.I)
PLAN_ID = re.compile(r"compare-[a-z0-9-]+?-[0-9a-f]{8}\b")
PATHS = re.compile(r"/[^\s\"']*/(?:workspace|Containers)/[^\s\"']*")
STAMP = re.compile(r"\d{4}-\d{2}-\d{2}[T ]\d{2}:\d{2}:\d{2}(?:\.\d+)?Z?")
TOOL_ID = re.compile(r"toolu_[A-Za-z0-9]+")


def normalize_text(text: str) -> str:
    for pattern, value in ((UUID, "<uuid>"), (PLAN_ID, "<plan>"), (PATHS, "<path>"), (STAMP, "<time>"), (TOOL_ID, "<tool-id>")):
        text = pattern.sub(value, text)
    return text


def normalize(value):
    if isinstance(value, str):
        return normalize_text(value)
    if isinstance(value, list):
        return [normalize(item) for item in value]
    if isinstance(value, dict):
        return {key: normalize(item) for key, item in value.items()}
    return value


def is_codex_only(block: dict) -> bool:
    return block.get("type") == "text" and str(block.get("text", "")).lstrip().startswith(CODEX_ONLY)


def split_codex_only(blocks: list) -> tuple[list, list]:
    kept, removed = [], []
    for block in blocks:
        (removed if isinstance(block, dict) and is_codex_only(block) else kept).append(block)
    return kept, removed


def canonical(body: dict) -> tuple[dict, list[str]]:
    """比べる形にする。戻り値の 2 つ目は、取り除いた Codex だけの文の頭。"""
    removed: list[dict] = []
    system, gone = split_codex_only(body.get("system") or [])
    removed += gone
    messages = []
    for message in body.get("messages") or []:
        content = message.get("content")
        if isinstance(content, list):
            content, gone = split_codex_only(content)
            removed += gone
            if not content:
                continue
            message = {**message, "content": content}
        messages.append(message)
    result = {key: body.get(key) for key in TOP_LEVEL}
    result["diagnostics_present"] = "diagnostics" in body
    result["system"] = system
    result["messages"] = messages
    return normalize(result), [str(block.get("text", ""))[:80] for block in removed]


def diff(path: str, a, b, out: list[dict], limit: int = 40) -> None:
    if len(out) >= limit or a == b:
        return
    if isinstance(a, dict) and isinstance(b, dict):
        for key in sorted(set(a) | set(b)):
            diff(f"{path}.{key}", a.get(key), b.get(key), out, limit)
    elif isinstance(a, list) and isinstance(b, list):
        if len(a) != len(b):
            out.append({"path": path + ".length", "codex": len(a), "direct": len(b)})
        for index in range(min(len(a), len(b))):
            diff(f"{path}[{index}]", a[index], b[index], out, limit)
    else:
        out.append({"path": path, "codex": short(a), "direct": short(b)})


def short(value):
    text = json.dumps(value, ensure_ascii=False, sort_keys=True) if not isinstance(value, str) else value
    return text if len(text) <= 300 else text[:300] + "…"


def load_requests(root: Path, runner: str, set_name: str, step: str) -> list[dict]:
    directory = root / "scenarios" / runner / set_name / step
    return [json.loads(path.read_text()) for path in sorted(directory.glob("*.json"))] if directory.exists() else []


def compare_requests(server: Path) -> dict:
    root = server / "scenarios" / "codex"
    pairs = []
    if not root.exists():
        return {"pairs": [], "identical": 0, "different": 0, "codex_only_text": []}
    only: dict[str, int] = {}
    for set_dir in sorted(p for p in root.iterdir() if p.is_dir()):
        for step_dir in sorted(p for p in set_dir.iterdir() if p.is_dir()):
            codex = load_requests(server, "codex", set_dir.name, step_dir.name)
            direct = load_requests(server, "direct", set_dir.name, step_dir.name)
            if not direct:
                continue
            for index in range(max(len(codex), len(direct))):
                entry = {"set": set_dir.name, "step": step_dir.name, "index": index + 1}
                if index >= len(codex) or index >= len(direct):
                    entry["differences"] = [{"path": "request", "codex": index < len(codex), "direct": index < len(direct)}]
                    pairs.append(entry)
                    continue
                a, removed = canonical(codex[index]["request"])
                b, _ = canonical(direct[index]["request"])
                for text in removed:
                    only[text] = only.get(text, 0) + 1
                found: list[dict] = []
                diff("body", a, b, found)
                entry["differences"] = found
                entry["codex_bytes"], entry["direct_bytes"] = codex[index].get("bytes"), direct[index].get("bytes")
                pairs.append(entry)
    return {
        "pairs": pairs, "identical": sum(not pair["differences"] for pair in pairs), "different": sum(bool(pair["differences"]) for pair in pairs),
        "codex_only_text": sorted(only.items(), key=lambda item: -item[1]),
    }


def timing(server: Path, runner: str, results: list[dict]) -> list[dict]:
    """1 ターンの時間の内訳。到着と返し終わりは模擬サーバーの時計(アプリと同じ計算機)。"""
    rows = []
    for result in results:
        requests = load_requests(server, runner, result["set"], result["step"])
        if not requests:
            continue
        first = requests[0]["arrived_at"] - result["started_at"]
        gaps = [later["arrived_at"] - earlier["finished_at"] for earlier, later in zip(requests, requests[1:])]
        last = result["ended_at"] - requests[-1]["finished_at"]
        rows.append({
            "set": result["set"], "step": result["step"], "before_first_request_ms": first * 1000, "gap_between_requests_ms": [g * 1000 for g in gaps],
            "after_last_response_ms": last * 1000, "total_ms": (result["ended_at"] - result["started_at"]) * 1000, "requests": len(requests),
        })
    return rows


def median(values: list[float]):
    return round(statistics.median(values), 1) if values else None


def timing_summary(rows: list[dict], prefix: str) -> dict:
    chosen = [row for row in rows if row["set"].startswith(prefix)]
    return {
        "turns": len(chosen),
        "before_first_request_ms": median([row["before_first_request_ms"] for row in chosen]),
        "gap_between_requests_ms": median([gap for row in chosen for gap in row["gap_between_requests_ms"]]),
        "after_last_response_ms": median([row["after_last_response_ms"] for row in chosen]),
        "total_ms": median([row["total_ms"] for row in chosen]),
    }


def fault_rows(server: Path, runners: dict) -> list[dict]:
    rows = []
    names = sorted({r["set"] for data in runners.values() for r in data["results"] if r["set"].startswith("fault-")})
    for name in names:
        row = {"fault": name[len("fault-"):]}
        for runner, data in runners.items():
            result = next((r for r in data["results"] if r["set"] == name), None)
            if not result:
                continue
            requests = load_requests(server, runner, name, result["step"])
            row[runner] = {"status": result["status"], "requests": len(requests), "ms": round((result["ended_at"] - result["started_at"]) * 1000),
                           "error": result.get("error"), "detail": result.get("error_detail"), "reasons": result.get("request_reasons")}
        rows.append(row)
    return rows


def outcome_differences(runners: dict) -> list[dict]:
    if "codex" not in runners or "direct" not in runners:
        return []
    direct = {(r["set"], r["step"]): r for r in runners["direct"]["results"]}
    rows = []
    for a in runners["codex"]["results"]:
        b = direct.get((a["set"], a["step"]))
        if not b or a["set"].startswith("fault-"):
            continue
        keys = ("status", "final_text", "audit_status", "request_reasons")
        changed = [key for key in keys if a.get(key) != b.get(key)]
        progress = [line for line in a.get("progress", []) if not line.startswith("reasoning:")], [line for line in b.get("progress", []) if not line.startswith("reasoning:")]
        if progress[0] != progress[1]:
            changed.append("progress")
        missing = sorted(set(a.get("audit_keys", [])) ^ set(b.get("audit_keys", [])))
        if changed or missing:
            rows.append({"set": a["set"], "step": a["step"], "changed": changed, "audit_keys_differ": missing,
                         "progress": {"codex": progress[0][:12], "direct": progress[1][:12]} if "progress" in changed else None,
                         "values": {key: {"codex": short(a.get(key)), "direct": short(b.get(key))} for key in changed if key != "progress"}})
    return rows


def cache_rows(runners: dict) -> dict:
    rows = {}
    for runner, data in runners.items():
        chosen = [r for r in data["results"] if r["set"] == "real"]
        rows[runner] = [{"step": r["step"], "status": r["status"], "cache_states": r.get("cache_states"), "tokens": r.get("request_tokens"), "usd": r.get("estimated_cost_usd")} for r in chosen]
    return rows


def megabytes(value) -> float:
    return round((value or 0) / (1024 * 1024), 1)


def report(summary: dict) -> str:
    lines = ["# Codex 版と Claude 直結版の比較", ""]
    requests = summary["requests"]
    lines += [f"届いた要求: 同じ {requests['identical']} 件 / 違う {requests['different']} 件", ""]
    if requests["codex_only_text"]:
        lines.append("Codex だけが足す文(比較から除いた):")
        lines += [f"- {count} 回: `{text}`" for text, count in requests["codex_only_text"]]
        lines.append("")
    seen: dict[str, dict] = {}
    for pair in requests["pairs"]:
        for item in pair["differences"]:
            seen.setdefault(re.sub(r"\[\d+\]", "[]", item["path"]), item)
    if seen:
        lines += ["違いの種類(同じ場所は 1 件にまとめた):", "", "| 場所 | Codex | 直結 |", "|---|---|---|"]
        for path, item in seen.items():
            codex = str(item.get("codex")).replace("|", "\\|").replace("\n", " ")[:120]
            direct = str(item.get("direct")).replace("|", "\\|").replace("\n", " ")[:120]
            lines.append(f"| `{path}` | {codex} | {direct} |")
        lines.append("")
    lines += ["## 時間(中央値、ミリ秒)", "", "| 場面 | 版 | 件数 | 最初の要求まで | 要求の間 | 最後の応答の後 | 合計 |", "|---|---|---|---|---|---|---|"]
    for prefix, label in (("warm", "起動直後"), ("normal", "固定の応答"), ("replay", "録画の再生")):
        for runner, table in summary["timing"].items():
            row = table[prefix]
            if row["turns"]:
                lines.append(f"| {label} | {runner} | {row['turns']} | {row['before_first_request_ms']} | {row['gap_between_requests_ms']} | {row['after_last_response_ms']} | {row['total_ms']} |")
    lines += ["", "## 起動とメモリ", "", "| 版 | 起動 ms | 起動後 MB | 最後 MB | 最大 MB |", "|---|---|---|---|---|"]
    for runner, data in summary["runtime"].items():
        memory = data["memory"]
        lines.append(f"| {runner} | {data['startup_ms']} | {megabytes(memory['after_start']['footprint'])} | {megabytes(memory['end']['footprint'])} | {megabytes(memory['end']['lifetime_peak'])} |")
    lines += ["", "## 故障時", "", "| 故障 | Codex | 直結 |", "|---|---|---|"]
    for row in summary["faults"]:
        cell = lambda data: f"{data['status']} / {data['requests']} 要求 / {data['ms']} ms" if data else "-"
        lines.append(f"| {row['fault']} | {cell(row.get('codex'))} | {cell(row.get('direct'))} |")
    lines += ["", f"結果の違い(通常の場面): {len(summary['outcomes'])} 件", ""]
    for row in summary["outcomes"][:20]:
        lines.append(f"- {row['set']}/{row['step']}: {', '.join(row['changed']) or '-'} {('実行監査の項目 ' + ', '.join(row['audit_keys_differ'])) if row['audit_keys_differ'] else ''}")
    if any(summary["cache"].values()):
        lines += ["", "## 実 API", "", "| 版 | 依頼 | 状態 | キャッシュ | 概算 USD |", "|---|---|---|---|---|"]
        for runner, rows in summary["cache"].items():
            for row in rows:
                lines.append(f"| {runner} | {row['step']} | {row['status']} | {', '.join(str(s) for s in row['cache_states'] or [])} | {row['usd']} |")
    return "\n".join(lines) + "\n"


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--server", required=True, type=Path)
    parser.add_argument("--outcomes", required=True, type=Path)
    parser.add_argument("--out", required=True, type=Path)
    args = parser.parse_args()
    runners = {path.stem: json.loads(path.read_text()) for path in sorted(args.outcomes.glob("*.json"))}
    rows = {name: timing(args.server, name, data["results"]) for name, data in runners.items()}
    summary = {
        "requests": compare_requests(args.server),
        "timing": {name: {prefix: timing_summary(table, prefix) for prefix in ("warm", "normal", "replay")} for name, table in rows.items()},
        "runtime": {name: {"startup_ms": data["startup_ms"], "memory": data["memory"]} for name, data in runners.items()},
        "faults": fault_rows(args.server, runners),
        "outcomes": outcome_differences(runners),
        "cache": cache_rows(runners),
    }
    args.out.mkdir(parents=True, exist_ok=True)
    (args.out / "summary.json").write_text(json.dumps(summary, ensure_ascii=False, indent=1))
    text = report(summary)
    (args.out / "report.md").write_text(text)
    print(text)


if __name__ == "__main__":
    main()
