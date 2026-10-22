#!/usr/bin/env python3
"""Native runtime outputs built once on GitHub and reused by Xcode Cloud.

The outputs of NativeRuntime/Scripts/bootstrap.py --platform both (the same
four directories as the Actions cache in agent-native-cache.yml) are published
as an asset of the GitHub Release `native-runtime`, named by a key over the
tracked NativeRuntime inputs. The repository is public, so Xcode Cloud
downloads it without credentials and verifies its SHA-256 instead of
rebuilding Rust and the BSD tools on every build.

  native_prebuilt.py key                print the key for this checkout
  native_prebuilt.py apply              download, verify and unpack; exit 3 if not published
  native_prebuilt.py pack OUTPUT        archive the built outputs (publisher)
"""
import argparse
import hashlib
import http.client
import io
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tarfile
import urllib.error
import urllib.request

ROOT = Path(__file__).resolve().parents[2]
REPOSITORY = os.environ.get('STRUIS_NATIVE_REPOSITORY', 'DigiLog-lab/struis-ios')
RELEASE_TAG = 'native-runtime'
OUTPUTS = ('NativeRuntime/Vendor', 'NativeRuntime/PythonPackages', 'NativeRuntime/PackageCache', 'NativeRuntime/.build')
MARKER = 'NativeRuntime/.prebuilt.json'
# Same exclusions as the Actions cache key (hashFiles in agent-native-cache.yml / ios.yml).
EXCLUDED = (lambda path: path.startswith('NativeRuntime/Shared/')
            or (path.startswith('NativeRuntime/Worker/') and path.count('/') == 2
                and (path.endswith('.swift') or path == 'NativeRuntime/Worker/Info.plist'))
            or path.endswith('.entitlements') or path.endswith('.md'))


def tracked_inputs(root=ROOT):
    names = subprocess.check_output(['git', 'ls-files', '-z', '--', 'NativeRuntime'], cwd=root).split(b'\0')
    return sorted(name.decode() for name in names if name and not EXCLUDED(name.decode()))


def key(root=ROOT):
    digest = hashlib.sha256()
    for name in tracked_inputs(root):
        data = (root / name).read_bytes()
        digest.update(name.encode() + b'\0' + hashlib.sha256(data).hexdigest().encode() + b'\n')
    return 'v1-' + digest.hexdigest()[:40]


def asset_name(value):
    return f'native-runtime-{value}.tar.gz'


def download(url, timeout=900, attempts=4, opener=None):
    """Read the whole asset, resuming with a Range request when the connection drops.

    PR Gate 161 lost its ~500 MB download midway (IncompleteRead) and fell back
    to building native from source for six minutes. A 404 is returned at once.
    """
    opener = opener or urllib.request.urlopen
    data = bytearray()
    for attempt in range(attempts):
        headers = {'User-Agent': 'struis-native-prebuilt'}
        if data:
            headers['Range'] = f'bytes={len(data)}-'
        try:
            with opener(urllib.request.Request(url, headers=headers), timeout=timeout) as response:
                if data and response.status != 206:
                    data.clear()  # the server ignored the range: start over
                total = expected_total(response, len(data))
                while chunk := response.read(1 << 20):
                    data.extend(chunk)
            if total is not None and len(data) < total:
                raise http.client.IncompleteRead(bytes(), total - len(data))
            return bytes(data)
        except urllib.error.HTTPError:
            raise
        except (OSError, http.client.HTTPException) as error:
            if attempt == attempts - 1:
                raise
            print(f'STRUIS_NATIVE_PREBUILT retry={attempt + 1} received_bytes={len(data)} error={type(error).__name__}', flush=True)
    raise RuntimeError('unreachable')


def expected_total(response, offset):
    """The full size of the asset from Content-Range (206) or Content-Length (200), if given."""
    headers = response.headers
    if response.status == 206 and '/' in (headers.get('Content-Range') or ''):
        total = headers['Content-Range'].rsplit('/', 1)[1]
        return int(total) if total.isdigit() else None
    length = headers.get('Content-Length')
    return offset + int(length) if length and length.isdigit() else None


def apply(root=ROOT, fetch=download):
    value = key(root)
    base = f'https://github.com/{REPOSITORY}/releases/download/{RELEASE_TAG}/{asset_name(value)}'
    try:
        expected = fetch(base + '.sha256', timeout=60).decode().split()[0]
    except urllib.error.HTTPError as error:
        if error.code == 404:
            print(f'STRUIS_NATIVE_PREBUILT key={value} status=not-published', flush=True)
            return 3
        raise
    data = fetch(base)
    actual = hashlib.sha256(data).hexdigest()
    if actual != expected:
        raise SystemExit(f'Native prebuilt SHA-256 mismatch: expected {expected}, got {actual}')
    staging = root / 'NativeRuntime' / '.prebuilt-staging'
    shutil.rmtree(staging, ignore_errors=True)
    skipped = []

    def safe(member, path):
        # Build-tool leftovers such as dash-source/missing point at the build
        # host's automake (/usr/local/share/...). They are not build outputs
        # the app uses, and an absolute link must not be created here.
        if member.issym() and member.linkname.startswith('/'):
            skipped.append(member.name)
            return None
        return tarfile.data_filter(member, path)

    try:
        with tarfile.open(fileobj=io.BytesIO(data), mode='r:gz') as archive:
            for member in archive.getmembers():
                if not any(member.name == output or member.name.startswith(output + '/') for output in OUTPUTS):
                    raise SystemExit(f'Unexpected entry in the native prebuilt: {member.name}')
            archive.extractall(staging, filter=safe)
        # Replace the outputs only after the whole archive unpacked, so a
        # failure leaves no partial tree for the fallback build to trust.
        for output in OUTPUTS:
            source, destination = staging / output, root / output
            if source.exists():
                shutil.rmtree(destination, ignore_errors=True)
                destination.parent.mkdir(parents=True, exist_ok=True)
                source.rename(destination)
    finally:
        shutil.rmtree(staging, ignore_errors=True)
    (root / MARKER).write_text(f'{{"key": "{value}", "sha256": "{actual}"}}\n')
    print(f'STRUIS_NATIVE_PREBUILT key={value} status=applied bytes={len(data)} sha256={actual} '
          f'skipped_absolute_links={",".join(skipped) or "-"}', flush=True)
    return 0


def pack(output, root=ROOT):
    missing = [name for name in OUTPUTS if not (root / name).exists()]
    if missing:
        raise SystemExit(f'Native outputs are missing: {", ".join(missing)}')
    with tarfile.open(output, 'w:gz', compresslevel=6) as archive:
        for name in OUTPUTS:
            archive.add(root / name, arcname=name)
    data = Path(output).read_bytes()
    Path(str(output) + '.sha256').write_text(hashlib.sha256(data).hexdigest() + f'  {Path(output).name}\n')
    print(f'packed {output} ({len(data)} bytes)')


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    commands = parser.add_subparsers(dest='command', required=True)
    commands.add_parser('key')
    commands.add_parser('apply')
    packer = commands.add_parser('pack')
    packer.add_argument('output', type=Path)
    args = parser.parse_args(argv)
    if args.command == 'key':
        print(key())
    elif args.command == 'apply':
        return apply()
    else:
        pack(args.output)
    return 0


if __name__ == '__main__':
    sys.exit(main())
