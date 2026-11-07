#!/usr/bin/env python3
"""Whether the target `strius`'s "Package Python" build phase can be skipped (Issue #93).

The phase copies the Python standard library and packages into the app, turns their extension modules into
signed frameworks, prepares the Dash images and compiles every .py: 94 s on the runner, on every build,
because Xcode cannot know its inputs and outputs (`alwaysOutOfDate`). This records, after the phase ran,
what it read and what it left in the app; the next build skips the phase while both are the same, and
otherwise says in the build log the first thing that changed.

    package_python_stamp.py check STAMP SCRIPT   # exit 0: unchanged, skip the phase
    package_python_stamp.py write STAMP SCRIPT   # after the phase ran

Files are compared by path, size, modification time and mode (a symbolic link by its target), not by
content: an input that changes always gets a new modification time, and reading 400 MB on every build would
cost what skipping saves. Anything else (another build phase rewriting the app's Frameworks, a cleaned
DerivedData, a new signing identity) makes the stamps differ and the phase runs.
Reads Xcode's build settings from the environment (SRCROOT, CODESIGNING_FOLDER_PATH, PLATFORM_NAME, ...).
"""
from __future__ import annotations

import hashlib
import os
import pathlib
import subprocess
import sys

# What the phase reads, relative to SRCROOT. NativeRuntime/PythonPackages/<platform> is added at run time.
INPUTS: tuple[str, ...] = (
    "NativeRuntime/Vendor",
    "NativeRuntime/Scripts",
    "scripts/package_compound_dash_preparation.py",
    "scripts/package_python_stamp.py",
)
# What it writes (or what it changes after another phase copied it), relative to the app.
OUTPUTS: tuple[str, ...] = ("Frameworks", "python", "PythonModules", "PythonPackages")
SETTINGS: tuple[str, ...] = (
    "PLATFORM_NAME", "EFFECTIVE_PLATFORM_NAME", "CONFIGURATION", "ARCHS", "EXPANDED_CODE_SIGN_IDENTITY",
    "EXPANDED_CODE_SIGN_IDENTITY_NAME", "CODESIGNING_FOLDER_PATH", "PROJECT_DIR",
)


def tree(lines: list[str], root: pathlib.Path, label: str) -> None:
    """Every entry under root (or root itself, a file), in a fixed order."""
    if not root.exists() and not root.is_symlink():
        lines.append(f"{label} missing")
        return
    paths: list[pathlib.Path] = [root]
    if root.is_dir() and not root.is_symlink():
        for directory, names, files in os.walk(root):
            names.sort()
            base = pathlib.Path(directory)
            paths += [base / name for name in names] + [base / name for name in sorted(files)]
    for path in paths:
        info = path.lstat()
        relative = path.relative_to(root).as_posix()
        target = os.readlink(path) if path.is_symlink() else ""
        lines.append(f"{label}/{relative} mode={info.st_mode:o} size={info.st_size} mtime={info.st_mtime_ns} link={target}")


def python_compiler() -> str:
    """The python3.14 the phase compiles with, by the same lookup, and its version."""
    for directory in os.environ.get("PATH", "").split(os.pathsep):
        candidate = pathlib.Path(directory) / "python3.14"
        if candidate.is_file() and os.access(candidate, os.X_OK):
            break
    else:
        return "brew"
    version = subprocess.run([str(candidate), "-c", "import sys; print(sys.version)"],
                             capture_output=True, text=True, check=False).stdout
    return f"{candidate} {version.strip()}"


def stamp(script: pathlib.Path) -> list[str]:
    env = os.environ
    source = pathlib.Path(env["SRCROOT"])
    app = pathlib.Path(env["CODESIGNING_FOLDER_PATH"])
    lines: list[str] = [f"script sha256={hashlib.sha256(script.read_bytes()).hexdigest()}"]
    lines += [f"{name}={env.get(name, '')}" for name in SETTINGS]
    lines.append(f"python3.14={python_compiler()}")
    for relative in (*INPUTS, f"NativeRuntime/PythonPackages/{env.get('PLATFORM_NAME', '')}"):
        tree(lines, source / relative, "src:" + relative)
    for relative in OUTPUTS:
        tree(lines, app / relative, "app:" + relative)
    return lines


def main(argv: list[str]) -> int:
    if len(argv) != 3 or argv[0] not in ("check", "write"):
        print(__doc__, file=sys.stderr)
        return 2
    path, script = pathlib.Path(argv[1]), pathlib.Path(argv[2])
    current = stamp(script)
    if argv[0] == "write":
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text("\n".join(current) + "\n")
        return 0
    try:
        recorded = path.read_text().splitlines()
    except FileNotFoundError:
        print("Package Python runs: no record of an earlier run")
        return 1
    if recorded == current:
        return 0
    for before, now in zip(recorded + ["(nothing)"] * len(current), current + ["(nothing)"] * len(recorded)):
        if before != now:
            print(f"Package Python runs: changed\n  was: {before}\n  now: {now}")
            break
    return 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
