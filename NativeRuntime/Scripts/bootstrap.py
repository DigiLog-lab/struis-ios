#!/usr/bin/env python3
"""Build Struis's native runtime from pinned sources on an Xcode host."""
import argparse
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import sys
import tarfile

from fetch import fetch

ROOT = Path(__file__).resolve().parents[1]
# Former embedded-agent outputs. A restored cache can still contain them; delete
# them so no project setting or search path can link them by accident.
RETIRED = ["Vendor/NativeCodex.xcframework", "Vendor/NativeCodexHost.xcframework", "Vendor/codex-source",
           ".build/codex", ".build/codex-artifacts", ".build/codex-metadata.json",
           ".build/NativeCodex-metadata.json", ".build/native-codex-host-exports.txt"]


def remove_retired():
    for relative in RETIRED:
        path = ROOT / relative
        if path.is_symlink() or path.is_file():
            path.unlink()
        elif path.is_dir():
            shutil.rmtree(path)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--platform", choices=["both", "device", "simulator"], default="both")
    args = parser.parse_args()
    vendor = ROOT / "Vendor"
    vendor.mkdir(exist_ok=True)
    remove_retired()
    for dependency in json.loads((ROOT / "dependencies.lock.json").read_text()):
        destination = vendor / (dependency["name"] + ".xcframework")
        if destination.is_symlink():
            raise SystemExit(f"External framework symlink is not a reproducible build input: {destination}")
        if not destination.exists():
            archive = vendor / dependency["url"].rsplit("/", 1)[-1]
            archive.write_bytes(fetch(dependency["url"]))
            if hashlib.sha256(archive.read_bytes()).hexdigest() != dependency["sha256"]:
                raise SystemExit("Python support archive hash mismatch")
            with tarfile.open(archive) as package:
                package.extractall(vendor, filter="data")
            archive.unlink()
    # The BSD tools and dash build both SDKs. The Rust libraries can target a single SDK in CI.
    for script in ("build-bsd.py", "build-dash.py"):
        subprocess.run([sys.executable, str(ROOT / "Scripts" / script)], check=True)
    subprocess.run([sys.executable, str(ROOT / "Scripts/build-native.py"), "--platform", args.platform], check=True)
    for platform in (["iphoneos", "iphonesimulator"] if args.platform == "both" else
                     ["iphoneos" if args.platform == "device" else "iphonesimulator"]):
        subprocess.run([sys.executable, str(ROOT / "Scripts/prepare-python.py"), "--platform", platform], check=True)


if __name__ == "__main__":
    main()
