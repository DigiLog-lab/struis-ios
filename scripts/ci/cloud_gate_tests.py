#!/usr/bin/env python3
"""PR Gate on one Xcode Cloud machine.

Runs on the build machine of the PR Gate workflow's BUILD action (from
``ci_pre_xcodebuild.sh``): builds the ``StruisPRGate`` scheme for testing and
runs its test plan on simulators of the same machine, so there is no hand-off
to a separate test machine and no TEST action post-processing to wait for.

The longest UI test class runs alone on its own simulator from the start; the
other tests run in parallel on clones of a second simulator. Every test's
result is printed as ``STRUIS_GATE_TEST<TAB>result<TAB>identifier`` for the
gate controller, which compares the list with the tests the gate requires.
The exit status is non-zero when a build or a test failed, which fails the
Xcode Cloud action.

Runs with the system ``python3`` (3.9): no newer syntax.
"""
import json
import os
import re
import subprocess
import sys
import time
from pathlib import Path

SCHEME = 'StruisPRGate'
TEST_PLAN = 'PRGate'
UI_TARGET = 'striusUITests'
# Classes that set the floor of the UI phase. Each starts at once on a
# simulator of its own instead of waiting for a free parallel worker.
SOLO_CLASSES = ('WorkbookLongConversationUITests',)
MARK = 'STRUIS_GATE_TEST'
# Same as the gate controller: anything else (an expected failure too) is not green.
PASSING = ('Passed', 'Skipped')
DEVICE_TYPE = 'iPhone 16'
# Same limits as the Xcode Cloud TEST action (its xcodebuild invocation).
TIMEOUT_FLAGS = ['-test-timeouts-enabled', 'YES', '-maximum-test-execution-time-allowance', '1800']


def log(message):
    print(message, flush=True)


def stage(name, started):
    log(f'STRUIS_STAGE_END name={name} elapsed_seconds={int(time.time() - started)}')


def selected_tests(plan):
    """``Class/method`` names the test plan selects in the UI target, or None when it runs the whole target."""
    for entry in plan.get('testTargets', []):
        if (entry.get('target') or {}).get('name') != UI_TARGET or entry.get('enabled') is False:
            continue
        selected = entry.get('selectedTests')
        if selected is None:
            return None
        skipped = set(entry.get('skippedTests') or [])
        return [name for name in selected if name not in skipped]
    return []


def solo_classes(plan):
    """The solo classes this plan actually runs (an empty selection must not start a solo run)."""
    tests = selected_tests(plan)
    if tests is None:
        return list(SOLO_CLASSES)
    present = {name.split('/', 1)[0] for name in tests}
    return [name for name in SOLO_CLASSES if name in present]


def test_rows(tree):
    """Test cases of ``xcresulttool get test-results tests`` (the same walk as scripts/agent/delivery.py)."""
    rows = []

    def visit(node):
        if isinstance(node, list):
            for child in node:
                visit(child)
        elif isinstance(node, dict):
            if node.get('nodeType') == 'Test Case':
                failures = [child.get('name', '') for child in node.get('children', [])
                            if isinstance(child, dict) and child.get('nodeType') == 'Failure Message']
                rows.append({'test': node.get('nodeIdentifier') or node.get('name'),
                             'result': node.get('result'), 'failures': failures})
            else:
                visit(node.get('testNodes', node.get('children', [])))

    visit(tree)
    return rows


def result_lines(rows):
    clean = lambda value: re.sub(r'[\t\r\n]+', ' ', str(value or ''))
    return [f'{MARK}\t{clean(row["result"])}\t{clean(row["test"])}' for row in rows]


def verdict(exit_codes, rows):
    """True only when every xcodebuild succeeded and every test case passed or was skipped."""
    if not rows or any(code != 0 for code in exit_codes):
        return False
    return all(row.get('result') in PASSING for row in rows)


def worker_count(cpus, solo):
    """Parallel UI workers next to the solo simulators: leave cores for xcodebuild, the runners and the host."""
    configured = os.environ.get('STRUIS_GATE_WORKERS')
    if configured:
        return max(1, int(configured))
    return max(2, min(8, cpus - 4) - solo)


def latest_ios_runtime():
    runtimes = json.loads(subprocess.check_output(['xcrun', 'simctl', 'list', 'runtimes', '-j']))['runtimes']
    available = [item for item in runtimes if item.get('platform') == 'iOS' and item.get('isAvailable')]
    if not available:
        raise SystemExit('No available iOS simulator runtime on this machine')
    version = lambda item: tuple(int(part) for part in re.findall(r'\d+', item.get('version', '0')))
    return max(available, key=version)['identifier']


def create_device(name, runtime):
    return subprocess.check_output(['xcrun', 'simctl', 'create', name, DEVICE_TYPE, runtime], text=True).strip()


def prewarm(parallel_device, solo_devices, output):
    """Boot each new simulator once while the build runs (the first boot migrates its data). The parallel run's
    device is shut down again, because xcodebuild clones it for the workers; a solo device stays booted."""
    steps = [f'xcrun simctl boot {parallel_device} && xcrun simctl bootstatus {parallel_device} -b && xcrun simctl shutdown {parallel_device}']
    steps += [f'xcrun simctl boot {device} && xcrun simctl bootstatus {device} -b' for device in solo_devices]
    handle = open(output, 'w')
    return [subprocess.Popen(['/bin/sh', '-c', step], stdout=handle, stderr=subprocess.STDOUT) for step in steps], handle


def xcodebuild(arguments, output):
    """Start xcodebuild with its (long) output in a file; the Cloud log keeps only summaries."""
    handle = open(output, 'w')
    return subprocess.Popen(['xcodebuild', *arguments], stdout=handle, stderr=subprocess.STDOUT), handle


def report_log(path, failed):
    """Lines worth keeping in the Cloud log: diagnostics, and errors when something failed."""
    keep = re.compile(r'UI_DIAGNOSTICS|Test session results|\*\* TEST|error:|Testing failed|Restarting after unexpected exit')
    with open(path, errors='replace') as handle:
        lines = handle.readlines()
    # Copied lines are indented: the gate controller reads only lines that start with this script's marks,
    # so nothing a test prints can add a result.
    for line in lines:
        if keep.search(line):
            log('  ' + line.rstrip()[:2000])
    if failed:
        log(f'--- last lines of {Path(path).name} ---')
        for line in lines[-80:]:
            log('  ' + line.rstrip()[:2000])


def export(bundle):
    data = subprocess.check_output(['xcrun', 'xcresulttool', 'get', 'test-results', 'tests', '--path', str(bundle), '--format', 'json'])
    return test_rows(json.loads(data))


def main():
    repository = Path(os.environ['CI_PRIMARY_REPOSITORY_PATH'])
    derived = os.environ.get('CI_DERIVED_DATA_PATH') or str(repository.parent / 'DerivedData')
    work = Path(os.environ.get('STRUIS_GATE_WORK') or (repository.parent / 'tmp' / 'struis-gate'))
    work.mkdir(parents=True, exist_ok=True)
    products = work / 'TestProducts.xctestproducts'
    plan = json.loads((repository / 'TestPlans' / f'{TEST_PLAN}.xctestplan').read_text())
    solos = solo_classes(plan)
    cpus = os.cpu_count() or 4
    workers = worker_count(cpus, len(solos))
    log(f'STRUIS_GATE_PLAN cpus={cpus} workers={workers} solo={",".join(solos) or "-"}')

    started = time.time()
    runtime = latest_ios_runtime()
    parallel_device = create_device('struis-gate-parallel', runtime)
    solo_devices = [create_device(f'struis-gate-{name}', runtime) for name in solos]
    log(f'STRUIS_GATE_DEVICES runtime={runtime} parallel={parallel_device} solo={",".join(solo_devices) or "-"}')
    stage('gate-simulators', started)

    started = time.time()
    warming, warm_log = prewarm(parallel_device, solo_devices, work / 'prewarm.log')
    common = ['-project', str(repository / 'strius.xcodeproj'), '-scheme', SCHEME, '-testPlan', TEST_PLAN]
    build, handle = xcodebuild([
        'build-for-testing', *common, '-destination', f'platform=iOS Simulator,id={parallel_device}',
        '-derivedDataPath', derived, '-testProductsPath', str(products), '-quiet',
    ], work / 'build-for-testing.log')
    code = build.wait()
    handle.close()
    stage('gate-build-for-testing', started)
    warm_codes = [process.wait() for process in warming]
    warm_log.close()
    stage('gate-prewarm', started)
    if any(warm_codes):
        # Not fatal: xcodebuild boots the simulators itself, only later.
        report_log(work / 'prewarm.log', failed=True)
    if code != 0:
        report_log(work / 'build-for-testing.log', failed=True)
        log(f'STRUIS_GATE_RESULT ok=false reason=build-for-testing exit={code}')
        return 1

    started = time.time()
    runs = []
    skip = [f'-skip-testing:{UI_TARGET}/{name}' for name in solos]
    runs.append(('parallel', work / 'parallel.xcresult', xcodebuild([
        'test-without-building', '-testProductsPath', str(products),
        '-destination', f'platform=iOS Simulator,id={parallel_device}',
        '-parallel-testing-enabled', 'YES', '-parallel-testing-worker-count', str(workers),
        '-resultBundlePath', str(work / 'parallel.xcresult'), *TIMEOUT_FLAGS, *skip,
    ], work / 'parallel.log')))
    for name, device in zip(solos, solo_devices):
        runs.append((name, work / f'{name}.xcresult', xcodebuild([
            'test-without-building', '-testProductsPath', str(products),
            '-destination', f'platform=iOS Simulator,id={device}', '-parallel-testing-enabled', 'NO',
            '-resultBundlePath', str(work / f'{name}.xcresult'), *TIMEOUT_FLAGS,
            f'-only-testing:{UI_TARGET}/{name}',
        ], work / f'{name}.log')))
    codes, rows = [], []
    for name, bundle, (process, handle) in runs:
        code = process.wait()
        handle.close()
        codes.append(code)
        log(f'STRUIS_GATE_RUN name={name} exit={code} elapsed_seconds={int(time.time() - started)}')
        report_log(work / f'{name}.log', failed=code != 0)
        try:
            found = export(bundle)
        except (subprocess.CalledProcessError, OSError, ValueError) as error:
            log(f'STRUIS_GATE_EXPORT name={name} error={error}')
            codes.append(1)
            continue
        rows.extend(found)
        for row in found:
            for failure in row['failures']:
                log(f'STRUIS_GATE_FAILURE\t{row["test"]}\t' + re.sub(r'[\r\n]+', ' | ', failure)[:1500])
    stage('gate-tests', started)
    for line in result_lines(rows):
        log(line)
    ok = verdict(codes, rows)
    log(f'STRUIS_GATE_RESULT ok={str(ok).lower()} tests={len(rows)} exits={",".join(map(str, codes))}')
    return 0 if ok else 1


if __name__ == '__main__':
    sys.exit(main())
