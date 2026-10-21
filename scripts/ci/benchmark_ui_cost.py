#!/usr/bin/env python3
"""Paired UI cost experiment; same binary, five methods, one simulator, ABBA order.

This measures deterministic reply-tail control and practice-ready fixtures only.
It does not measure module extraction, dependency-based skipping, or full-CI savings.
"""
import json
import os
from pathlib import Path
import subprocess
import sys
import time

ROOT = Path(os.environ['RUNNER_TEMP']) / 'ci-cost-benchmark'
ROOT.mkdir(exist_ok=True)
TESTS = [
    'ReplyTailUITests/testQuestionSheetSendsWhileReplyIsRecording',
    'ReplyTailUITests/testAdvanceAppearsWhileReadyReplyIsRecording',
    'WorkbookSplitGradingUITests/testPhotosAddUpToOneSetResult',
    'WorkbookSplitGradingCloseSetUITests/testCloseSetWithFoundProblems',
    'WorkbookSplitGradingBatchUITests/testBatchOfPhotosGradedAsOneAnswer',
]
COMMAND = [
    'xcodebuild', 'test-without-building', '-project', 'strius.xcodeproj', '-scheme', 'strius',
    '-destination', 'id=' + os.environ['SIMULATOR_UDID'],
    '-derivedDataPath', os.environ['RUNNER_TEMP'] + '/DerivedData',
    '-collect-test-diagnostics', 'never', '-parallel-testing-enabled', 'NO',
    '-test-timeouts-enabled', 'YES', '-default-test-execution-time-allowance', '180',
    '-maximum-test-execution-time-allowance', '300', 'ARCHS=arm64', 'STRUIS_AUTH_REQUIRED=YES',
]


def run(label, variant, tests):
    result = ROOT / (label + '.xcresult')
    command = COMMAND + ['-resultBundlePath', str(result)] + tests
    environment = dict(os.environ, TEST_RUNNER_STRUIS_CI_BENCH_VARIANT=variant)
    started = time.monotonic()
    print(f'::group::{label} variant={variant}', flush=True)
    with (ROOT / (label + '.log')).open('w') as log:
        # Simulator descendants can inherit stdout after xcodebuild exits. Waiting
        # for a pipe EOF then blocks the next pass despite TEST EXECUTE SUCCEEDED.
        process = subprocess.Popen(command, stdout=log, stderr=subprocess.STDOUT, env=environment)
        with (ROOT / (label + '.log')).open() as live:
            while True:
                for line in live:
                    if any(word in line for word in ('Test Case', 'Test Suite', 'error:', 'failed', 'TEST ', 'Testing ')):
                        print(line.rstrip(), flush=True)
                if process.poll() is not None:
                    break
                time.sleep(1)
        code = process.wait()
    seconds = time.monotonic() - started
    print(f'::endgroup::\nBENCHMARK {label} exit={code} wall_seconds={seconds:.3f}', flush=True)
    for kind in ('summary', 'tests'):
        export = subprocess.run(['xcrun', 'xcresulttool', 'get', 'test-results', kind,
                                 '--path', str(result), '--format', 'json'], capture_output=True, text=True)
        if export.returncode == 0:
            (ROOT / f'{label}-{kind}.json').write_text(export.stdout)
        else:
            (ROOT / f'{label}-{kind}-error.txt').write_text(export.stderr)
    return dict(label=label, variant=variant, exitCode=code, wallSeconds=seconds)


records = []
for variant in ('baseline', 'optimized'):
    method = 'testBaselineVariantInjection' if variant == 'baseline' else 'testOptimizedVariantInjection'
    record = run('injection-' + variant, variant,
                 ['-only-testing:striusUITests/CIBenchmarkModeUITests/' + method])
    records.append(record)
    if record['exitCode']:
        sys.exit('Benchmark variant injection failed; refusing to compare identical modes')
records.append(run('unit', 'baseline', ['-only-testing:striusTests']))
for index, variant in enumerate(('baseline', 'optimized', 'optimized', 'baseline'), 1):
    records.append(run(f'{index}-{variant}', variant,
                       ['-only-testing:striusUITests/' + test for test in TESTS]))
    (ROOT / 'measurements.json').write_text(json.dumps(dict(
        commit=os.environ['GITHUB_SHA'], sourceCommit='d3fe8a59acffe7fe21f87941e6f9863047813e8e',
        scope='five UI methods; same assertions after setup, ABBA; no selective skipping',
        tests=TESTS, runs=records), indent=2))

with open(os.environ['GITHUB_STEP_SUMMARY'], 'a') as summary:
    summary.write('## Paired UI cost experiment\n\nSame binary and simulator, ABBA order. '
                  'Measures tail control and setup fixtures; not full-CI savings.\n\n'
                  '| Pass | Variant | Wall seconds | Exit |\n|---|---|---:|---:|\n')
    for record in records:
        summary.write(f"| {record['label']} | {record['variant']} | {record['wallSeconds']:.2f} | {record['exitCode']} |\n")
sys.exit(1 if any(record['exitCode'] for record in records) else 0)
