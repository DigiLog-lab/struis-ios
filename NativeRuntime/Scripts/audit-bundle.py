#!/usr/bin/env python3
"""Audit the built app's actual native payload; not a legal opinion."""
import argparse
import json
from pathlib import Path
import plistlib
import re
import subprocess

p = argparse.ArgumentParser()
p.add_argument('--app', required=True, type=Path)
p.add_argument('--link-map', action='append', required=True, type=Path)
a = p.parse_args()
app = a.app.resolve()
workers = {
    'StruisExec': 'com.digiloglab.strius.exec',
}
# The embedded agent runtime was removed: the app calls the model API from Swift.
# None of its former products, archives or code may reach the bundle again.
RETIRED_PATHS = re.compile(r'(^|/)(?:StruisRuntime\.appex|NativeCodex(?:Host)?\.(?:framework|xcframework)|libhyotan_codex\.a)(/|$)')
RETIRED_SYMBOLS = re.compile(r'hyotan_codex|codex_app_server|codex_core|codex_exec_server|codex_protocol')
RETIRED_BYTES = [b'hyotan_codex_', b'codex-rs/', b'NativeCodexHost']
# Inspect definitions in the actual symbol table. LLVM nm's default dyld
# supplement is quadratic for the large Rust executable; the link maps below
# also independently check every linked input. Missing definitions fail closed.
worker_symbols = {}
for name in workers:
    binary = app / 'Extensions' / (name + '.appex') / name
    linked = subprocess.check_output(['otool', '-L', str(binary)], text=True)
    symbols = subprocess.check_output(['nm', '--no-dyldinfo', '-g', '-U', str(binary)], text=True)
    def defines(symbol):
        return re.search(r'\b_' + re.escape(symbol) + r'\s*$', symbols, re.M) is not None
    assert defines('hyotan_rg_run'), 'Exec search engine missing'
    assert defines('hyotan_python_main'), 'Exec Python entry point missing'
    assert not defines('hyotan_codex_start'), 'Exec worker contains the retired agent runtime'
    worker_symbols[name] = True
extensions = sorted(path.name for path in (app / 'Extensions').glob('*.appex'))
assert extensions == sorted(name + '.appex' for name in workers), f'unexpected app extensions: {extensions}'
assert not (app / 'Extensions/StruisRuntime.appex').exists(), 'retired StruisRuntime extension is present'
assert not (app / 'Frameworks/NativeCodexHost.framework').exists(), 'retired NativeCodexHost framework is present'
for name, bundle_id in workers.items():
    worker = app / 'Extensions' / (name + '.appex')
    assert worker.is_dir(), f'{name} extension is missing'
    assert not (worker / 'Frameworks').exists(), 'frameworks must be in the containing app'
    worker_info = plistlib.loads((worker / 'Info.plist').read_bytes())
    assert worker_info.get('CFBundleDisplayName'), f'{name} display name is missing'
    assert worker_info.get('CFBundleIdentifier') == bundle_id, f'{name} bundle ID mismatch'
assert (app / 'python/lib/python3.14/encodings').is_dir()
assert (app / 'PythonPackages/numpy').is_dir()
subprocess.run(['codesign', '--verify', '--deep', '--strict', str(app)], check=True)
info = plistlib.loads((app / 'Info.plist').read_bytes())
# The host links only the trusted workspace operations library (statically).
# The native command runtime stays in the Exec worker.
host_binary = app / info['CFBundleExecutable']
host_symbols = subprocess.check_output(['nm', '--no-dyldinfo', '-g', '-U', str(host_binary)], text=True)
host_linked = subprocess.check_output(['otool', '-L', str(host_binary)], text=True)
for symbol in ['hyotan_codex_start', 'StruisRunCommand', 'hyotan_python_main', 'hyotan_rg_run']:
    assert re.search(r'\b_' + re.escape(symbol) + r'\s*$', host_symbols, re.M) is None, 'host contains native execution implementation: ' + symbol
assert not re.search(r'/(?:Python|ios_system(?:-native)?|files(?:-native)?|text(?:-native)?|shell(?:-native)?|awk(?:-native)?|dash(?:-native)?)\.framework/', host_linked, re.I), 'host links native command dependencies'
def version(value):
    return tuple((list(map(int, value.split('.'))) + [0, 0])[:3])

framework_minimums = {}
for framework in (app / 'Frameworks').glob('*.framework'):
    metadata = plistlib.loads((framework / 'Info.plist').read_bytes())
    binary = framework / metadata['CFBundleExecutable']
    commands = subprocess.check_output(['otool', '-l', str(binary)], text=True)
    minimums = re.findall(r'\bminos\s+(\d+(?:\.\d+)+)', commands)
    minimums += re.findall(r'cmd LC_VERSION_MIN_IPHONEOS\s+cmdsize \d+\s+version (\d+(?:\.\d+)+)', commands)
    assert minimums, f'missing Mach-O deployment target: {framework}'
    declared = metadata['MinimumOSVersion']
    assert all(version(declared) >= version(value) for value in minimums), framework
    assert version(info['MinimumOSVersion']) >= version(declared), framework
    framework_minimums[framework.name] = declared
assert not info.get('UIFileSharingEnabled', False)
assert not info.get('LSSupportsOpeningDocumentsInPlace', False)
points = plistlib.loads((app / 'Extensions' / (info['CFBundleExecutable'] + '.appexpt')).read_bytes())
assert points['com.digiloglab.strius.Runtime'].get('EXRequiresEnhancedSecurity', False) is False, \
    'runtime extension point must use the ordinary sandbox to access the app group'

def entitlements(path):
    out = subprocess.run(['codesign', '-d', '--entitlements', '-', '--xml', str(path)], capture_output=True, check=True).stdout
    return plistlib.loads(out)

host_entitlements = entitlements(app)
group = 'group.com.digiloglab.struis.runtime'
assert group in host_entitlements['com.apple.security.application-groups']
notice_counts = {}
for name in workers:
    worker = app / 'Extensions' / (name + '.appex')
    worker_entitlements = entitlements(worker)
    assert group in worker_entitlements['com.apple.security.application-groups'], name
    assert worker_entitlements['com.apple.security.hardened-process'] is True, name
    notices = worker / 'Licenses'
    ledger = json.loads((notices / 'dependencies.json').read_text())
    for component in ledger:
        assert (notices / component['notice']).is_file(), component['name']
    for filename in ['Rust-dependencies.json', 'Rust-notices.txt', 'Rust-audit.json']:
        assert (notices / filename).stat().st_size > 0, name
    notice_counts[name] = len(ledger)
macho = []
retired_findings = []
for path in app.rglob('*'):
    if RETIRED_PATHS.search(path.relative_to(app).as_posix()):
        retired_findings.append('path ' + path.relative_to(app).as_posix())
    if not path.is_file(): continue
    relative = path.relative_to(app).as_posix()
    assert path.suffix != '.a', f'static development library: {relative}'
    assert not re.search(r'(^|/)(rootfs-v.*|rootfs-manifest.plist|lib(?:ish|ish_emu|hyotan|fakefs)\.a)$', relative), relative
    assert not re.search(r'(^|/)(?:readline|_gdbm)(?:\.framework/|[^/]*\.(?:so|fwork)$)', relative), relative
    with path.open('rb') as f: magic = f.read(4)
    assert magic != b'\x7fELF', f'ELF payload: {relative}'
    if magic in [b'\xcf\xfa\xed\xfe', b'\xca\xfe\xba\xbe', b'\xfe\xed\xfa\xcf']:
        macho.append(relative)
        linked = subprocess.check_output(['otool', '-L', str(path)], text=True)
        assert not re.search(r'lib(?:gfortran|gomp|readline|gdbm|openblas)', linked, re.I), relative
        if re.search(r'NativeCodex|hyotan_codex', linked):
            retired_findings.append('linked library in ' + relative)
        # Every symbol table entry (local, global, undefined), not only exports.
        names = subprocess.run(['nm', '--no-dyldinfo', '-a', '-j', str(path)], capture_output=True, text=True).stdout
        found = sorted({match.group(0) for match in RETIRED_SYMBOLS.finditer(names)})
        if found:
            retired_findings.append(f'symbols {found} in {relative}')
        data = path.read_bytes()
        for marker in RETIRED_BYTES:
            if marker in data:
                retired_findings.append(f'bytes {marker!r} in {relative}')
for finding in retired_findings:
    print('FORBIDDEN retired agent runtime: ' + finding)
assert not retired_findings, 'retired agent runtime code or products are in the bundle'
worker_maps = {name: [] for name in workers}
host_maps = []

def forbid(pattern, contents, message):
    """Fail on any link map line naming forbidden code, in linked inputs or code
    symbols. Only string-literal data entries are exempt: the host's Swift ledger
    values such as "codex_app_server" are data, not linked AppServer code. Every
    match is printed with its section so a Cloud log shows exactly what matched."""
    assert '# Object files:' in contents, 'link map object file section missing'
    section, violations = 'header', []
    for line in contents.splitlines():
        if line.startswith('# ') and line.rstrip().endswith(':'):
            section = line[2:].rstrip(': \t')
            continue
        if not re.search(pattern, line):
            continue
        literal = 'literal string:' in line
        print(('EXEMPT-LITERAL ' if literal else 'FORBIDDEN ') + message + ' [' + section + ']: ' + line.strip()[:300])
        if not literal:
            violations.append(line)
    assert not violations, message

for path in a.link_map:
    contents = path.read_bytes().decode('latin-1')
    assert not re.search(r'lib(?:ish|ish_emu|hyotan|fakefs)\.a|Runtime/hyotan/', contents), path
    host_map_pattern = r'^# Path:.*[/\\]' + re.escape(app.name) + r'[/\\]' + re.escape(info['CFBundleExecutable']) + r'\s*$'
    if re.search(host_map_pattern, contents, re.M):
        host_maps.append(str(path))
        # Only the trusted workspace operations archive is linked into the host.
        assert re.search(r'libhyotan_operations\.a', contents), 'host link map lacks the workspace operations library'
        forbid(r'NativeSearch\.xcframework|libhyotan_search\.a|RuntimeCommand\.o|PythonCommand\.o|SearchCommand\.o|GraphicsModule\.o', contents, 'host link map includes command code')
    forbid(r'NativeCodex|libhyotan_codex|hyotan_codex|codex_app_server|codex_core|codex_exec_server|codex_protocol|StruisRuntime', contents, 'link map includes the retired agent runtime')
    for name in workers:
        if not re.search(r'^# Path:.*[/\\]' + re.escape(name) + r'\.appex[/\\]' + re.escape(name) + r'\s*$', contents, re.M):
            continue
        worker_maps[name].append(str(path))
        forbid(r'libhyotan_operations\.a', contents, 'Exec link map includes the host workspace operations library')
assert all(worker_maps.values()), 'actual link maps for every worker are required'
assert host_maps, 'actual host link map is required'
print(json.dumps({'status':'PASS', 'app':str(app), 'signed':True,
                  'framework_minimum_os':framework_minimums,
                  'enhanced_security_extension':False, 'app_group':group,
                  'worker_bundle_ids':workers, 'notice_components':notice_counts, 'macho_files':len(macho),
                  'worker_dependency_separation':worker_symbols, 'host_execution_dependencies_absent':True,
                  'retired_agent_runtime_absent':True,
                  'legacy_runtime_or_rootfs':False, 'ELF_files':0,
                  'link_maps':[str(x) for x in a.link_map]}, ensure_ascii=False, indent=2))
