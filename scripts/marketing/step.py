#!/usr/bin/env python3
"""宣伝用の収録の操作(Dev Box で、`session.sh start` の後に動かす)。E2E の操作役(`scripts/e2e/ui.py`)を束ねる。

    step.py launch                  アプリを起動して、タイムラインの1問目が出るまで待つ
    step.py problem                 今の問題の文を出し、画面を $DEVBOX_FILES/shots に撮る
    step.py answer <答案の画像>     答案の画像をカメラに差し込んで撮り、採点の結果が出るまで待つ
    step.py next                    「次へ」を押して、次の問題が出るまで待つ
    step.py skip                    「飛ばす」を押して、次の問題が出るまで待つ
    step.py shot <名前>             画面を撮る
    step.py open <起動引数...>      起動引数を付けてアプリを起動する(問題を待たない。単元づくりの収録用)
    step.py chatcam <画像>          会話の入力欄の「添付」→「撮る」で、画像をカメラに差し込んで撮る
    step.py say <文>                会話の入力欄に打って送る
    step.py ui <op> [key=value...]  操作役にそのまま1つ命令を送る(tapid・wait・tree など)

答案の画像はアプリが撮るたびに読み直す(`ChatCamera.swift` の `testPhoto`)ので、撮る直前に差し替えれば問題ごとに違う答案になる。
`take.py` もこのファイルの関数を使う。
"""
from __future__ import annotations

import json
import os
import re
import shutil
import subprocess
import sys
import time
from pathlib import Path

ROOT: Path = Path(__file__).resolve().parents[2]
WORK: Path = Path(os.environ.get("MARKETING_DIR") or Path(os.environ.get("RUNNER_TEMP", "/tmp")) / "marketing")
UI: Path = ROOT / "scripts/e2e/ui.py"
PROBLEM_IDS: tuple[str, ...] = ("timeline-prompt", "timeline-math", "timeline-question")


def ui(op: str, **args: object) -> str:
    """操作役に1つ命令を送り、結果の1行を返す。"""
    env = {**os.environ, "E2E_DIR": str(WORK)}
    argv = [sys.executable, str(UI), op] + [f"{k}={v}" for k, v in args.items()]
    done = subprocess.run(argv, env=env, capture_output=True, text=True)
    return done.stdout.strip()


def tree() -> str:
    path = ui("tree")
    try:
        return Path(path).read_text()
    except OSError:
        return ""


def label_of(text: str, identifier: str) -> str:
    """要素の木(`app.debugDescription`)から、identifier の付いた要素のラベルを取る。"""
    for line in text.splitlines():
        if f"identifier: '{identifier}'" in line:
            found = re.search(r"label: '((?:[^'\\]|\\.)*)'", line)
            if found:
                return found.group(1)
    return ""


def problem() -> dict[str, str]:
    text = tree()
    found = {key: label_of(text, key) for key in PROBLEM_IDS}
    found["card"] = next((m.group(1) for m in re.finditer(r"identifier: 'timeline-card-([a-z_]+)'", text)), "")
    found["actions"] = ",".join(sorted(set(re.findall(r"identifier: '(timeline-(?:capture|skip|send|next|ask))'", text))))
    return found


def has(identifier: str, timeout: float) -> bool:
    return ui("wait", id=identifier, timeout=timeout) == "exists"


def wait_problem(previous: str | None = None, timeout: float = 600) -> dict[str, str]:
    """問題が出て、撮る(か飛ばす)が押せるまで待つ。previous を渡したら、それと違う問題になるまで待つ。"""
    deadline = time.time() + timeout
    while time.time() < deadline:
        if has("timeline-capture", 5) or has("timeline-skip", 1):
            now = problem()
            key = now["timeline-prompt"] + now["timeline-math"] + now["timeline-question"]
            if key and (previous is None or key != previous):
                return now
        time.sleep(1)
    raise SystemExit("問題が出ない(時間切れ)")


def problem_key(found: dict[str, str]) -> str:
    return found["timeline-prompt"] + found["timeline-math"] + found["timeline-question"]


def shot(name: str) -> str:
    target = Path(os.environ.get("DEVBOX_FILES", WORK / "files")) / "shots"
    target.mkdir(parents=True, exist_ok=True)
    path = target / f"{name}.png"
    subprocess.run(["xcrun", "simctl", "io", os.environ["SIMULATOR_UDID"], "screenshot", str(path)], capture_output=True)
    return str(path)


def answer(image: str, timeout: float = 600) -> str:
    """答案を撮って採点を待つ。結果(correct/partial/wrong)を返す。"""
    shutil.copyfile(image, WORK / "camera.jpg")
    if ui("tapid", id="timeline-capture", timeout=10) != "ok":
        raise SystemExit("「撮る」が無い")
    if ui("tapid", id="chat-camera-shutter", timeout=15) != "ok":
        raise SystemExit("シャッターが出ない")
    deadline = time.time() + timeout
    while time.time() < deadline:
        for grade in ("correct", "partial", "wrong"):
            if has(f"timeline-result-{grade}", 1):
                return grade
        time.sleep(1)
    raise SystemExit("採点の結果が出ない(時間切れ)")


def advance(button: str, previous: str) -> dict[str, str]:
    if ui("tapid", id=button, timeout=10) != "ok":
        raise SystemExit(f"{button} が無い")
    return wait_problem(previous)


def chat_camera(image: str) -> None:
    """会話の入力欄の「添付」→「撮る」→ シャッター。撮った写真は入力欄に添付される。"""
    shutil.copyfile(image, WORK / "camera.jpg")
    for target in ("添付", "撮る"):
        if ui("tapid", id=target, timeout=10) != "ok":
            raise SystemExit(f"「{target}」が無い")
        time.sleep(0.6)
    ui("alert", text="許可", timeout=2)
    if ui("tapid", id="chat-camera-shutter", timeout=15) != "ok":
        raise SystemExit("シャッターが出ない")


def say(text: str) -> None:
    # 入力欄の識別子は会話の画面の識別子(chat-page)に上書きされているので、空の時の案内の文でたたく。
    if all(ui("tapid", id=key, timeout=5) != "ok" for key in ("chat-composer-input", "聞きたいことを書く")):
        raise SystemExit("入力欄が無い")
    time.sleep(0.6)
    typed = ui("type", text=text)
    if typed != "ok":
        raise SystemExit(f"打てない: {typed}")
    time.sleep(0.4)
    if ui("tapid", id="送信", timeout=10) != "ok":
        raise SystemExit("送信が押せない")


def main(argv: list[str]) -> None:
    op = argv[0] if argv else ""
    if op == "launch":
        print(ui("launch", text="-skip-onboarding"))
        print(json.dumps(wait_problem(), ensure_ascii=False))
    elif op == "problem":
        print(json.dumps(problem(), ensure_ascii=False))
        print(shot(argv[1] if len(argv) > 1 else time.strftime("p-%H%M%S")))
    elif op == "answer":
        print(answer(str(ROOT / argv[1]) if not argv[1].startswith("/") else argv[1]))
        print(shot(time.strftime("r-%H%M%S")))
        print(json.dumps(problem(), ensure_ascii=False))
    elif op in ("next", "skip"):
        before = problem_key(problem())
        found = advance("timeline-next" if op == "next" else "timeline-skip", before)
        print(json.dumps(found, ensure_ascii=False))
        print(shot(time.strftime("p-%H%M%S")))
    elif op == "shot":
        print(shot(argv[1]))
    elif op == "open":
        print(ui("launch", text=" ".join(argv[1:])))
    elif op == "chatcam":
        chat_camera(str(ROOT / argv[1]) if not argv[1].startswith("/") else argv[1])
        print("ok")
    elif op == "say":
        say(" ".join(argv[1:]))
        print("ok")
    elif op == "ui":
        print(ui(argv[1], **dict(a.split("=", 1) for a in argv[2:])))
    else:
        raise SystemExit(__doc__)


if __name__ == "__main__":
    main(sys.argv[1:])
