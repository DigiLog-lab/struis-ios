#!/usr/bin/env python3
"""The web Claude's side of the Dev Box: `mac <command>` runs <command> on the macOS runner.

A command is a commit on `devbox/cmd` (files `id` and `cmd.sh`); the Dev Box (scripts/devbox/serve.sh)
answers with one force-pushed commit on `devbox/out`. Both are watched with `git ls-remote`.

    mac.py run -- xcodebuild test-without-building ...   # waits, prints the log tail, exits with its code
    mac.py run --async -- xcrun simctl io booted recordVideo rec.mp4
    mac.py wait <id>                                     # the result of an --async command
    mac.py ready                                         # waits until a Dev Box has said it is ready
    mac.py kill                                          # ends the running command
    mac.py stop                                          # ends the running command and the Dev Box
Files the command writes to "$DEVBOX_FILES" are copied to ./devbox-out/<id>/.
"""
from __future__ import annotations

import argparse
import dataclasses
import pathlib
import shlex
import subprocess
import sys
import time
import uuid

CMD_REF: str = "refs/heads/devbox/cmd"
OUT_REF: str = "refs/heads/devbox/out"


@dataclasses.dataclass(frozen=True)
class Result:
    id: str
    state: str
    exit_code: int | None
    times: dict[str, int]
    log_tail: str


def git(*args: str, cwd: pathlib.Path | None = None, input_text: str | None = None) -> str:
    completed: subprocess.CompletedProcess[str] = subprocess.run(
        ["git", *args], cwd=cwd, input=input_text, text=True, capture_output=True, check=True
    )
    return completed.stdout.strip()


def remote_sha(ref: str) -> str:
    line: str = git("ls-remote", "origin", ref)
    return line.split("\t", 1)[0] if line else ""


def send(command: str) -> str:
    """Pushes one command; returns its id."""
    command_id: str = uuid.uuid4().hex[:12]
    blob_id: str = git("hash-object", "-w", "--stdin", input_text=command_id + "\n")
    blob_cmd: str = git("hash-object", "-w", "--stdin", input_text=command + "\n")
    tree: str = git("mktree", input_text=f"100644 blob {blob_cmd}\tcmd.sh\n100644 blob {blob_id}\tid\n")
    commit: str = git("commit-tree", tree, "-m", f"devbox command {command_id}")
    git("push", "-q", "--force", "origin", f"{commit}:{CMD_REF}")
    return command_id


def read_out(sha: str, destination: pathlib.Path | None) -> Result:
    git("fetch", "-q", "--depth", "1", "origin", sha)

    def show(name: str) -> str:
        try:
            return git("show", f"{sha}:{name}")
        except subprocess.CalledProcessError:
            return ""

    times: dict[str, int] = {}
    for line in show("times").splitlines():
        key, _, value = line.partition("=")
        if value.isdigit():
            times[key] = int(value)
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


def wait(command_id: str | None, timeout: float, poll: float, quiet: bool) -> Result:
    """Waits for the result of command_id (or for any `ready` when None)."""
    deadline: float = time.monotonic() + timeout
    seen: str = ""
    printed: str = ""
    while time.monotonic() < deadline:
        sha: str = remote_sha(OUT_REF)
        if sha and sha != seen:
            seen = sha
            wanted_done: bool = command_id is not None
            destination: pathlib.Path | None = (
                pathlib.Path("devbox-out") / command_id if command_id else None
            )
            result: Result = read_out(sha, None)
            if command_id is None and result.state == "ready":
                return result
            if wanted_done and result.id == command_id:
                if result.state == "done":
                    return read_out(sha, destination)
                if not quiet and result.log_tail and result.log_tail != printed:
                    last_line: str = result.log_tail.splitlines()[-1]
                    print(f"[devbox {command_id} running] {last_line}", file=sys.stderr, flush=True)
                    printed = result.log_tail
        time.sleep(poll)
    raise TimeoutError(
        f"no result for {command_id or 'ready'} within {timeout:.0f}s"
        + (f" (still running? `mac.py wait {command_id}`, or `mac.py kill`)" if command_id else "")
    )


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(prog="mac")
    sub = parser.add_subparsers(dest="action", required=True)
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

    if args.action == "ready":
        result: Result = wait(None, args.timeout, 3.0, True)
        print(f"ready: {result.id} {result.times}")
        return 0
    if args.action in ("stop", "kill"):
        print(send(f"__devbox_{args.action}__"))
        return 0
    if args.action == "wait":
        command_id: str = args.id
    else:
        words: list[str] = args.command[1:] if args.command[:1] == ["--"] else args.command
        if not words:
            parser.error("no command")
        command: str = words[0] if len(words) == 1 else shlex.join(words)
        sent: float = time.time()
        command_id = send(command)
        if args.run_async:
            print(command_id)
            return 0
        print(f"[devbox {command_id} sent]", file=sys.stderr, flush=True)
    result = wait(command_id, args.timeout, 2.0, False)
    print(result.log_tail)
    times: dict[str, int] = result.times
    if args.action == "run" and "started" in times and "finished" in times:
        total: float = time.time() - sent
        run_seconds: int = times["finished"] - times["started"]
        print(
            f"[devbox {command_id} exit {result.exit_code}: {run_seconds}s on the Mac,"
            f" {total - run_seconds:.0f}s overhead]",
            file=sys.stderr,
        )
    return result.exit_code if result.exit_code is not None else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
