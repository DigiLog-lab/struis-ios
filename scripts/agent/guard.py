"""Process control for the local verification, and the pre-push hook of the agent's checkout."""
import json
import os
import re
import signal
from pathlib import Path
import subprocess
import sys
import time

from agentlib import agent_home

FAILED_TEST = re.compile(r"^Test Case .* failed \(|^[✘×] Test .* failed", re.MULTILINE)


def run_check(command, stream, timeout, environment):
    """Stop on a known failing test and reap the entire owned process group."""
    process = subprocess.Popen(command, stdout=stream, stderr=subprocess.STDOUT,
                               env=environment, start_new_session=True)
    from progress import process_name
    registration = agent_home() / f'validation-process-{process.pid}.json'
    registration.write_text(json.dumps({'pid': process.pid, 'name': process_name(process.pid), 'group': True}))
    deadline = time.monotonic() + timeout
    old_handlers = {}
    def interrupted(signum, _frame):
        raise InterruptedError(f'検証処理が中断されました (signal {signum})')
    try:
        for signum in (signal.SIGTERM, signal.SIGINT):
            old_handlers[signum] = signal.signal(signum, interrupted)
        with Path(stream.name).open(errors='replace') as reader:
            pending = ''
            while process.poll() is None:
                pending = (pending + reader.read())[-65536:]
                if FAILED_TEST.search(pending):
                    return subprocess.CompletedProcess(command, 1)
                if time.monotonic() >= deadline:
                    raise subprocess.TimeoutExpired(command, timeout)
                time.sleep(0.2)
        return subprocess.CompletedProcess(command, process.returncode)
    finally:
        # SIGINT lets xcodebuild finish its result bundle before forced cleanup.
        if process.poll() is None:
            try:
                os.killpg(process.pid, signal.SIGINT)
                process.wait(timeout=15)
            except (ProcessLookupError, subprocess.TimeoutExpired):
                pass
        try:
            os.killpg(process.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        process.wait()
        registration.unlink(missing_ok=True)
        for signum, handler in old_handlers.items():
            signal.signal(signum, handler)


def git(*args):
    return subprocess.run(['git', *args], capture_output=True, text=True, check=True).stdout.strip()


def push_gate():
    """Only the current, committed HEAD may be pushed, and never to main."""
    if git('status', '--porcelain'):
        raise RuntimeError('未コミットの変更があります。pushを止めました。')
    updates = [line.split() for line in sys.stdin if line.strip()]
    head = git('rev-parse', 'HEAD')
    if any(len(parts) != 4 or parts[1] != head or parts[2] == 'refs/heads/main'
           or not parts[2].startswith('refs/heads/') for parts in updates):
        raise RuntimeError('現在のHEAD以外やmainへのpushは許可しません。')


if __name__ == '__main__':
    try:
        if sys.argv[1:] != ['push']:
            sys.exit('usage: guard.py push')
        push_gate()
    except (RuntimeError, OSError, subprocess.SubprocessError) as error:
        print(f'push: {error}', file=sys.stderr)
        sys.exit(1)
