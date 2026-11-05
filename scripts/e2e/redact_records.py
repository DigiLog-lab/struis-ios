#!/usr/bin/env python3
"""模擬サーバーの記録(scenarios・tapes)を、配信の本文と認証情報を伏せて写す(artifact に入れる用)。

    python3 scripts/e2e/redact_records.py --assets strius/Resources/Prompts \
        --in <log-dir> --out <出力先>

- 配信の本文: `--assets` の各ファイルの 20 文字以上の行(JSON の資産は中の文字列の値)が文字列の中に現れたら `‹配信の本文›` に置き換える
  (system・AGENTS.md・Skill・道具の結果の中の写しも同じ)。続く置き換えは 1 つにまとめる。
- 認証情報: `sk-ant-` で始まる値と、`x-api-key`・`authorization` のキーの値を伏せる。
- 置き換えた数を `redaction.json` に残す。伏せた後にも `--assets` の行が残っていないかを確かめ、残れば失敗する。
"""
from __future__ import annotations

import argparse
import json
import re
from pathlib import Path

MARK = "‹配信の本文›"
SECRET = re.compile(r"sk-ant-[A-Za-z0-9_\-]{8,}")
MIN_LINE = 20


def asset_lines(root: Path) -> list[str]:
    lines: set[str] = set()
    for path in root.rglob("*"):
        if not path.is_file() or path.name == "manifest.json":
            continue
        try:
            text = path.read_text(encoding="utf-8")
        except (UnicodeDecodeError, OSError):
            continue
        try:
            # JSON の資産(schema など)は書式の行ではなく、中の文字列の値で伏せる。
            values: list[str] = list(strings(json.loads(text)))
        except ValueError:
            values = text.splitlines()
        for line in values:
            line = line.strip()
            if len(line) >= MIN_LINE:
                lines.add(line)
    # 長い行から置き換える(短い行が長い行の一部を先に壊さないように)。
    return sorted(lines, key=len, reverse=True)


def strings(value):
    if isinstance(value, str):
        yield value
    elif isinstance(value, list):
        for item in value:
            yield from strings(item)
    elif isinstance(value, dict):
        for item in value.values():
            yield from strings(item)


class Redactor:
    def __init__(self, lines: list[str]):
        self.lines = lines
        self.count = 0

    def text(self, value: str) -> str:
        if len(value) < MIN_LINE:
            return value
        for line in self.lines:
            if line in value:
                self.count += value.count(line)
                value = value.replace(line, MARK)
        value = re.sub(f"(?:{re.escape(MARK)}\\s*)+{re.escape(MARK)}", MARK, value)
        return SECRET.sub("‹秘密›", value)

    def walk(self, value):
        if isinstance(value, str):
            return self.text(value)
        if isinstance(value, list):
            return [self.walk(item) for item in value]
        if isinstance(value, dict):
            return {key: ("‹秘密›" if key.lower() in ("x-api-key", "authorization") else self.walk(item)) for key, item in value.items()}
        return value


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--assets", required=True, type=Path)
    parser.add_argument("--in", dest="source", required=True, type=Path)
    parser.add_argument("--out", required=True, type=Path)
    args = parser.parse_args()
    lines = asset_lines(args.assets)
    redactor = Redactor(lines)
    files = 0
    for path in sorted(args.source.rglob("*.json")):
        target = args.out / path.relative_to(args.source)
        target.parent.mkdir(parents=True, exist_ok=True)
        data = redactor.walk(json.loads(path.read_text()))
        # 置き換えた後の文字列に、配信の行が 1 つも残っていないことを確かめる。
        rendered = json.dumps(data, ensure_ascii=False, indent=1)
        left = [line for line in lines if any(line in text for text in strings(data))]
        if left:
            raise SystemExit(f"{path}: 配信の本文が残っている ({left[0][:40]}…)")
        if SECRET.search(rendered):
            raise SystemExit(f"{path}: 認証情報らしい値が残っている")
        target.write_text(rendered)
        files += 1
    (args.out / "redaction.json").write_text(json.dumps(
        {"files": files, "asset_lines": len(lines), "replacements": redactor.count, "mark": MARK}, ensure_ascii=False, indent=1))
    print(f"{files} 件を写した(配信の行 {len(lines)} 種、置き換え {redactor.count} 回)")


if __name__ == "__main__":
    main()
