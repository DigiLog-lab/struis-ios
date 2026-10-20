"""Prepare hash-pinned large downloads before the native build on CI hosts."""
import argparse
import hashlib
import importlib.util
import io
import json
from pathlib import Path
import sys
import tarfile
import tempfile

from native_fetch import fetch

ROOT = Path(__file__).resolve().parents[2] / "NativeRuntime"


def verified_download(url, expected, download):
    data = download(url)
    if hashlib.sha256(data).hexdigest() != expected:
        raise ValueError(f"Hash mismatch: {url}")
    return data


def prefetch(root, platform, resolve, download=fetch):
    vendor = root / "Vendor"
    vendor.mkdir(exist_ok=True)
    for dependency in json.loads((root / "dependencies.lock.json").read_text()):
        destination = vendor / (dependency["name"] + ".xcframework")
        if destination.is_symlink():
            raise ValueError(f"External framework symlink: {destination}")
        if not destination.exists():
            data = verified_download(dependency["url"], dependency["sha256"], download)
            with tarfile.open(fileobj=io.BytesIO(data)) as archive:
                archive.extractall(vendor, filter="data")
    platforms = {"device": {"iphoneos"}, "simulator": {"iphonesimulator"},
                 "both": {"iphoneos", "iphonesimulator"}}[platform]
    cache = root / "PackageCache"
    cache.mkdir(exist_ok=True)
    for package in json.loads((root / "python-packages.lock.json").read_text()):
        if package["platform"] != "all" and package["platform"] not in platforms:
            continue
        filename = package["filename"]
        if Path(filename).name != filename:
            raise ValueError(f"Invalid package filename: {filename}")
        path = cache / filename
        if path.exists():
            if hashlib.sha256(path.read_bytes()).hexdigest() != package["sha256"]:
                raise ValueError(f"Hash mismatch: {filename}")
        else:
            data = verified_download(resolve(package), package["sha256"], download)
            # Never leave a truncated wheel for the native packager to consume.
            with tempfile.TemporaryDirectory(dir=cache) as directory:
                staged = Path(directory) / filename
                staged.write_bytes(data)
                staged.replace(path)
        print(f"STRUIS_NATIVE_INPUT verified={filename}")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--platform", choices=["both", "device", "simulator"], required=True)
    args = parser.parse_args()
    # Reuse the native package resolver and its pinned filenames. Only the CI
    # network transport differs; the native build inputs/cache identity do not.
    sys.path.insert(0, str(ROOT / "Scripts"))
    spec = importlib.util.spec_from_file_location("native_python_inputs", ROOT / "Scripts/prepare-python.py")
    resolver = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(resolver)
    resolver.fetch = fetch
    prefetch(ROOT, args.platform, resolver.download_url)


if __name__ == "__main__":
    main()
