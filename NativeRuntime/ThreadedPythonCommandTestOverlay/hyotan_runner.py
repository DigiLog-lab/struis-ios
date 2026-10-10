"""Entry points for the embedded interpreter; no child process or host Python."""
import code
import os
import runpy
import sys
import traceback
import math
import operator
import time


_native_sleep = time.sleep
_monotonic = time.monotonic


def _interruptible_sleep(seconds):
    # Embedded Python has no process-level SIGINT handler. Returning to Python
    # between bounded waits lets the pending KeyboardInterrupt take effect.
    seconds = seconds if isinstance(seconds, float) else operator.index(seconds)
    if seconds <= 0 or not math.isfinite(seconds):
        return _native_sleep(seconds)
    deadline = _monotonic() + seconds
    while True:
        remaining = deadline - _monotonic()
        if remaining <= 0:
            return
        _native_sleep(min(remaining, 0.05))


def python_main(args):
    previous = sys.argv
    previous_sleep = time.sleep
    time.sleep = _interruptible_sleep
    try:
        if args and args[0] in ("--version", "-V"):
            print("Python " + sys.version.split()[0])
        elif args and args[0] == "-c":
            if len(args) < 2:
                print("python3: -c requires an argument", file=sys.stderr)
                return 2
            sys.argv = ["-c", *args[2:]]
            exec(compile(args[1], "<string>", "exec"), {"__name__": "__main__"})
        elif args and args[0] == "-m":
            if len(args) < 2:
                return 2
            sys.argv = args[1:]
            runpy.run_module(args[1], run_name="__main__", alter_sys=True)
        elif args:
            sys.argv = args
            if args[0] == "-":
                exec(compile(sys.stdin.read(), "<stdin>", "exec"), {"__name__": "__main__"})
            else:
                runpy.run_path(args[0], run_name="__main__")
        else:
            code.interact(banner="Python " + sys.version, local={"__name__": "__main__"}, exitmsg="")
        return 0
    except SystemExit as error:
        if error.code is None:
            return 0
        if isinstance(error.code, int):
            return error.code
        print(error.code, file=sys.stderr)
        return 1
    except KeyboardInterrupt:
        print("KeyboardInterrupt", file=sys.stderr)
        return 130
    except BaseException:
        traceback.print_exc()
        return 1
    finally:
        sys.argv = previous
        time.sleep = previous_sleep


def git_main(args):
    from hyotan_git import main
    try:
        return main(args)
    except SystemExit as error:
        return error.code or 0
    except KeyboardInterrupt:
        print("KeyboardInterrupt", file=sys.stderr)
        return 130
    except Exception as error:
        print(f"git: {error}", file=sys.stderr)
        return 1
