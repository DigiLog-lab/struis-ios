#!/usr/bin/env python3
"""Bounded overnight benchmark; outputs evidence even after test failure."""
import fnmatch
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import time

ROOT = Path(__file__).resolve().parents[2]
OUT = Path(os.environ['RUNNER_TEMP']) / 'ci-overnight'
OUT.mkdir(exist_ok=True)
VARIANT = os.environ['BENCH_VARIANT']
WORKERS = int(os.environ['BENCH_WORKERS'])
os.environ['TEST_RUNNER_STRUIS_CI_BENCH_VARIANT'] = VARIANT
os.environ['TEST_RUNNER_STRUIS_PROBE_DIR'] = str(OUT / 'ui-probe')
records = []


def save():
    (OUT / 'measurements.json').write_text(json.dumps({
        'sourceCommit': 'd3fe8a59acffe7fe21f87941e6f9863047813e8e',
        'commit': os.environ['GITHUB_SHA'],
        'configuration': os.environ['BENCH_CONFIG'],
        'repetition': os.environ['BENCH_REPETITION'],
        'variant': VARIANT, 'workers': WORKERS,
        'runs': records,
        'scope': 'All existing gate-eligible UI methods, plus all unit tests. No changed-file skipping in executions.',
    }, indent=2))


def run(label, arguments, budget=2700):
    started = time.monotonic()
    result = OUT / (label + '.xcresult')
    cmd = ['xcodebuild', 'test-without-building', '-project', 'strius.xcodeproj',
           '-scheme', 'strius', '-destination', 'id=' + os.environ['SIMULATOR_UDID'],
           '-derivedDataPath', os.environ['RUNNER_TEMP'] + '/DerivedData',
           '-resultBundlePath', str(result), '-collect-test-diagnostics', 'never',
           '-test-timeouts-enabled', 'YES', '-default-test-execution-time-allowance', '180',
           '-maximum-test-execution-time-allowance', '600',
           'ARCHS=arm64', 'STRUIS_AUTH_REQUIRED=YES'] + arguments
    print('COMMAND ' + json.dumps(cmd), flush=True)
    timeout = False
    with (OUT / (label + '.log')).open('w') as log:
        proc = subprocess.Popen(cmd, stdout=log, stderr=subprocess.STDOUT)
        with (OUT / (label + '.log')).open() as live:
            while proc.poll() is None:
                for line in live:
                    if any(w in line for w in ('Test Case', 'error:', 'TEST ', 'failed')):
                        print(line.rstrip(), flush=True)
                if time.monotonic() - started > budget:
                    timeout = True
                    proc.terminate()
                    try:
                        proc.wait(timeout=15)
                    except subprocess.TimeoutExpired:
                        proc.kill()
                    break
                time.sleep(1)
        code = proc.wait()
    record = {'label': label, 'wallSeconds': time.monotonic() - started,
              'exitCode': code, 'budgetExceeded': timeout}
    records.append(record)
    save()
    print('OVERNIGHT ' + json.dumps(record), flush=True)
    for kind in ('summary', 'tests'):
        export = subprocess.run(['xcrun', 'xcresulttool', 'get', 'test-results', kind,
                                 '--path', str(result), '--format', 'json'],
                                capture_output=True, text=True, timeout=90)
        (OUT / (label + '-' + kind + ('.json' if export.returncode == 0 else '-error.txt'))).write_text(
            export.stdout if export.returncode == 0 else export.stderr)
    summary_path = OUT / (label + '-summary.json')
    expected = len(eligible) if label == 'ui' else 1 if label == 'injection' else None
    if not summary_path.exists():
        record['validationError'] = 'Missing xcresult summary'
    else:
        counts = json.loads(summary_path.read_text())
        record['counts'] = {k: counts.get(k) for k in (
            'totalTestCount', 'passedTests', 'skippedTests', 'failedTests', 'result')}
        if not counts.get('totalTestCount') or (expected is not None and counts['totalTestCount'] != expected):
            record['validationError'] = 'Missing or unexpected test count'
    if record.get('validationError'):
        record['exitCode'] = code or 97
    save()
    return record['exitCode']


# Use the repository's authoritative discovery and gate exclusion manifest.
import sys
sys.path.insert(0, str(ROOT / 'scripts/ci'))
import ui_test_plan as planner
import xcode_test_plan as cloud
all_tests = [t for t in planner.discover() if not t.startswith('CIBenchmarkModeUITests/')]
exclusions = cloud.exclusions_for(all_tests, json.loads(cloud.EXCLUSIONS.read_text()))
eligible = sorted(set(all_tests) - set(exclusions))
(OUT / 'selection.json').write_text(json.dumps({
    'allDiscovered': all_tests, 'selected': eligible,
    'excluded': list(exclusions.values()),
    'experimentalProbes': 'Run separately; only the probe matching the configured mode.',
}, ensure_ascii=False, indent=2))
if not eligible:
    raise SystemExit('Empty eligible test selection')
save()

# Shadow audit only: do not skip actual tests using this analysis.
plan = json.loads(planner.PLAN.read_text())
tracked = subprocess.check_output(['git', 'ls-files'], text=True).splitlines()
production = [p for p in tracked if p.startswith('strius/') and p.endswith('.swift')]
unmapped = [p for p in production if not any(fnmatch.fnmatch(p, g) for g in plan.get('paths', {}))]
commits = subprocess.check_output(['git', 'rev-list', '--max-count=20',
    'd3fe8a59acffe7fe21f87941e6f9863047813e8e'], text=True).splitlines()
history = []
for commit in commits:
    changed = subprocess.check_output(['git', 'diff-tree', '--root', '--no-commit-id',
        '--name-only', '-r', commit], text=True).splitlines()
    current = sorted(set(planner.select(all_tests, plan, 'pr', changed)) & set(eligible))
    missing = [p for p in changed if p.startswith('strius/') and
               not any(fnmatch.fnmatch(p, g) for g in plan.get('paths', {}))]
    conservative = eligible if missing else current
    history.append({'commit': commit, 'changed': changed, 'currentSelectedCount': len(current),
                    'unmappedProductionChanges': missing,
                    'conservativeSelectedCount': len(conservative)})
(OUT / 'selection-shadow.json').write_text(json.dumps({
    'fullEligibleCount': len(eligible), 'unmappedSwiftFiles': unmapped, 'recentChanges': history,
    'limitation': 'Path-map audit, not a verified semantic dependency graph or proof of safe omission.',
}, ensure_ascii=False, indent=2))

probe = 'testBaselineVariantInjection' if VARIANT == 'baseline' else 'testOptimizedVariantInjection'
if run('injection', ['-parallel-testing-enabled', 'NO',
    '-only-testing:striusUITests/CIBenchmarkModeUITests/' + probe], budget=240):
    raise SystemExit('Variant injection failed; no comparison permitted')
run('unit', ['-parallel-testing-enabled', 'NO', '-only-testing:striusTests'], budget=600)
parallel = ['-parallel-testing-enabled', 'NO'] if WORKERS == 1 else [
    '-parallel-testing-enabled', 'YES', '-maximum-concurrent-test-simulator-destinations', '2',
    '-parallel-testing-worker-count', '2']
run('ui', parallel + ['-only-testing:striusUITests/' + t for t in eligible])
with open(os.environ['GITHUB_STEP_SUMMARY'], 'a') as summary:
    summary.write('# Overnight CI experiment\n\nTarget: mean merge decision latency <= 600 seconds, including setup, queues and retries.\n\n')
    summary.write(json.dumps({'configuration': os.environ['BENCH_CONFIG'],
        'eligibleUI': len(eligible), 'measurements': records}, indent=2))
raise SystemExit(1 if any(r['exitCode'] for r in records) else 0)

