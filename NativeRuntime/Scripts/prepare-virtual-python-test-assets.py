#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Generate pinned WK/Python assets for the unit-test bundle only.

No production runtime switch, app resources, auth, or learner data is used.
Existing corrupt cache/input/output files fail; never silently replace them with
an unverified download. Network inputs are fixed version and SHA-256 checked.
"""
import argparse
import urllib.error
import time
import http.client
import hashlib
import io
import json
import os
from pathlib import Path, PurePosixPath
import shutil
import tempfile
import urllib.request
import zipfile

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / 'VirtualPython'
CDN = 'https://cdn.jsdelivr.net/pyodide/v314.0.7/full/'
JS = ('main.js', 'worker.js', 'filesystem.js', 'resources.js', 'stdio.js')
NOTICES = {
    'Pyodide-MPL-2.0.txt': '1f256ecad192880510e84ad60474eab7589218784b9a50bc7ceee34c2b91f1d5',
    'Python-3.14.2.txt': 'b0e25a78cffb43f4d92de8b61ccfa1f1f98ecbc22330b54b5251e7b6ba010231',
}
PACKAGES = {'numpy': '2.4.6', 'sympy': '1.14.0', 'mpmath': '1.4.1', 'pyyaml': '6.0.3'}
MAX_ASSET_BYTES = 64 * 1024 * 1024
DOWNLOAD_ATTEMPTS = 3


def download_verified(name, expected):
    """Only fresh public downloads retry; no unverified body reaches cache."""
    for attempt in range(1, DOWNLOAD_ATTEMPTS + 1):
        status = 0; data = bytearray(); declared = -1
        deadline = time.monotonic() + 30
        try:
            request = urllib.request.Request(CDN + name, headers={'Accept-Encoding': 'identity'})
            with urllib.request.urlopen(request, timeout=30) as response:
                status = response.status
                length = response.headers.get('Content-Length')
                declared = int(length) if length is not None and length.isdecimal() else -1
                if status != 200 or response.headers.get('Content-Encoding', 'identity').lower() != 'identity':
                    raise ValueError('Unexpected download status/encoding')
                if declared > MAX_ASSET_BYTES:
                    raise ValueError('Download byte limit exceeded')
                while len(data) <= MAX_ASSET_BYTES:
                    if time.monotonic() >= deadline:
                        raise TimeoutError('Download deadline exceeded')
                    chunk = response.read1(min(65_536, MAX_ASSET_BYTES + 1 - len(data)))
                    if not chunk: break
                    data.extend(chunk)
            if len(data) > MAX_ASSET_BYTES or (declared >= 0 and len(data) != declared) or digest(data) != expected:
                raise ValueError('Downloaded pinned resource mismatch')
            return bytes(data)
        except (OSError, urllib.error.URLError, http.client.IncompleteRead, ValueError) as error:
            if isinstance(error, urllib.error.HTTPError): status = error.code
            print('Pinned download rejected: ' + name + ' attempt=' + str(attempt)
                  + ' status=' + str(status) + ' bytes=' + str(len(data))
                  + ' declared=' + str(declared) + ' sha256=' + digest(data)
                  + ' error=' + type(error).__name__)
            if attempt == DOWNLOAD_ATTEMPTS:
                raise ValueError('Pinned resource download failed after bounded attempts: ' + name) from None
            time.sleep(attempt)


def digest(data):
    return hashlib.sha256(data).hexdigest()


def read_regular(path):
    if path.is_symlink() or not path.is_file():
        raise ValueError('Regular build asset required: ' + path.name)
    if path.stat().st_size > MAX_ASSET_BYTES:
        raise ValueError('Build asset byte limit exceeded: ' + path.name)
    return path.read_bytes()


def inventory():
    text = read_regular(SOURCE / 'resources.js').decode('utf-8')
    files = json.loads(text.split('export const resources = ', 1)[1].strip().removesuffix(';'))
    if len(files) != 9:
        raise ValueError('Expected nine pinned Python runtime/package resources')
    for name, sha in files.items():
        if not isinstance(name, str) or PurePosixPath(name).name != name or not isinstance(sha, str) or len(sha) != 64 or any(c not in '0123456789abcdef' for c in sha):
            raise ValueError('Invalid pinned asset inventory')
    return files


def load_package_assets(cache, expected, offline):
    cache.mkdir(parents=True, exist_ok=True)
    result = {}
    for name, sha in expected.items():
        path = cache / name
        if path.exists() or path.is_symlink():
            data = read_regular(path)
        else:
            if offline:
                raise ValueError('Missing offline pinned asset: ' + name)
            data = download_verified(name, sha)
            if len(data) > MAX_ASSET_BYTES:
                raise ValueError('Downloaded asset byte limit exceeded: ' + name)
        if digest(data) != sha:
            raise ValueError('Pinned resource SHA-256 mismatch: ' + name)
        if not path.exists():
            temporary = path.with_suffix(path.suffix + '.download')
            temporary.write_bytes(data); os.replace(temporary, path)
        result[name] = data
    lock = json.loads(result['pyodide-lock.json'])
    if lock['info'] != {'abi_version': '2026_0', 'arch': 'wasm32', 'platform': 'emscripten_5_0_3', 'python': '3.14.2'}:
        raise ValueError('Unexpected Python/WASM ABI pin')
    pending = list(PACKAGES); closure = set()
    while pending:
        name = pending.pop()
        if name in closure: continue
        record = lock['packages'][name]; closure.add(name)
        if name not in PACKAGES or record['version'] != PACKAGES[name] or expected.get(record['file_name']) != record['sha256']:
            raise ValueError('Unpinned Python package dependency: ' + name)
        pending.extend(record['depends'])
    if closure != set(PACKAGES):
        raise ValueError('Required Python package closure mismatch')
    return result, lock


def generate(cache, destination, offline):
    expected = inventory()
    assets, lock = load_package_assets(cache, expected, offline)
    payload = {name: read_regular(SOURCE / name) for name in JS}
    payload['hyotan_runner.py'] = read_regular(ROOT / 'PythonModules' / 'hyotan_runner.py')
    payload.update({'py/' + name: data for name, data in assets.items()})
    for name, sha in NOTICES.items():
        data = read_regular(SOURCE / 'Licenses' / name)
        if digest(data) != sha: raise ValueError('Pinned license SHA-256 mismatch: ' + name)
        payload['licenses/' + name] = data
    notice_counts = {}
    for name in PACKAGES:
        wheel = lock['packages'][name]['file_name']
        with zipfile.ZipFile(io.BytesIO(assets[wheel])) as archive:
            records = []
            for entry in archive.infolist():
                path = PurePosixPath(entry.filename)
                if path.is_absolute() or '..' in path.parts: raise ValueError('Unsafe wheel entry')
                base = path.name.lower()
                if not entry.is_dir() and (any(word in base for word in ('license', 'notice', 'copying', 'authors')) or base == 'metadata'):
                    if entry.file_size > MAX_ASSET_BYTES: raise ValueError('Wheel notice byte limit exceeded')
                    target = 'licenses/' + name + '/' + entry.filename
                    payload[target] = archive.read(entry)
                    if base != 'metadata': records.append(target)
            if not records: raise ValueError('Required wheel license notice missing: ' + name)
            notice_counts[name] = len(records)
    manifest = {'format_version': 1, 'pyodide_version': '314.0.7', 'python_version': '3.14.2',
                'files': {name: {'sha256': digest(data), 'bytes': len(data)} for name, data in sorted(payload.items())},
                'packages': PACKAGES, 'package_notice_counts': notice_counts,
                'scope': 'Debug Simulator unit-test assets; no app/device deployment or binary legal guarantee'}
    if destination.is_symlink(): raise ValueError('Generated test root cannot be a symlink')
    # Detect tampering of generated Python files against the immutable source pin.
    for name, sha in expected.items():
        previous = destination / 'py' / name
        if previous.exists() or previous.is_symlink():
            if digest(read_regular(previous)) != sha: raise ValueError('Generated pinned asset SHA-256 mismatch: ' + name)
    destination.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='virtual-python-assets-', dir=destination.parent) as temporary:
        staging = Path(temporary) / 'VirtualPythonTestAssets'; staging.mkdir()
        # The tracked empty sentinel preserves this XCTest resource directory
        # in clean checkouts that do not generate the large runtime payload.
        # It is structural only, excluded from the served payload/manifest.
        (staging / '.gitkeep').write_bytes(b'')
        for name, data in payload.items():
            path = staging / name; path.parent.mkdir(parents=True, exist_ok=True); path.write_bytes(data)
        (staging / 'manifest.json').write_text(json.dumps(manifest, sort_keys=True, indent=2) + '\n')
        if destination.exists(): shutil.rmtree(destination)
        os.replace(staging, destination)
    print('PASS pinned WK test assets: Python3.14.2, Pyodide314.0.7; nine hashes; NumPy/SymPy/mpmath/PyYAML closure; primary and wheel notices')
    print('Generated test-only files=' + str(len(payload) + 2) + ' bytes=' + str(sum(len(data) for data in payload.values())) + ' (includes empty structural .gitkeep, excluded from manifest)')
    return manifest


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--cache', type=Path, default=ROOT / '.build/virtual-python-assets')
    parser.add_argument('--destination', type=Path, default=ROOT / 'VirtualPythonTestAssets')
    parser.add_argument('--offline', action='store_true')
    args = parser.parse_args()
    generate(args.cache, args.destination, args.offline)


if __name__ == '__main__': main()
