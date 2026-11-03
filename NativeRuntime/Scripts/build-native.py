#!/usr/bin/env python3
"""Build the pinned native search (Exec worker) and workspace operations (app) libraries.

Each feature is built into its own static archive and XCFramework:
  search     -> Vendor/NativeSearch.xcframework     (libhyotan_search.a)
  operations -> Vendor/NativeOperations.xcframework (libhyotan_operations.a)
The `ca-bundle` feature is resolved for metadata only, so build-ca.py encodes the
pinned trust anchors; it is never compiled into either archive.
Rust 1.95.0 and Xcode are required.
"""
import argparse
import copy
import json
import os
import pathlib
import shutil
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parents[1]
CRATE = ROOT / 'NativeLibrary'
TOOLCHAIN = '1.95.0'
FEATURES = [
    ('NativeSearch', 'search', 'include-search', 'libhyotan_search.a'),
    ('NativeOperations', 'operations', 'include-operations', 'libhyotan_operations.a'),
]


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


def cargo_command():
    rustup = shutil.which('rustup')
    if not rustup:
        candidate = pathlib.Path(os.environ.get('CARGO_HOME', pathlib.Path.home() / '.cargo')) / 'bin/rustup'
        if candidate.is_file():
            rustup = str(candidate)
    if not rustup:
        raise RuntimeError(f'Install rustup, Rust {TOOLCHAIN}, and its aarch64-apple-ios and aarch64-apple-ios-sim targets first')
    env = dict(os.environ)
    # Cargo launched through rustup can still find a non-proxy Homebrew rustc
    # earlier in PATH. Select the same fixed toolchain for all compiler subprocesses.
    for executable, variable in [('rustc', 'RUSTC'), ('rustdoc', 'RUSTDOC')]:
        env[variable] = subprocess.check_output(
            [rustup, 'which', '--toolchain', TOOLCHAIN, executable], text=True).strip()
    env['IPHONEOS_DEPLOYMENT_TARGET'] = '18.4'
    env['CFLAGS_aarch64_apple_ios_sim'] = '-mios-simulator-version-min=18.4'
    env['CFLAGS_aarch64_apple_ios'] = '-miphoneos-version-min=18.4'
    return [rustup, 'run', TOOLCHAIN, 'cargo'], env


def metadata(cargo, env, features, destination):
    destination.parent.mkdir(parents=True, exist_ok=True)
    with destination.open('w') as stream:
        run(cargo + ['metadata', '--locked', '--manifest-path', CRATE / 'Cargo.toml', '--filter-platform',
                     'aarch64-apple-ios', '--format-version', '1', '--no-default-features', '--features', features],
            env=env, stdout=stream)
    return json.loads(destination.read_text())


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--platform', choices=['both', 'device', 'simulator'], default='both')
    parser.add_argument('--profile', choices=['dev', 'release'], default='release')
    args = parser.parse_args()
    cargo, env = cargo_command()
    target_dir = pathlib.Path(env.get('CARGO_TARGET_DIR', ROOT / '.build/native'))
    env['CARGO_TARGET_DIR'] = str(target_dir)
    platforms = [(name, target) for name, target in [('device', 'aarch64-apple-ios'), ('simulator', 'aarch64-apple-ios-sim')]
                 if args.platform in ('both', name)]
    artifacts = ROOT / '.build/native-artifacts'
    graphs = []
    for framework, feature, header_directory, archive_name in FEATURES:
        headers = CRATE / header_directory
        command = ['xcodebuild', '-create-xcframework']
        for _, target in platforms:
            run(cargo + ['build', '--locked', '--manifest-path', CRATE / 'Cargo.toml', '--target', target,
                         '--profile', args.profile, '--no-default-features', '--features', feature], env=env)
            library = target_dir / target / ('debug' if args.profile == 'dev' else 'release') / 'libhyotan_native.a'
            # Every feature build emits the same archive name. Preserve this exact role's
            # bytes before another build overwrites the Cargo output.
            preserved = artifacts / framework / target / archive_name
            preserved.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(library, preserved)
            command += ['-library', preserved, '-headers', headers]
        output = ROOT / 'Vendor' / (framework + '.xcframework')
        if output.exists():
            shutil.rmtree(output)
        run(command + ['-output', output])
        graphs.append(metadata(cargo, env, feature, ROOT / '.build' / (framework + '-metadata.json')))
    # The shipped CA bundle is derived from this pinned crate source, so its
    # license and notice are audited with the linked runtime graph.
    graphs.append(metadata(cargo, env, 'ca-bundle', ROOT / '.build/CABundle-metadata.json'))
    merged = ROOT / '.build/native-metadata.json'
    merged.write_text(json.dumps(merge_metadata(graphs), indent=2) + '\n')
    run([sys.executable, ROOT / 'Scripts/audit-rust-licenses.py', merged])
    run([sys.executable, ROOT / 'Scripts/build-ca.py', merged])


if __name__ == '__main__':
    main()
