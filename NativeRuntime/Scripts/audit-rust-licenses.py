#!/usr/bin/env python3
"""Fail closed on unreviewed runtime license expressions; preserve upstream notices."""
import argparse
import hashlib
import json
import pathlib
import re

ROOT = pathlib.Path(__file__).resolve().parents[1]
PERMISSIVE = ['MIT', 'Apache-2.0', 'BSD-3-Clause', 'BSD-2-Clause', 'ISC', 'Zlib', 'Unicode-3.0', 'CDLA-Permissive-2.0', 'CC0-1.0', '0BSD', 'MIT-0', 'BSL-1.0', 'Unlicense']

def select(expression):
    tokens = re.findall(r'\(|\)|AND|OR|WITH|[^\s()]+', expression.replace('/', ' OR '))
    position = 0
    def atom():
        nonlocal position
        value = tokens[position]; position += 1
        if value == '(':
            value = alternatives()
            if tokens[position] != ')': raise ValueError(expression)
            position += 1
        if position < len(tokens) and tokens[position] == 'WITH':
            position += 2
            # Prefer another branch; exceptions are not used for this product.
            return None
        return value if value is None or all(v in PERMISSIVE for v in value.split(' AND ')) else None
    def conjunction():
        nonlocal position
        value = atom()
        while position < len(tokens) and tokens[position] == 'AND':
            position += 1
            other = atom()
            value = value + ' AND ' + other if value and other else None
        return value
    def alternatives():
        nonlocal position
        choices = [conjunction()]
        while position < len(tokens) and tokens[position] == 'OR':
            position += 1; choices.append(conjunction())
        valid = [v for v in choices if v]
        return min(valid, key=lambda v: sum(PERMISSIVE.index(p) for p in v.split(' AND '))) if valid else None
    result = alternatives()
    if position != len(tokens) or not result: raise ValueError(f'No reviewed permissive choice: {expression}')
    return ' AND '.join(dict.fromkeys(result.split(' AND ')))

def notices(directory):
    found = []
    for path in sorted(directory.rglob('*')):
        if path.is_file() and not path.is_symlink() and re.match(r'^(license|copying|notice)([._-]|$)', path.name, re.I):
            found.append(path)
    if not found:
        for parent in list(directory.parents)[:4]:
            found = [p for p in parent.iterdir() if p.is_file() and re.match(r'^(license|copying|notice)([._-]|$)', p.name, re.I)]
            if found: break
    return found

def main():
    parser = argparse.ArgumentParser(); parser.add_argument('metadata', type=pathlib.Path)
    args = parser.parse_args()
    metadata = json.loads(args.metadata.read_text())
    packages = {p['id']: p for p in metadata['packages']}
    nodes = {n['id']: n for n in metadata['resolve']['nodes']}
    pending = [metadata['resolve']['root']]; seen = set()
    while pending:
        key = pending.pop()
        if key in seen: continue
        seen.add(key)
        for dependency in nodes[key]['deps']:
            if any(kind['kind'] is None for kind in dependency['dep_kinds']): pending.append(dependency['pkg'])
    entries = []; blocks = []; errors = []
    for key in sorted(seen, key=lambda key: (packages[key]['name'], packages[key]['version'])):
        package = packages[key]
        try: selected = select(package.get('license') or '')
        except (ValueError, IndexError) as error:
            errors.append(f"{package['name']}: {error}"); continue
        directory = pathlib.Path(package['manifest_path']).parent
        files = notices(directory)
        upstream = ROOT / 'Licenses/Rust-upstream' / (package['name'] + '-' + package['version'])
        if upstream.is_dir(): files.extend(sorted(upstream.glob('NOTICE*.txt')))
        selection = upstream / 'source-notice.json'
        if selection.is_file():
            record = json.loads(selection.read_text())
            selected = record['selectedLicense']
            if selected not in package['license']: raise ValueError('Selection does not match package license')
        if not files: errors.append(f"{package['name']}: missing original license/notice")
        entry = {k: package.get(k) for k in ['name', 'version', 'source', 'repository', 'license']}
        entry['selectedLicense'] = selected
        if selection.is_file(): entry['noticeBasis'] = json.loads(selection.read_text())
        entry['notices'] = []
        blocks.append(f"\n=== {package['name']} {package['version']} | selected: {selected} ===\n")
        for path in files:
            data = path.read_bytes()
            entry['notices'].append({'file': str(path.relative_to(directory)) if path.is_relative_to(directory) else path.name, 'sha256': hashlib.sha256(data).hexdigest()})
            blocks.append(f'\n--- {path.name} ---\n' + data.decode('utf-8', errors='replace'))
        entries.append(entry)
    if errors: raise SystemExit('\n'.join(errors))
    (ROOT / 'Licenses/Rust-dependencies.json').write_text(json.dumps(entries, indent=2) + '\n')
    (ROOT / 'Licenses/Rust-notices.txt').write_text('\n'.join(blocks))
    (ROOT / 'Licenses/Rust-audit.json').write_text(json.dumps({'cargoLockSHA256': hashlib.sha256((ROOT / 'NativeCodex/Cargo.lock').read_bytes()).hexdigest(), 'packageCount': len(entries), 'noticeExceptions': [entry['name'] for entry in entries if entry.get('noticeBasis', {}).get('review')]}, indent=2) + '\n')
    print(f'PASS: {len(entries)} runtime Rust packages have a recorded permissive license choice and notice evidence.')
    print('Scope: target-filtered Cargo runtime graph; native vendored code is preserved in notices and requires separate source review.')
if __name__ == '__main__': main()
