#!/usr/bin/env python3
"""Verify actual pinned-source generation without modifying the vendor checkout.

The cfg probes use a host Rust compiler; they do not build an iOS SDK artifact.
Run after fetching pinned Codex and the original dirs-sys source/archive.
"""
import argparse
import hashlib
import os
import pathlib
import re
import shutil
import subprocess
import sys
import tempfile

ROOT = pathlib.Path(__file__).resolve().parents[1]
SOURCE = ROOT / 'Vendor/codex-source'
PIN = '3d2ee51ca2d5db578f328aa75e20aa22c0197c9a'
HEADER = '// Hyotan: modified for the embedded iOS runtime.\n'
SQLITE = 'codex-rs/state/src/sqlite.rs'
FEEDBACK = 'codex-rs/feedback/src/lib.rs'
HISTORY = 'codex-rs/core/src/context_manager/history.rs'


def run(args, **kwargs):
    result = subprocess.run([str(arg) for arg in args], capture_output=True,
                            text=True, **kwargs)
    if result.returncode:
        raise RuntimeError(f'Command failed ({result.returncode}): {args}\n'
                           f'{result.stdout}{result.stderr}')
    return result.stdout


def require(condition, message):
    if not condition:
        raise AssertionError(message)


def original(relative):
    return run(['git', '-C', SOURCE, 'show', f'{PIN}:{relative}'])


def snapshot(directory):
    return {str(path.relative_to(directory)): hashlib.sha256(path.read_bytes()).hexdigest()
            for path in directory.rglob('*')
            if path.is_file() and '.git' not in path.relative_to(directory).parts}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--rustc', default=shutil.which('rustc'))
    args = parser.parse_args()
    require(args.rustc is not None, 'Provide --rustc for both cfg compilation probes')
    require(run(['git', '-C', SOURCE, 'rev-parse', 'HEAD']).strip() == PIN,
            'Vendor source must match the pinned revision')
    with tempfile.TemporaryDirectory(prefix='hyotan-codex-memory-') as temporary:
        root = pathlib.Path(temporary) / 'NativeRuntime'
        scripts = root / 'Scripts'
        scripts.mkdir(parents=True)
        for name in ('prepare-codex.py', 'prepare-turn-lease.py',
                     'prepare-model-file-operations.py', 'prepare-role-reads.py', 'fetch.py'):
            shutil.copyfile(ROOT / 'Scripts' / name, scripts / name)
        native_ios = root / 'NativeCodex/ios'
        native_ios.mkdir(parents=True)
        for name in ('file_search.rs', 'turn_lease.rs', 'turn_lease_appserver_tests.rs',
                     'model_operations.rs', 'role_snapshot.rs', 'role_snapshot_tests.rs'):
            shutil.copyfile(ROOT / 'NativeCodex/ios' / name, native_ios / name)
        integration = root / 'TurnLeaseIntegration'
        integration.mkdir(parents=True)
        shutil.copyfile(ROOT / 'TurnLeaseIntegration/appserver.Cargo.lock',
                        integration / 'appserver.Cargo.lock')
        source = root / 'Vendor/codex-source'
        source.parent.mkdir(parents=True)
        run(['git', 'clone', '--shared', '--no-checkout', SOURCE, source])
        run(['git', '-C', source, 'checkout', PIN, '--',
             'codex-rs/core/src', 'codex-rs/file-search', 'codex-rs/utils/audio', SQLITE, FEEDBACK, HISTORY])
        environment = dict(os.environ)
        cargo_home = pathlib.Path(temporary) / 'cargo'
        environment['CARGO_HOME'] = str(cargo_home)
        # Use original cached source, never the already patched vendor copy.
        dirs_source = ROOT / '.build/dirs-upstream/dirs-sys-0.5.0'
        if not dirs_source.is_dir():
            configured_home = pathlib.Path(os.environ.get('CARGO_HOME', pathlib.Path.home() / '.cargo'))
            candidates = list((configured_home / 'registry/src').glob('*/dirs-sys-0.5.0'))
            require(len(candidates) == 1, 'Original dirs-sys cache is required (no network fetch in this check)')
            dirs_source = candidates[0]
        shutil.copytree(dirs_source, cargo_home / 'registry/src/check/dirs-sys-0.5.0')
        run([sys.executable, scripts / 'prepare-codex.py'], env=environment)
        first = snapshot(source)
        dirs_first = snapshot(root / 'Vendor/dirs-sys')
        run([sys.executable, scripts / 'prepare-codex.py'], env=environment)
        require(snapshot(source) == first, 'Codex generation is not idempotent')
        require(snapshot(root / 'Vendor/dirs-sys') == dirs_first, 'dirs-sys generation is not idempotent')
        sqlite = (source / SQLITE).read_text()
        feedback = (source / FEEDBACK).read_text()
        sqlite_constants = '''#[cfg(target_os = "ios")]
const MAX_READ_WRITE_CONNECTIONS: u32 = 1;
#[cfg(not(target_os = "ios"))]
const MAX_READ_WRITE_CONNECTIONS: u32 = 5;

'''
        feedback_constants = '''#[cfg(target_os = "ios")]
const DEFAULT_MAX_BYTES: usize = 256 * 1024; // 256 KiB
#[cfg(not(target_os = "ios"))]
const DEFAULT_MAX_BYTES: usize = 4 * 1024 * 1024; // 4 MiB'''
        require(sqlite.count(sqlite_constants) == 1, 'Expected platform SQLite constants missing')
        require(feedback.count(feedback_constants) == 1, 'Expected platform feedback constants missing')
        sqlite_journal = '''            .journal_mode(if cfg!(target_os = "ios") {
                SqliteJournalMode::Delete
            } else {
                SqliteJournalMode::Wal
            })
'''
        require(sqlite.count(sqlite_journal) == 1 and sqlite.count('SqliteJournalMode::Wal') == 1,
                'Writable pool must use a rollback journal on iOS and WAL elsewhere')
        require(sqlite.removeprefix(HEADER).replace(sqlite_constants, '').replace(
            '.max_connections(MAX_READ_WRITE_CONNECTIONS)', '.max_connections(5)').replace(
            sqlite_journal, '            .journal_mode(SqliteJournalMode::Wal)\n') == original(SQLITE),
            'SQLite changes extend beyond the writable connection limit and journal mode')
        require(feedback.removeprefix(HEADER).replace(feedback_constants,
            'const DEFAULT_MAX_BYTES: usize = 4 * 1024 * 1024; // 4 MiB') == original(FEEDBACK),
            'Feedback changes extend beyond the default ring capacity')
        require(sqlite.count('.max_connections(MAX_READ_WRITE_CONNECTIONS)') == 1
                and sqlite.count('.max_connections(1)') == 1,
                'Writable pool must use selected cap; read-only pool must retain upstream cap')
        require((source / 'codex-rs/file-search/src/hyotan.rs').read_bytes()
                == (ROOT / 'NativeCodex/ios/file_search.rs').read_bytes(),
                'Existing native file-search adaptation changed')
        require('hyotan_audio_duration' in (source / 'codex-rs/utils/audio/src/lib.rs').read_text(),
                'Existing Apple audio adaptation missing')
        require('cfg(not(target_os = "ios"))' in (source / 'codex-rs/file-search/Cargo.toml').read_text(),
                'Existing non-iOS dependency selection missing')
        # Compile constants extracted from actual generated source in each cfg.
        # Only constants are probed; full SQLite/feedback crates need SDK/Cloud checks.
        selected = []
        for text in (sqlite, feedback):
            selected.extend(re.findall(
                r'#\[cfg\((?:not\()?target_os = "ios"\)?\)\]\nconst (?:MAX_READ_WRITE_CONNECTIONS|DEFAULT_MAX_BYTES):[^\n]+', text))
        require(len(selected) == 4, 'Could not extract both actual platform constant branches')
        for ios, connections, capacity in ((False, 5, 4 * 1024 * 1024), (True, 1, 256 * 1024)):
            probe = pathlib.Path(temporary) / ('ios.rs' if ios else 'host.rs')
            probe.write_text('\n'.join(selected) + '\nfn main() {\n'
                f'assert_eq!(MAX_READ_WRITE_CONNECTIONS, {connections});\n'
                f'assert_eq!(DEFAULT_MAX_BYTES, {capacity});\n' + '}\n')
            binary = probe.with_suffix('')
            command = [args.rustc, '--edition=2024', probe, '-o', binary]
            if ios:
                command.extend(['--cfg', 'target_os="ios"', '-Aexplicit_builtin_cfgs_in_flags'])
            run(command)
            run([binary])
            print(f'PASS cfg={"ios-host-probe" if ios else "non-ios-host"} writable_connections={connections} feedback_bytes={capacity}')
        print('PASS actual pinned-source generation twice; complete generated-source hashes identical')
        print('PASS untouched upstream SQLite/feedback behavior outside platform constants; existing adaptations retained')
        print('LIMIT full Rust/iOS SDK build, native execution, peak memory and real-device recovery remain unverified')


if __name__ == '__main__':
    main()
