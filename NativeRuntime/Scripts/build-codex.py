#!/usr/bin/env python3
"""Build separate pinned Codex, search and operations libraries, and the app-process Codex framework. Rust 1.95.0 and Xcode are required."""
import argparse
import copy
import json
import os
import pathlib
import plistlib
import shutil
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parents[1]
SOURCE = ROOT / 'Vendor/codex-source'
REVISION = '3d2ee51ca2d5db578f328aa75e20aa22c0197c9a'

def run(args, **kwargs):
    subprocess.run([str(arg) for arg in args], check=True, **kwargs)

def merge_metadata(graphs):
    """Audit all active feature graphs once, without losing either runtime closure."""
    merged = copy.deepcopy(graphs[0])
    packages = {package['id']: package for package in merged['packages']}
    nodes = {node['id']: node for node in merged['resolve']['nodes']}
    for graph in graphs[1:]:
        if graph['resolve']['root'] != merged['resolve']['root']:
            raise RuntimeError('Rust feature graphs have different root packages')
        for package in graph['packages']:
            previous = packages.get(package['id'])
            if previous is not None and previous != package:
                raise RuntimeError(f"Rust package metadata differs: {package['id']}")
            packages[package['id']] = copy.deepcopy(package)
        for node in graph['resolve']['nodes']:
            if node['id'] not in nodes:
                nodes[node['id']] = copy.deepcopy(node)
                continue
            previous = nodes[node['id']]
            previous['features'] = sorted(set(previous['features']) | set(node['features']))
            previous['dependencies'] = sorted(set(previous['dependencies']) | set(node['dependencies']))
            dependencies = {(dep['name'], dep['pkg']): dep for dep in previous['deps']}
            for dependency in node['deps']:
                key = (dependency['name'], dependency['pkg'])
                if key not in dependencies:
                    dependencies[key] = copy.deepcopy(dependency)
                else:
                    kinds = {json.dumps(kind, sort_keys=True): kind for kind in dependencies[key]['dep_kinds']}
                    for kind in dependency['dep_kinds']:
                        kinds[json.dumps(kind, sort_keys=True)] = kind
                    dependencies[key]['dep_kinds'] = [kinds[key] for key in sorted(kinds)]
            previous['deps'] = [dependencies[key] for key in sorted(dependencies)]
    merged['packages'] = [packages[key] for key in sorted(packages)]
    merged['resolve']['nodes'] = [nodes[key] for key in sorted(nodes)]
    return merged

parser = argparse.ArgumentParser()
parser.add_argument('--platform', choices=['both', 'device', 'simulator'], default='both')
parser.add_argument('--profile', choices=['dev', 'release'], default='release')
args = parser.parse_args()
if not SOURCE.exists():
    run(['git', 'clone', '--depth', '1', '--branch', 'rust-v0.153.4', 'https://github.com/openai/codex.git', SOURCE])
if subprocess.check_output(['git', '-C', str(SOURCE), 'rev-parse', 'HEAD'], text=True).strip() != REVISION:
    raise RuntimeError('Unexpected Codex source revision')
run([sys.executable, ROOT / 'Scripts/prepare-codex.py'])
rustup = shutil.which('rustup')
if not rustup:
    candidate = pathlib.Path(os.environ.get('CARGO_HOME', pathlib.Path.home() / '.cargo')) / 'bin/rustup'
    if candidate.is_file(): rustup = str(candidate)
if not rustup:
    raise RuntimeError('Install rustup, Rust 1.95.0, and its aarch64-apple-ios and aarch64-apple-ios-sim targets first')
cargo = [rustup, 'run', '1.95.0', 'cargo']
env = dict(os.environ)
# Cargo launched through rustup can still find a non-proxy Homebrew rustc
# earlier in PATH. Select the same fixed toolchain for all compiler subprocesses.
for executable, variable in [('rustc', 'RUSTC'), ('rustdoc', 'RUSTDOC')]:
    env[variable] = subprocess.check_output(
        [rustup, 'which', '--toolchain', '1.95.0', executable], text=True).strip()
env['IPHONEOS_DEPLOYMENT_TARGET'] = '18.4'
env['CFLAGS_aarch64_apple_ios_sim'] = '-mios-simulator-version-min=18.4'
env['CFLAGS_aarch64_apple_ios'] = '-miphoneos-version-min=18.4'
target_dir = pathlib.Path(env.get('CARGO_TARGET_DIR', ROOT / '.build/codex'))
env['CARGO_TARGET_DIR'] = str(target_dir)
platforms = [('device', 'aarch64-apple-ios'), ('simulator', 'aarch64-apple-ios-sim')]
manifest = ROOT / 'NativeCodex/Cargo.toml'
artifacts = ROOT / '.build/codex-artifacts'
graphs = []
for framework, feature, header_directory in [
    ('NativeCodex', 'codex', 'include'),
    ('NativeSearch', 'search', 'include-search'),
    ('NativeOperations', 'operations', 'include-operations'),
]:
    headers = ROOT / 'NativeCodex' / header_directory
    headers.mkdir(exist_ok=True)
    if feature == 'codex':
        shutil.copyfile(ROOT / 'Worker/CodexBridge.h', headers / 'HyotanCodex.h')
    selection = ['--no-default-features', '--features', feature]
    command = ['xcodebuild', '-create-xcframework']
    for name, target in platforms:
        if args.platform != 'both' and name != args.platform: continue
        run(cargo + ['build', '--locked', '--manifest-path', manifest, '--target', target, '--profile', args.profile] + selection, env=env)
        library = target_dir / target / ('debug' if args.profile == 'dev' else 'release') / 'libhyotan_codex.a'
        # All feature builds emit the same archive name. Preserve this exact role's
        # bytes before another build overwrites the Cargo output.
        archive_name = {'search': 'libhyotan_search.a', 'operations': 'libhyotan_operations.a'}.get(feature, library.name)
        preserved = artifacts / framework / target / archive_name
        preserved.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(library, preserved)
        command += ['-library', preserved, '-headers', headers]
    output = ROOT / 'Vendor' / (framework + '.xcframework')
    if output.exists(): shutil.rmtree(output)
    run(command + ['-output', output])
    graph_file = ROOT / '.build' / (framework + '-metadata.json')
    graph_file.parent.mkdir(exist_ok=True)
    with graph_file.open('w') as stream:
        run(cargo + ['metadata', '--locked', '--manifest-path', manifest, '--filter-platform', 'aarch64-apple-ios', '--format-version', '1'] + selection, env=env, stdout=stream)
    graphs.append(json.loads(graph_file.read_text()))
# The app process runs Codex from a dynamic framework, not from the host
# executable: the archive bundles its own SQLite, and the Ledger's GRDB must
# keep binding to the system library. A separate image keeps each copy's
# references internal; only the hyotan_* C API is exported.
HOST_FRAMEWORK = 'NativeCodexHost'
host_exports = ROOT / '.build' / 'native-codex-host-exports.txt'
host_exports.write_text('_hyotan_*\n')
host_command = ['xcodebuild', '-create-xcframework']
for name, target in platforms:
    if args.platform != 'both' and name != args.platform: continue
    sdk, triple = {'device': ('iphoneos', 'arm64-apple-ios18.4'),
                   'simulator': ('iphonesimulator', 'arm64-apple-ios18.4-simulator')}[name]
    framework = artifacts / HOST_FRAMEWORK / target / (HOST_FRAMEWORK + '.framework')
    if framework.exists(): shutil.rmtree(framework)
    (framework / 'Headers').mkdir(parents=True)
    shutil.copyfile(ROOT / 'Worker/CodexBridge.h', framework / 'Headers/HyotanCodex.h')
    shutil.copyfile(ROOT / 'NativeCodex/include-operations/HyotanOperations.h', framework / 'Headers/HyotanOperations.h')
    run(['xcrun', '-sdk', sdk, 'clang', '-target', triple, '-dynamiclib', '-fobjc-arc',
         '-install_name', f'@rpath/{HOST_FRAMEWORK}.framework/{HOST_FRAMEWORK}',
         '-o', framework / HOST_FRAMEWORK, ROOT / 'Worker/AudioDuration.m',
         '-Wl,-force_load,' + str(artifacts / 'NativeCodex' / target / 'libhyotan_codex.a'),
         '-Wl,-dead_strip', '-Wl,-exported_symbols_list,' + str(host_exports),
         '-lc++', '-liconv', '-lz', '-lresolv',
         '-framework', 'Foundation', '-framework', 'AVFoundation', '-framework', 'Security',
         '-framework', 'SystemConfiguration', '-framework', 'CoreFoundation', '-framework', 'UIKit'])
    plist = {
        'CFBundleExecutable': HOST_FRAMEWORK, 'CFBundleIdentifier': 'com.digiloglab.strius.nativecodex',
        'CFBundleName': HOST_FRAMEWORK, 'CFBundlePackageType': 'FMWK', 'CFBundleInfoDictionaryVersion': '6.0',
        'CFBundleShortVersionString': '1.0', 'CFBundleVersion': '1', 'MinimumOSVersion': '18.4',
        'CFBundleSupportedPlatforms': ['iPhoneSimulator' if name == 'simulator' else 'iPhoneOS'],
    }
    (framework / 'Info.plist').write_bytes(plistlib.dumps(plist))
    host_command += ['-framework', framework]
host_output = ROOT / 'Vendor' / (HOST_FRAMEWORK + '.xcframework')
if host_output.exists(): shutil.rmtree(host_output)
run(host_command + ['-output', host_output])

metadata = ROOT / '.build/codex-metadata.json'
metadata.write_text(json.dumps(merge_metadata(graphs), indent=2) + '\n')
run([sys.executable, ROOT / 'Scripts/audit-rust-licenses.py', metadata])

run([sys.executable, ROOT / 'Scripts/build-ca.py', metadata])
