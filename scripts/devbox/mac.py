#!/usr/bin/env python3
"""The web Claude's side of the Dev Box: `mac.py run -- <command>` runs <command> on the macOS runner.

Each command is its own branch `devbox-cmd/<id>` and its result its own branch `devbox-out/<id>`
(scripts/devbox/serve.sh). Both are watched with `git ls-remote`, from the clone of this repository. A
result stays readable for an hour after it finished (`mac.py wait <id>`); the Dev Box deletes it then.

    mac.py start <branch>                                # starts a Dev Box for <branch> (main's devbox.yml)
    mac.py ready                                         # waits until a Dev Box is waiting for commands
    mac.py run -- xcodebuild test-without-building ...   # waits, prints the log tail, exits with its code
    mac.py run -- 'xcrun simctl io booted screenshot "$DEVBOX_FILES/home.png"'
    mac.py run --async -- <command>                      # prints the id and returns
    mac.py wait <id>                                     # the result of an --async command
    mac.py kill                                          # ends the running command
    mac.py stop                                          # ends the running command and the Dev Box
One argument is run as a shell line; several are run as exactly those arguments. Files the command writes
to "$DEVBOX_FILES" are copied to ./devbox-out/<id>/.
"""
from __future__ import annotations

import argparse
import dataclasses
import json
import pathlib
import shlex
import subprocess
import sys
import time
import uuid

CMD_PREFIX: str = "refs/heads/devbox-cmd/"
OUT_PREFIX: str = "refs/heads/devbox-out/"
REPOSITORY: str = "DigiLog-lab/struis-ios"


@dataclasses.dataclass(frozen=True)
class Result:
    id: str
    state: str
    exit_code: int | None
    times: dict[str, str]
    log_tail: str


def git(*args: str, input_text: str | None = None) -> str:
    completed: subprocess.CompletedProcess[str] = subprocess.run(
        ["git", *args], input=input_text, text=True, capture_output=True, check=True
    )
    return completed.stdout.strip()


def remote_sha(ref: str) -> str:
    line: str = git("ls-remote", "origin", ref)
    return line.split("\t", 1)[0] if line else ""


def new_id(suffix: str = "") -> str:
    return time.strftime("%Y%m%dT%H%M%S", time.gmtime()) + "-" + uuid.uuid4().hex[:6] + suffix


def send(command: str, command_id: str) -> None:
    blob: str = git("hash-object", "-w", "--stdin", input_text=command + "\n")
    tree: str = git("mktree", input_text=f"100644 blob {blob}\tcmd.sh\n")
    commit: str = git("commit-tree", tree, "-m", f"devbox command {command_id}")
    git("push", "-q", "origin", f"{commit}:{CMD_PREFIX}{command_id}")


def read_result(sha: str, destination: pathlib.Path | None) -> Result:
    git("fetch", "-q", "--depth", "1", "origin", sha)

    def show(name: str) -> str:
        try:
            return git("show", f"{sha}:{name}")
        except subprocess.CalledProcessError:
            return ""

    times: dict[str, str] = {}
    for line in show("times").splitlines():
        key, _, value = line.partition("=")
        times[key] = value
    exit_text: str = show("exit")
    if destination is not None:
        listing: str = git("ls-tree", "-r", "--name-only", sha, "files")
        for name in filter(None, listing.splitlines()):
            target: pathlib.Path = destination / name.removeprefix("files/")
            target.parent.mkdir(parents=True, exist_ok=True)
            data: bytes = subprocess.run(
                ["git", "show", f"{sha}:{name}"], capture_output=True, check=True
            ).stdout
            target.write_bytes(data)
    return Result(
        id=show("id"),
        state=show("state"),
        exit_code=int(exit_text) if exit_text.lstrip("-").isdigit() else None,
        times=times,
        log_tail=show("log.tail.txt"),
    )


def wait(name: str, timeout: float, poll: float, want: str, quiet: bool) -> Result:
    """Waits until devbox-out/<name> shows the state `want` ("done" or "ready")."""
    deadline: float = time.monotonic() + timeout
    seen: str = ""
    printed_line: str = ""
    while time.monotonic() < deadline:
        sha: str = remote_sha(OUT_PREFIX + name)
        if sha and sha != seen:
            seen = sha
            result: Result = read_result(sha, None)
            if result.state == want:
                if want == "done":
                    # The Dev Box deletes the branch an hour later; this token cannot delete branches.
                    result = read_result(sha, pathlib.Path("devbox-out") / name)
                return result
            lines: list[str] = result.log_tail.splitlines()
            if not quiet and lines and lines[-1] != printed_line:
                printed_line = lines[-1]
                print(f"[devbox {name} running] {printed_line}", file=sys.stderr, flush=True)
        time.sleep(poll)
    hint: str = f" (still running? `mac.py wait {name}`, or `mac.py kill`)" if want == "done" else ""
    raise TimeoutError(f"no {want} for {name} within {timeout:.0f}s{hint}")


def start(branch: str, idle_minutes: int) -> None:
    """repository_dispatch: runs main's devbox.yml (workflow_dispatch is refused to the web Claude's token)."""
    payload: str = json.dumps(
        {"event_type": "devbox", "client_payload": {"branch": branch, "idle_minutes": str(idle_minutes)}}
    )
    subprocess.run(
        ["gh", "api", "-X", "POST", f"repos/{REPOSITORY}/dispatches", "--input", "-"],
        input=payload, text=True, check=True,
    )


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(prog="mac")
    sub = parser.add_subparsers(dest="action", required=True)
    start_parser = sub.add_parser("start")
    start_parser.add_argument("branch")
    start_parser.add_argument("--idle-minutes", type=int, default=15)
    run = sub.add_parser("run")
    run.add_argument("--async", dest="run_async", action="store_true")
    run.add_argument("--timeout", type=float, default=540.0)
    run.add_argument("command", nargs=argparse.REMAINDER)
    wait_parser = sub.add_parser("wait")
    wait_parser.add_argument("id")
    wait_parser.add_argument("--timeout", type=float, default=540.0)
    ready = sub.add_parser("ready")
    ready.add_argument("--timeout", type=float, default=600.0)
    sub.add_parser("stop")
    sub.add_parser("kill")
    args = parser.parse_args(argv)

    if args.action == "start":
        start(args.branch, args.idle_minutes)
        print(f"Dev Box requested for {args.branch}; `mac.py ready` waits for it", file=sys.stderr)
        return 0
    if args.action == "ready":
        result: Result = wait("ready", args.timeout, 3.0, "ready", True)
        print("ready: " + " ".join(f"{key}={value}" for key, value in result.times.items()))
        return 0
    if args.action in ("stop", "kill"):
        control_id: str = new_id(f"-{args.action}")
        send("", control_id)
        print(control_id)
        return 0
    sent: float = time.time()
    if args.action == "wait":
        command_id: str = args.id
    else:
        words: list[str] = args.command[1:] if args.command[:1] == ["--"] else args.command
        if not words:
            parser.error("no command")
        command: str = words[0] if len(words) == 1 else shlex.join(words)
        command_id = new_id()
        send(command, command_id)
        if args.run_async:
            print(command_id)
            return 0
        print(f"[devbox {command_id} sent]", file=sys.stderr, flush=True)
    result = wait(command_id, args.timeout, 2.0, "done", False)
    print(result.log_tail)
    times: dict[str, str] = result.times
    if args.action == "run" and times.get("started", "").isdigit() and times.get("finished", "").isdigit():
        run_seconds: int = int(times["finished"]) - int(times["started"])
        print(
            f"[devbox {command_id} exit {result.exit_code}: {run_seconds}s on the Mac,"
            f" {time.time() - sent - run_seconds:.0f}s overhead]",
            file=sys.stderr,
        )
    return result.exit_code if result.exit_code is not None else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
