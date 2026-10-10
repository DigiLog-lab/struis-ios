#!/usr/bin/env python3
"""Offline validation of the tiny stdio overlay; shared V4 core is unchanged."""
import hashlib
import json
from pathlib import Path

root = Path(__file__).resolve().parents[1] / 'ThreadedPythonCommandTestOverlay'
def require(value):
    if not value: raise ValueError('fixed threaded command overlay invariant')
def read(name, maximum):
    path = root / name
    require(not path.is_symlink() and path.is_file() and 0 < path.stat().st_size <= maximum)
    return path.read_bytes()
def digest(data): return hashlib.sha256(data).hexdigest()
data = read('overlay-manifest.json', 8192)
require(digest(data) == 'a201704550aecb439fb9d5fee36fb7b2e2ebc82dc47b1237e4de94cc08a362ae')
manifest = json.loads(data)
require(manifest['base_runtime_manifest_sha256'] == '560ff976255773573e69ec9eac6832fd993ada286e963307639e0710536d8ce2')
require(manifest['runtime_profile'] == 'sync-proxy-no-jspi' and manifest['runtime_closure_changes'] == [])
require(set(manifest['overlay_files']) == {'main.js', 'worker.js', 'stdio.js', 'hyotan_runner.py'})
total = 0
for name, record in manifest['overlay_files'].items():
    require(type(record['bytes']) is int and 0 < record['bytes'] <= 16384)
    data = read(name, record['bytes']); total += len(data)
    require(len(data) == record['bytes'] and digest(data) == record['sha256'] and total <= 32768)
print('PASS exact threaded command overlay: four fixed entries,', total, 'bytes; shared frozen V4 runtime')
