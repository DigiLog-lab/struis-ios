#!/usr/bin/env python3
"""Fetch hash-pinned iOS packages and assemble one SDK's embedded Python path."""
import argparse
import hashlib
import html.parser
import json
from pathlib import Path, PurePosixPath
import shutil
import tarfile
import tempfile
import urllib.parse
import zipfile

from fetch import fetch

ROOT = Path(__file__).resolve().parents[1]


class Links(html.parser.HTMLParser):
    def __init__(self):
        super().__init__()
        self.links = []

    def handle_starttag(self, tag, attrs):
        if tag == "a":
            self.links.extend(value for key, value in attrs if key == "href")


def download_url(package):
    if package["source"] == "pypi":
        releases = json.loads(fetch(f'https://pypi.org/pypi/{package["name"]}/{package["version"]}/json'))["urls"]
        return next(item["url"] for item in releases if item["filename"] == package["filename"])
    index = "https://pypi.anaconda.org/beeware/simple/numpy/"
    parser = Links()
    parser.feed(fetch(index).decode())
    return next(urllib.parse.urljoin(index, link) for link in parser.links
                if urllib.parse.unquote(urllib.parse.urlsplit(link).path).endswith("/" + package["filename"]))


def destination(root, name):
    relative = PurePosixPath(name)
    if relative.is_absolute() or ".." in relative.parts:
        raise ValueError(f"Unsafe archive member: {name}")
    return root.joinpath(*relative.parts)


def unpack(archive, root):
    if archive.suffix == ".whl":
        with zipfile.ZipFile(archive) as package:
            for entry in package.infolist():
                if entry.is_dir():
                    continue
                if (entry.external_attr >> 16) & 0o170000 == 0o120000:
                    raise ValueError(f"Symlink in wheel: {entry.filename}")
                target = destination(root, entry.filename)
                target.parent.mkdir(parents=True, exist_ok=True)
                target.write_bytes(package.read(entry))
    else:
        # PyYAML's pure Python loader is sufficient; do not compile its optional C extension.
        with tarfile.open(archive) as package:
            for entry in package.getmembers():
                parts = PurePosixPath(entry.name).parts[1:]
                if not entry.isfile():
                    continue
                if parts[:2] == ("lib", "yaml"):
                    target = destination(root, str(PurePosixPath(*parts[1:])))
                elif parts == ("LICENSE",):
                    target = root / "PyYAML-LICENSE"
                else:
                    continue
                target.parent.mkdir(parents=True, exist_ok=True)
                target.write_bytes(package.extractfile(entry).read())


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--platform", choices=["iphoneos", "iphonesimulator"], required=True)
    parser.add_argument("--cache", type=Path, default=ROOT / "PackageCache")
    args = parser.parse_args()
    args.cache.mkdir(parents=True, exist_ok=True)
    packages = json.loads((ROOT / "python-packages.lock.json").read_text())
    output = ROOT / "PythonPackages" / args.platform
    output.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(dir=output.parent) as temporary:
        staged = Path(temporary) / "packages"
        staged.mkdir()
        for package in packages:
            if package["platform"] not in ("all", args.platform):
                continue
            archive = args.cache / package["filename"]
            if not archive.exists():
                data = fetch(download_url(package))
                if hashlib.sha256(data).hexdigest() != package["sha256"]:
                    raise ValueError(f'Hash mismatch: {package["filename"]}')
                archive.write_bytes(data)
            if hashlib.sha256(archive.read_bytes()).hexdigest() != package["sha256"]:
                raise ValueError(f'Hash mismatch: {archive.name}')
            unpack(archive, staged)
            print(f'Verified {archive.name}')
        if output.exists():
            shutil.rmtree(output)
        staged.rename(output)
    print(f'Prepared {args.platform}: {output}')


if __name__ == "__main__":
    main()
