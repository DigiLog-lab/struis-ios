#!/usr/bin/env python3
"""Codex 版と Claude 直結版の比較をまとめる(`RunnerComparisonLiveTests` の結果を読む)。

    python3 scripts/e2e/compare_runners.py --server <dir>/server --outcomes <dir>/outcomes --out <dir>/report

- 届いた要求: 同じ場面・同じ順番の要求を、ID や時刻など毎回変わるものを揃えて比べる。Codex だけが足す権限の注記・環境情報・
  アプリの案内(`<permissions instructions>`・`<environment_context>`・`<apps_instructions>`)と `request_user_input` の道具は
  `allowed` として分けて数え、それ以外の違いはすべて `differences` に出す。これらの節は、1 つの文(翻訳 v2 の `system` など)の
  中に "\n\n" で挟まっていても取り除く。Skill の一覧(`<skills_instructions>`)と AGENTS.md は直結版も同じに作るので比べる。
- 場面の置き場所は `<server>/scenarios/<版>/<組>/<段>/NNNN.json`(会話は組 `chat`・段が場面の名前、構造化は組 `structured`)。
- 結果・時間・故障時・メモリを版ごとに並べる。時間は同じ計算機の時計で測った模擬サーバーの到着時刻を使う。

標準ライブラリだけで動く。結果は `summary.json` と `report.md`。
"""
from __future__ import annotations

import argparse
import json
import re
import statistics
from pathlib import Path

CODEX_ONLY = ("<permissions instructions>", "<environment_context>", "<apps_instructions>")
# 文の中に埋まった Codex だけの節(閉じタグまで)。前の区切りの空行も一緒に取る。
CODEX_ONLY_SECTIONS = [re.compile(r"(?:\n\n)?" + re.escape(tag) + r".*?" + re.escape(tag.replace("<", "</", 1)), re.S) for tag in CODEX_ONLY]
CODEX_ONLY_TOOLS = ("request_user_input",)
CLOCK = re.compile(r"(?<![0-9:])\d{2}:\d{2}(?![0-9:])")
TOP_LEVEL = ("model", "max_tokens", "stream", "thinking", "output_config", "tool_choice", "cache_control", "tools")
UUID = re.compile(r"[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}", re.I)
PLAN_ID = re.compile(r"compare-[a-z0-9-]+?-[0-9a-f]{8}\b")
PATHS = re.compile(r"/[^\s\"']*/(?:workspace|Containers)/[^\s\"']*")
STAMP = re.compile(r"\d{4}-\d{2}-\d{2}[T ]\d{2}:\d{2}:\d{2}(?:\.\d+)?Z?")
TOOL_ID = re.compile(r"toolu_[A-Za-z0-9]+")
TIMING_SETS = (("warm", "起動直後"), ("normal", "固定の応答"), ("replay", "録画の再生"), ("structured", "構造化の各種"), ("chat", "会話"))
DETAIL_SETS = ("structured", "chat")


def normalize_text(text: str) -> str:
    text = re.sub(r"fake-sig-\d+", "<sig>", text); text = re.sub(r"検証用の考えごと \d+", "<thinking>", text)
    stripped = text.strip()
    if stripped.startswith("{") and stripped.endswith("}"):
        try:
            text = json.dumps(json.loads(stripped), sort_keys=True, ensure_ascii=False)
        except ValueError:
            pass
    for pattern, value in ((UUID, "<uuid>"), (PLAN_ID, "<plan>"), (PATHS, "<path>"), (STAMP, "<time>"), (TOOL_ID, "<tool-id>"), (CLOCK, "<hhmm>")):
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


def strip_codex_sections(text: str) -> tuple[str, list[str]]:
    """文の中の Codex だけの節を取り除く。戻り値の 2 つ目は取り除いた節。"""
    removed: list[str] = []
    for pattern in CODEX_ONLY_SECTIONS:
        def take(match):
            removed.append(match.group(0).lstrip("\n"))
            return ""
        text = pattern.sub(take, text)
    if removed:
        text = text.lstrip("\n")
    return text, removed


def split_codex_only(blocks) -> tuple[list, list]:
    """Codex だけの文を除く。丸ごとの文は落とし、埋まった節は文から取り除く(残りが空なら落とす)。"""
    if isinstance(blocks, str):
        blocks = [{"type": "text", "text": blocks}]
    kept, removed = [], []
    for block in blocks:
        if not isinstance(block, dict) or block.get("type") != "text":
            kept.append(block)
            continue
        if is_codex_only(block):
            text, sections = strip_codex_sections(str(block.get("text", "")))
            # 閉じタグの無い文は、文ごと Codex だけのものとして落とす。
            if not sections or not text.strip():
                removed.append(block)
                continue
            removed += [{"type": "text", "text": section} for section in sections]
            kept.append({**block, "text": text})
            continue
        text, sections = strip_codex_sections(str(block.get("text", "")))
        removed += [{"type": "text", "text": section} for section in sections]
        if sections and not text.strip():
            continue
        kept.append({**block, "text": text} if sections else block)
    return kept, removed


def canonical(body: dict) -> tuple[dict, list[str]]:
    """比べる形にする。戻り値の 2 つ目は、取り除いた Codex だけの文の頭。"""
    removed: list[dict] = []
    system, gone = split_codex_only(body.get("system") or [])
    removed += gone
    messages = []
    for message in body.get("messages") or []:
        content = message.get("content")
        if isinstance(content, str):
            content = [{"type": "text", "text": content}]
        if isinstance(content, list):
            content, gone = split_codex_only(content)
            removed += gone
            if not content:
                continue
            message = {**message, "content": content}
        messages.append(message)
    result = {key: body.get(key) for key in TOP_LEVEL}
    result["diagnostics_present"] = "diagnostics" in body
    result["tools"] = [t for t in (body.get("tools") or []) if t.get("name") not in CODEX_ONLY_TOOLS]
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


def scenario_steps(server: Path) -> list[tuple[str, str]]:
    """どちらかの版に要求が届いた (組, 段)。"""
    steps: set[tuple[str, str]] = set()
    for runner in ("codex", "direct"):
        root = server / "scenarios" / runner
        if not root.exists():
            continue
        for set_dir in (p for p in root.iterdir() if p.is_dir()):
            steps.update((set_dir.name, step_dir.name) for step_dir in set_dir.iterdir() if step_dir.is_dir())
    return sorted(steps)


def compare_requests(server: Path) -> dict:
    pairs = []
    only: dict[str, int] = {}
    for set_name, step in scenario_steps(server):
        # 片方の版で流していない組(録画の `real` など)は比べない。段の要求が片方だけ無いのは違いとして出す。
        if not all((server / "scenarios" / runner / set_name).is_dir() for runner in ("codex", "direct")):
            continue
        codex = load_requests(server, "codex", set_name, step)
        direct = load_requests(server, "direct", set_name, step)
        if not direct and not codex:
            continue
        for index in range(max(len(codex), len(direct))):
            entry = {"set": set_name, "step": step, "index": index + 1}
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
        "by_step": by_step(pairs),
    }


def by_step(pairs: list[dict]) -> list[dict]:
    """組・段ごとの違い(会話の場面・構造化の種類ごとに見えるように)。"""
    groups: dict[tuple[str, str], list[dict]] = {}
    for pair in pairs:
        groups.setdefault((pair["set"], pair["step"]), []).append(pair)
    rows = []
    for (set_name, step), items in sorted(groups.items()):
        paths: dict[str, dict] = {}
        for pair in items:
            for item in pair["differences"]:
                paths.setdefault(re.sub(r"\[\d+\]", "[]", item["path"]), {**item, "request": pair["index"]})
        rows.append({
            "set": set_name, "step": step, "requests": len(items), "identical": sum(not p["differences"] for p in items),
            "different": sum(bool(p["differences"]) for p in items), "paths": list(paths.values()),
        })
    return rows


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


def turn_rows(runners: dict) -> list[dict]:
    """構造化と会話の場面の結果を、版ごとに並べる。"""
    rows: dict[tuple[str, str], dict] = {}
    for runner, data in runners.items():
        for result in data["results"]:
            if result["set"] not in DETAIL_SETS:
                continue
            row = rows.setdefault((result["set"], result["step"]), {"set": result["set"], "step": result["step"]})
            row[runner] = {"status": result.get("status"), "ms": round((result["ended_at"] - result["started_at"]) * 1000),
                           "error": result.get("error"), "executions": result.get("execution_count"), "text": short(result.get("final_text") or "")[:120]}
    return list(rows.values())


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
    lines += ["## 場面ごとの要求の違い", "", "| 組/段 | 要求 | 同じ | 違う | 違う場所 |", "|---|---|---|---|---|"]
    for row in requests.get("by_step", []):
        where = ", ".join(f"`{item['path']}`" for item in row["paths"][:6]) + (" …" if len(row["paths"]) > 6 else "")
        lines.append(f"| {row['set']}/{row['step']} | {row['requests']} | {row['identical']} | {row['different']} | {where or '-'} |")
    lines.append("")
    detail = [row for row in requests.get("by_step", []) if row["set"] in DETAIL_SETS and row["paths"]]
    if detail:
        lines += ["### 構造化と会話の違いの中身", ""]
        for row in detail:
            lines.append(f"- **{row['set']}/{row['step']}**")
            for item in row["paths"][:10]:
                codex = str(item.get("codex")).replace("\n", " ")[:160]
                direct = str(item.get("direct")).replace("\n", " ")[:160]
                lines.append(f"  - 要求 {item['request']} `{item['path']}`: Codex `{codex}` / 直結 `{direct}`")
        lines.append("")
    if summary.get("turns"):
        lines += ["## 構造化と会話の結果", "", "| 組/段 | Codex | 直結 |", "|---|---|---|"]
        for row in summary["turns"]:
            cell = lambda data: (f"{data['status']} / {data['ms']} ms / 実行 {data['executions']}" + (f" / {data['error']}" if data.get("error") else "")).replace("|", "\\|") if data else "-"
            lines.append(f"| {row['set']}/{row['step']} | {cell(row.get('codex'))} | {cell(row.get('direct'))} |")
        lines.append("")
    lines += ["## 時間(中央値、ミリ秒)", "", "| 場面 | 版 | 件数 | 最初の要求まで | 要求の間 | 最後の応答の後 | 合計 |", "|---|---|---|---|---|---|---|"]
    for prefix, label in TIMING_SETS:
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
        "timing": {name: {prefix: timing_summary(table, prefix) for prefix, _ in TIMING_SETS} for name, table in rows.items()},
        "turns": turn_rows(runners),
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
