#!/usr/bin/env python3
"""Run pinned-source estimator/cfg and synthetic allocation checks on Linux.

The actual generated estimator runs with real base64 and image libraries and a
cold-cache shim. Separate dimension-only allocator windows exclude common input
and base64 retention. Neither probe measures iOS physical footprint.
"""
import argparse
import importlib.util
import os
import pathlib
import re
import shutil
import tempfile

SCRIPTS = pathlib.Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location('memory_check', SCRIPTS / 'check-codex-memory-preparation.py')
memory = importlib.util.module_from_spec(spec)
spec.loader.exec_module(memory)
ROOT, SOURCE, PIN = memory.ROOT, memory.SOURCE, memory.PIN
HISTORY = memory.HISTORY


def function(text, name):
    start = text.index('fn ' + name + '(')
    end = text.index('\n}\n', start) + 3
    return text[start:end]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--cargo', default=shutil.which('cargo'))
    parser.add_argument('--rustc', default=shutil.which('rustc'))
    parser.add_argument('--target-dir')
    args = parser.parse_args()
    memory.require(args.cargo and args.rustc, 'Provide --cargo and --rustc')
    memory.require(memory.run(['git', '-C', SOURCE, 'rev-parse', 'HEAD']).strip() == PIN, 'Unexpected Codex pin')
    with tempfile.TemporaryDirectory(prefix='hyotan-image-estimate-') as temporary:
        root = pathlib.Path(temporary) / 'NativeRuntime'
        scripts = root / 'Scripts'
        scripts.mkdir(parents=True)
        for name in ('prepare-codex.py', 'prepare-turn-lease.py',
                     'prepare-model-file-operations.py', 'prepare-role-reads.py', 'fetch.py'):
            shutil.copyfile(SCRIPTS / name, scripts / name)
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
        memory.run(['git', 'clone', '--shared', '--no-checkout', SOURCE, source])
        memory.run(['git', '-C', source, 'checkout', PIN, '--', 'codex-rs/core/src', 'codex-rs/file-search',
                    'codex-rs/utils/audio', memory.SQLITE, memory.FEEDBACK, HISTORY])
        environment = dict(os.environ)
        # Generation is isolated and deliberately has no network dependency.
        preparation_environment = dict(environment)
        preparation_environment['CARGO_HOME'] = str(pathlib.Path(temporary) / 'cargo-source')
        original_dirs = ROOT / '.build/dirs-upstream/dirs-sys-0.5.0'
        if not original_dirs.is_dir():
            cached_home = pathlib.Path(os.environ.get('CARGO_HOME', pathlib.Path.home() / '.cargo'))
            candidates = list((cached_home / 'registry/src').glob('*/dirs-sys-0.5.0'))
            memory.require(len(candidates) == 1, 'Original dirs-sys cache required')
            original_dirs = candidates[0]
        shutil.copytree(original_dirs, pathlib.Path(preparation_environment['CARGO_HOME']) / 'registry/src/check/dirs-sys-0.5.0')
        memory.run([os.sys.executable, scripts / 'prepare-codex.py'], env=preparation_environment)
        before = memory.snapshot(source)
        memory.run([os.sys.executable, scripts / 'prepare-codex.py'], env=preparation_environment)
        memory.require(before == memory.snapshot(source), 'Generated source is not idempotent')
        generated = (source / HISTORY).read_text().removeprefix(memory.HEADER)
        original = memory.original(HISTORY)
        original_function = function(original, 'estimate_original_image_bytes')
        generated_function = function(generated, 'estimate_original_image_bytes')
        # Everything outside this estimator is exactly pinned upstream.
        memory.require(generated.replace(generated_function, original_function) == original,
                       'History changes extend beyond the original-detail estimator')
        dimension_start = original_function.index('        let dynamic = ')
        dimension_end = original_function.index('        let patch_size = ', dimension_start)
        adapted_start = generated_function.index('        // Token estimation only:')
        adapted_end = generated_function.index('        let patch_size = ', adapted_start)
        memory.require(original_function[:dimension_start] == generated_function[:adapted_start]
                       and original_function[dimension_end:] == generated_function[adapted_end:],
                       'Base64/cache/formula changed outside dimension extraction')
        full = original_function[dimension_start:dimension_end]
        memory.require(''.join('    ' + line + '\n' for line in full.splitlines()) in generated_function,
                       'Non-iOS upstream full decode not retained')
        memory.require('#[cfg(target_os = "ios")]' in generated_function
                       and '#[cfg(not(target_os = "ios"))]' in generated_function,
                       'Both platform branches must be retained')
        fixture = pathlib.Path(temporary) / 'check'
        shutil.copytree(SCRIPTS / 'ImageEstimateCheck', fixture)
        constants = '\n'.join(re.findall(r'^const ORIGINAL_IMAGE_(?:PATCH_SIZE|MAX_PATCHES):[^\n]+', original, re.M))
        parse_start = original.index('fn parse_base64_image_data_url(')
        parse_end = original.index('fn estimate_original_image_bytes(', parse_start)
        byte_formula_source = memory.original('codex-rs/utils/string/src/truncate.rs')
        formula = function(byte_formula_source, 'approx_bytes_for_tokens')
        byte_constant = re.search(r'^const APPROX_BYTES_PER_TOKEN:[^\n]+', byte_formula_source, re.M).group(0)
        (fixture / 'generated_estimator.rs').write_text(constants + '\n' + byte_constant + '\n' + formula
            + '\n' + original[parse_start:parse_end] + generated_function + '\n'
            + original_function.replace('fn estimate_original_image_bytes(', 'fn reference_estimate_original_image_bytes(', 1))
        environment['RUSTC'] = args.rustc
        target = pathlib.Path(args.target_dir) if args.target_dir else pathlib.Path(temporary) / 'target'
        environment['CARGO_TARGET_DIR'] = str(target)
        for ios in (False, True):
            command = [args.cargo, 'rustc', '--locked', '--offline', '--release', '--manifest-path', fixture / 'Cargo.toml']
            if ios:
                command += ['--', '--cfg', 'target_os="ios"', '-Aexplicit_builtin_cfgs_in_flags']
            memory.run(command, env=environment)
            print(memory.run([target / 'release/hyotan-image-estimate-check']), end='')
        print('PASS actual pinned-source adaptation twice; base64/cache/formula and non-iOS full decode preserved')
        print('LIMIT readable header with malformed image body may still estimate dimensions; this is not validation success')
        print('LIMIT full iOS SDK/native cold resume, physical peak and real-device PDF recovery remain unverified')


if __name__ == '__main__':
    main()
