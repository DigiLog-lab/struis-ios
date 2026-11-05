#!/usr/bin/env python3
"""Materialize opt-in test inputs into ignored folders; never fetch private data."""
import os
from pathlib import Path
import shutil
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
def external_source(value, destination):
    if not value:
        return None
    source = Path(value).resolve()
    target = destination.resolve()
    if source == target or source.is_relative_to(target) or target.is_relative_to(source):
        raise SystemExit("External test input must be outside its generated destination")
    if not source.is_dir():
        raise SystemExit("External test input directory does not exist")
    if destination.is_symlink():
        raise SystemExit("Generated test destination must not be a symlink")
    return source

threaded = os.environ.get("STRUIS_THREADED_PYTHON_ASSETS_DIR")
destination = ROOT / "NativeRuntime/ThreadedPythonFoundationTestAssets"
source_dir = external_source(threaded, destination)
if destination.is_symlink():
    raise SystemExit("Generated test destination must not be a symlink")
if destination.exists():
    shutil.rmtree(destination)
if threaded:
    shutil.copytree(source_dir, destination, symlinks=False)
    subprocess.run([sys.executable, str(ROOT / "NativeRuntime/Scripts/check-threaded-python-foundation-assets.py")], check=True)
else:
    print("SKIP threaded foundation: STRUIS_THREADED_PYTHON_ASSETS_DIR is unset")
