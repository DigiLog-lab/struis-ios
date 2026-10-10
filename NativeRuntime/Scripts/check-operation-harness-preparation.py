#!/usr/bin/env python3
"""Check actual pinned-source factory generation; no AppServer/iOS runtime claim."""
import hashlib
import importlib.util
import os
import pathlib
import shutil
import tempfile

HERE = pathlib.Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location('memory_check', HERE / 'check-codex-memory-preparation.py')
memory = importlib.util.module_from_spec(spec)
spec.loader.exec_module(memory)
ENV = 'codex-rs/exec-server/src/environment.rs'
LIB = 'codex-rs/exec-server/src/lib.rs'
FACTORY = '''            filesystem: Arc::new(LocalFileSystem::with_runtime_paths(
                local_runtime_paths.clone(),
            )),'''
REPLACEMENT = '            filesystem: hyotan_local_file_system(local_runtime_paths.clone()),'

with tempfile.TemporaryDirectory(prefix='hyotan-harness-source-') as temporary:
    root = pathlib.Path(temporary) / 'NativeRuntime'
    scripts = root / 'Scripts'
    scripts.mkdir(parents=True)
    for name in ('prepare-codex.py', 'prepare-turn-lease.py',
                 'prepare-model-file-operations.py', 'prepare-role-reads.py', 'fetch.py'):
        shutil.copyfile(HERE / name, scripts / name)
    ios = root / 'NativeCodex/ios'
    ios.mkdir(parents=True)
    for name in ('file_search.rs', 'turn_lease.rs', 'turn_lease_appserver_tests.rs',
                 'model_operations.rs', 'role_snapshot.rs', 'role_snapshot_tests.rs'):
        shutil.copyfile(memory.ROOT / 'NativeCodex/ios' / name, ios / name)
    integration = root / 'TurnLeaseIntegration'
    integration.mkdir(parents=True)
    shutil.copyfile(memory.ROOT / 'TurnLeaseIntegration/appserver.Cargo.lock',
                    integration / 'appserver.Cargo.lock')
    source = root / 'Vendor/codex-source'
    source.parent.mkdir(parents=True)
    memory.run(['git', 'clone', '--shared', '--no-checkout', memory.SOURCE, source])
    memory.run(['git', '-C', source, 'checkout', memory.PIN, '--', 'codex-rs/core/src', 'codex-rs/file-search', 'codex-rs/utils/audio', memory.SQLITE, memory.FEEDBACK, memory.HISTORY, ENV, LIB])
    env = dict(os.environ)
    cargo = pathlib.Path(temporary) / 'cargo'
    env['CARGO_HOME'] = str(cargo)
    upstream = memory.ROOT / '.build/dirs-upstream/dirs-sys-0.5.0'
    if not upstream.is_dir():
        cached = pathlib.Path(os.environ.get('CARGO_HOME', pathlib.Path.home() / '.cargo'))
        choices = list((cached / 'registry/src').glob('*/dirs-sys-0.5.0'))
        memory.require(len(choices) == 1, 'Original cached dirs-sys source required')
        upstream = choices[0]
    shutil.copytree(upstream, cargo / 'registry/src/check/dirs-sys-0.5.0')
    memory.run([os.sys.executable, scripts / 'prepare-codex.py'], env=env)
    first = memory.snapshot(source)
    memory.run([os.sys.executable, scripts / 'prepare-codex.py'], env=env)
    memory.require(first == memory.snapshot(source), 'Factory generation must be idempotent')
    generated = (source / ENV).read_text().removeprefix(memory.HEADER)
    original, hook = generated.split('\n\n#[cfg(target_os = "ios")]\nstatic HYOTAN_LOCAL_FILE_SYSTEM:', 1)
    memory.require(original.rstrip().replace(REPLACEMENT, FACTORY) == memory.original(ENV).rstrip(), 'Environment changes exceed local factory and appended hook')
    memory.require(generated.count(REPLACEMENT) == 1, 'Actual Environment::local must use trusted factory')
    memory.require('HYOTAN_LOCAL_FILE_SYSTEM.set(filesystem)' in hook, 'One-time installation missing')
    memory.require('Arc::new(LocalFileSystem::with_runtime_paths(runtime_paths))' in hook, 'Original uninstalled/non-iOS fallback missing')
    lib = (source / LIB).read_text().removeprefix(memory.HEADER)
    export = '\n#[cfg(target_os = "ios")]\npub use environment::hyotan_install_local_file_system;\n'
    memory.require(lib.removesuffix(export) == memory.original(LIB), 'Exports alter upstream behavior outside iOS hook')
    print('PASS actual pinned Environment::local factory; one-time iOS installation; uninstalled/non-iOS factory retained')
    print('PASS actual generation twice; complete generated source hashes identical')
    print('LIMIT no Swift, SDK, AppServer RPC, native command isolation or product host-mode verification')
