#!/usr/bin/env python3
"""宣伝用の撮影(Dev Box で動かす)。録音した返事を再生し、決めた手順どおりに解きながら画面を録画する。

    python3 scripts/marketing/take.py scripts/marketing/takes/demo1.json

手順のファイル(JSON):
    {"tape": "demo1", "answers": ["scripts/marketing/answers/demo1/01.jpg", ...],
     "hold_problem": 2.5, "hold_result": 3.0, "hold_end": 3.0}

1問目が出てから録画を始め(起動の画面は撮らない)、答案ごとに「問題を見せる → 撮る → 結果を見せる → 次へ」を繰り返す。
最後の「次へ」の後の問題を hold_end 秒見せて止める。$DEVBOX_FILES に次を置く:
    take.mp4         シミュレータの画面の録画(`xcrun simctl io recordVideo`)
    take.json        録画の開始からの秒数で、何が起きたか(編集で切り出しに使う)
単元づくりのように問題を解く流れでないものは、answers の代わりに actions(操作の列)を書く:
    {"tape": "unit-textbook", "launch": "-skip-onboarding -workbook-empty", "wait_first": "timeline-guide-create-unit",
     "actions": [{"do": "tap", "id": "..."}, {"do": "chatcam", "image": "..."}, {"do": "say", "text": "..."},
                 {"do": "wait", "id": "...", "timeout": 300}, {"do": "hold", "seconds": 2}]}
録画は wait_first の要素が出てから始める。各操作の前後の時刻を take.json に残す。
返事は録音の種類ごとの順で返る(`fake_anthropic.py` の `match: kind`)ので、録音した時と同じ手順なら同じ問題・同じ採点になる。
"""
from __future__ import annotations

import json
import os
import shutil
import signal
import subprocess
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import step  # noqa: E402


def run_actions(actions: list[dict], mark) -> None:
    for action in actions:
        do = action["do"]
        mark(f"{do}-start", **{k: v for k, v in action.items() if k != "do"})
        if do == "tap":
            if step.ui("tapid", id=action["id"], timeout=action.get("timeout", 15)) != "ok":
                raise SystemExit(f"{action['id']} が押せない")
        elif do == "chatcam":
            step.chat_camera(str(step.ROOT / action["image"]))
        elif do == "say":
            step.say(action["text"])
        elif do == "wait":
            deadline = time.time() + action.get("timeout", 300)
            while step.ui("wait", id=action["id"], timeout=2) != "exists":
                if time.time() > deadline:
                    raise SystemExit(f"{action['id']} が出ない")
        elif do == "hold":
            time.sleep(action["seconds"])
        mark(f"{do}-end")


def main(plan_path: str) -> None:
    plan = json.loads(Path(plan_path).read_text())
    files = Path(os.environ.get("DEVBOX_FILES", step.WORK / "files"))
    files.mkdir(parents=True, exist_ok=True)
    session = str(step.ROOT / "scripts/marketing/session.sh")
    subprocess.run([session, "start", "replay", plan["tape"]], check=True)
    video = step.WORK / "take.mp4"
    events: list[dict] = []
    recorder = None
    try:
        step.ui("launch", text=plan.get("launch", "-skip-onboarding"))
        if "actions" in plan:
            if step.ui("wait", id=plan["wait_first"], timeout=120) != "exists":
                raise SystemExit(f"{plan['wait_first']} が出ない")
            current = {}
        else:
            current = step.wait_problem()
        # 録画はアプリが開いて1問目が出てから。
        recorder = subprocess.Popen(["xcrun", "simctl", "io", os.environ["SIMULATOR_UDID"], "recordVideo", "--codec=h264", "--force", str(video)],
                                    stdout=subprocess.PIPE, stderr=subprocess.STDOUT, start_new_session=True)
        started = time.time()
        time.sleep(1.0)

        def mark(what: str, **extra: object) -> None:
            events.append({"t": round(time.time() - started, 2), "event": what, **extra})
            print(f"{events[-1]['t']:7.2f} {what} {json.dumps(extra, ensure_ascii=False) if extra else ''}", flush=True)

        if "actions" in plan:
            run_actions(plan["actions"], mark)
            plan["answers"] = []
        else:
            mark("problem", problem=step.problem_key(current))
        for index, image in enumerate(plan["answers"], 1):
            time.sleep(plan.get("hold_problem", 2.5))
            mark("capture", n=index)
            grade = step.answer(str(step.ROOT / image))
            mark("result", n=index, grade=grade)
            time.sleep(plan.get("hold_result", 3.0))
            mark("next", n=index)
            current = step.advance("timeline-next", step.problem_key(current))
            mark("problem", problem=step.problem_key(current))
        time.sleep(plan.get("hold_end", 3.0))
        mark("end")
    finally:
        if recorder is not None:
            os.killpg(recorder.pid, signal.SIGINT)
            try:
                recorder.wait(timeout=60)
            except subprocess.TimeoutExpired:
                os.killpg(recorder.pid, signal.SIGKILL)
        (files / "take.json").write_text(json.dumps({"plan": plan, "events": events}, ensure_ascii=False, indent=1))
        if video.exists():
            shutil.copyfile(video, files / "take.mp4")
        subprocess.run([session, "stop"])


if __name__ == "__main__":
    main(sys.argv[1])
