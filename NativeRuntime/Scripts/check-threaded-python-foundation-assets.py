#!/usr/bin/env python3
"""Validate the exact separately pinned test-only pthread CLI bundle, offline."""
import hashlib
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]

def validate(root, policy):
    def require(value):
        if not value: raise ValueError("fixed asset invariant")
    def read(name, maximum):
        parts = name.split('/')
        if len(name.encode()) > 512 or any(p in ('', '.', '..') for p in parts) or any(c in name for c in ('\\', '%', '\0')):
            raise ValueError('invalid fixed asset name')
        path = root
        for part in parts:
            path = path / part
            if path.is_symlink(): raise ValueError('symlink asset')
        if not path.is_file() or not 0 < path.stat().st_size <= maximum: raise ValueError('asset budget/type')
        return path.read_bytes()
    def digest(data): return hashlib.sha256(data).hexdigest()
    data = read('manifest.json', 1048576)
    if policy['manifest_sha256'] != '560ff976255773573e69ec9eac6832fd993ada286e963307639e0710536d8ce2' or digest(data) != policy['manifest_sha256']: raise ValueError('manifest pin')
    manifest = json.loads(data)
    require(manifest['format_version'] == 2 and manifest['runtime_family'] == 'vanilla-cpython-pthread-cli')
    require(manifest['python_version'] == '3.14.2' and manifest['custom_abi'] == 'pyemscripten_2026_99_wasm32')
    require(manifest['runtime_profile'] == 'sync-proxy-no-jspi' and manifest['requires_jspi'] is False and manifest['optional_cpython_jspi_io'] is False)
    require(manifest['emscripten_asyncify'] == 0 and manifest['trusted_native_preload'] is True and manifest['pthread_cleanup'] is True)
    require(manifest['test_only'] is True and manifest['production_enabled'] is False)
    require(manifest['logical_memory'] == {'initial_bytes':20971520,'maximum_pages':65536,'physical_4GiB_verified':False,'shared':True})
    require(set(manifest['files']) == set(policy['files']) and len(policy['files']) == len(set(policy['files'])))
    loaded = {}; total = 0
    for name, record in manifest['files'].items():
        require(type(record['bytes']) is int and 0 < record['bytes'] <= 67108864)
        data = read(name, record['bytes']); total += len(data)
        require(total <= 268435456 and len(data) == record['bytes'] and digest(data) == record['sha256'])
        loaded[name] = data
    inventory = json.loads(loaded['inventory.json'])
    require(inventory['custom_abi'] == manifest['custom_abi'])
    for group in ('files','native'):
        for item in inventory[group]:
            require(item['url'].startswith('./') and digest(loaded[item['url'][2:]]) == item['sha256'])
    closure = loaded['provenance/vanilla/closure-inspection/runtime-closure-audit.json']
    require(digest(closure) == manifest['closure_audit_sha256'])
    audit = json.loads(closure)
    require(audit['core_sha256'] == digest(loaded['python.wasm']))
    require(audit['core_binary_identical_to_trace_relink'] is True)
    require(audit['source_linked_GPL_exclusion'].startswith('PASS '))
    require(len(audit['actual_linked_archives']) == 17)
    profile = json.loads(loaded['provenance/vanilla/no-jspi/profile.json'])
    require(profile['profile'] == 'sync-proxy-no-jspi' and profile['actual_compile_flag'] == '-DHYOTAN_ENABLE_OPTIONAL_JSPI_IO=0')
    require(digest(loaded['provenance/vanilla/no-jspi/emscripten_syscalls_sync_profile.c']) == profile['source_patched_sha256'])
    print(f'PASS exact threaded foundation assets: {len(loaded)} files, {total} bytes; test-only; Apple unverified')
    return loaded

if __name__ == '__main__':
    validate(ROOT / 'ThreadedPythonFoundationTestAssets', json.loads((ROOT / 'threaded-foundation-policy.json').read_text()))
