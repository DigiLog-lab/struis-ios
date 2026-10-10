#!/usr/bin/env python3
"""画面に出した段(アプリの turn-activity の記録)と、Codex の rollout の出来事を時刻順に並べる(信頼性計画 P2: 偽の段が無いかの確認)。
usage: correlate.py <codex home> <app-activity.log> [since HH:MM:SS] [until HH:MM:SS]
app-activity.log は `log show --predicate 'subsystem == "com.digiloglab.strius" AND category == "turn-activity"' --style compact` の出力。
rollout 側は、推論・コマンド(exec_command)・委任(struis_delegate)・途中経過の文・圧縮・最後の返事を出す。本文は出さない。"""
import sys, json, glob, os, re
from datetime import datetime, timezone, timedelta

home, applog = sys.argv[1], sys.argv[2]
since = sys.argv[3] if len(sys.argv) > 3 else "00:00:00"
until = sys.argv[4] if len(sys.argv) > 4 else "23:59:59"
JST = timezone(timedelta(hours=9))
rows = []
for path in glob.glob(home + "/sessions/**/*.jsonl", recursive=True):
    thread = os.path.basename(path)[-41:-6]
    for line in open(path):
        try:
            d = json.loads(line)
        except ValueError:
            continue
        ts = d.get("timestamp")
        if not ts:
            continue
        t = datetime.fromisoformat(ts.replace("Z", "+00:00")).astimezone(JST).strftime("%H:%M:%S")
        p = d.get("payload") or {}
        kind = p.get("type")
        what = None
        if d.get("type") == "response_item":
            if kind == "reasoning":
                what = f"reasoning summary={len(p.get('summary') or [])}"
            elif kind == "function_call":
                name = p.get("name")
                args = p.get("arguments") or ""
                if name == "exec_command":
                    try:
                        cmd = json.loads(args).get("cmd", "")
                    except ValueError:
                        cmd = args
                    what = "exec_command " + re.sub(r"\s+", " ", cmd)[:60]
                else:
                    what = f"function_call {name}"
            elif kind == "message" and p.get("role") == "assistant":
                what = f"message phase={p.get('phase')}"
        elif d.get("type") == "compacted":
            what = "compacted"
        elif d.get("type") == "event_msg" and kind in ("task_started", "task_complete", "turn_aborted"):
            what = kind
        if what:
            rows.append((t, "rollout", thread[:8] + " " + what))
for line in open(applog):
    m = re.match(r"\S+ (\d\d:\d\d:\d\d)\.\d+ .*turn-activity\] activity (\S+) (.*)", line)
    if m:
        rows.append((m.group(1), "screen ", m.group(2)[:22] + " " + m.group(3)[:90]))
for t, src, text in sorted(rows):
    if since <= t <= until:
        print(t, src, text)
