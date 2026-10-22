#!/usr/bin/env python3
"""Bounded, explicit selected-suite experiment; never changes production gates."""
import argparse
from datetime import datetime, timezone
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import time

ROOT = Path(__file__).resolve().parents[2]
PROBE = 'CIBenchmarkModeUITests/testOptimizedVariantInjection'


def now():
    return datetime.now(timezone.utc).isoformat()


def test_cases(nodes):
    for node in nodes:
        if node.get('nodeType') == 'Test Case':
            yield node
        else:
            yield from test_cases(node.get('children', []))


def choose(profile):
    decisions = json.loads((ROOT / 'docs/ci-experiments/ui-scope-decisions-20261022.json').read_text())
    matches = [p for p in decisions['profiles'] if p['id'] == profile]
    if len(matches) != 1:
        raise ValueError('Unknown or duplicated profile: ' + profile)
    selected = matches[0]['ui']
    if len(selected) != len(set(selected)):
        raise ValueError('Duplicate selection')
    sys.path.insert(0, str(ROOT / 'scripts/ci'))
    import ui_test_plan
    discovered = set(ui_test_plan.discover())
    if not set(selected + [PROBE]) <= discovered:
        raise ValueError('Selected/probe method missing in source')
    return selected


def split_ui(selected, count, durations, unit_seconds=71.7):
    """Separate VMs, with all units assigned only to VM 1; no Simulator clones."""
    if count < 1:
        raise ValueError('Invalid shard count')
    shards, loads = [[] for _ in range(count)], [unit_seconds] + [0.0] * (count - 1)
    for test in sorted(selected, key=lambda name: (-durations[name], name)):
        index = min(range(count), key=lambda i: (loads[i], i))
        shards[index].append(test)
        loads[index] += durations[test]
    return [sorted(tests) for tests in shards]


def validate_exports(summary, nodes, expected_unit, selected, include_unit=True, include_ui=True):
    expected_ui = {s + '()': 'Passed' for s in selected + [PROBE]} if include_ui else {}
    expected = {'striusTests': expected_unit if include_unit else {}, 'striusUITests': expected_ui}
    actual = {k: {} for k in expected}
    for case in test_cases(nodes.get('testNodes', [])):
        url = case.get('nodeIdentifierURL', '')
        target = next((k for k in actual if '/' + k + '/' in url), None)
        if target is None:
            raise ValueError('Unrecognized test target: ' + url)
        key = case['nodeIdentifier']
        if key in actual[target]:
            raise ValueError('Duplicate case: ' + target + '/' + key)
        actual[target][key] = case.get('result')
    for target in expected:
        if set(actual[target]) != set(expected[target]):
            raise ValueError(json.dumps({'target': target, 'missing': sorted(set(expected[target]) - set(actual[target])),
                                         'unexpected': sorted(set(actual[target]) - set(expected[target]))}))
        changed = {k: {'expected': v, 'actual': actual[target][k]} for k, v in expected[target].items()
                   if actual[target][k] != v}
        if changed:
            raise ValueError('Unexpected pass/skip/failure: ' + json.dumps(changed))
    count = sum(len(v) for v in expected.values())
    skipped = sum(v == 'Skipped' for group in expected.values() for v in group.values())
    if (summary.get('totalTestCount') != count or summary.get('failedTests') != 0
            or summary.get('skippedTests') != skipped or summary.get('passedTests') != count - skipped
            or summary.get('result') != 'Passed'):
        raise ValueError('Summary mismatch: ' + json.dumps(summary))
    return {'unit': len(actual['striusTests']), 'selectedUI': len(selected) if include_ui else 0,
            'probe': 1 if include_ui else 0, 'passed': count - skipped, 'skipped': skipped, 'failed': 0}


class Experiment:
    def __init__(self, args):
        self.args = args
        self.out = Path(os.environ['RUNNER_TEMP']) / 'ci-selected'
        self.out.mkdir(parents=True, exist_ok=True)
        self.start = time.monotonic()
        self.data = {'startedAt': now(), 'commit': os.environ['GITHUB_SHA'],
                     'sourceCommit': 'd3fe8a59acffe7fe21f87941e6f9863047813e8e',
                     'runId': os.environ['GITHUB_RUN_ID'], 'configuration': args.configuration,
                     'profile': args.profile, 'warm': args.warm, 'commands': args.commands,
                     'phases': [], 'status': 'running', 'retries': 0,
                     'limitation': 'Explicit scenario profile, not an implemented automatic impact graph.'}
        self.selected = choose(args.profile)
        all_selected = list(self.selected)
        self.shards = getattr(args, 'ui_shards', 1)
        self.shard = getattr(args, 'ui_shard', 1)
        self.units = getattr(args, 'units', 'all')
        if not 1 <= self.shard <= self.shards:
            raise ValueError('Invalid shard number')
        if self.shards > 1:
            if self.units != ('all' if self.shard == 1 else 'none'):
                raise ValueError('Only VM 1 must execute the entire unit suite')
            decisions = json.loads((ROOT / 'docs/ci-experiments/ui-scope-decisions-20261022.json').read_text())
            durations = {r['test']: r['mockWarmTestBodyMeanSeconds'] for r in decisions['cases']}
            self.selected = split_ui(self.selected, self.shards, durations)[self.shard - 1]
        if not self.selected and self.units == 'none':
            raise ValueError('Refuse an empty VM')
        self.expected_unit = json.loads((ROOT / 'scripts/ci/selected_unit_inventory.json').read_text())['expectedUnitCases']
        self.data['selection'] = {'selected': self.selected, 'fullProfile': all_selected,
                                  'shard': self.shard, 'shards': self.shards,
                                  'probe': PROBE if self.selected else None,
                                  'unitExpected': len(self.expected_unit) if self.units == 'all' else 0,
                                  'omitted': [r['test'] for r in json.loads((ROOT / 'docs/ci-experiments/ui-scope-decisions-20261022.json').read_text())['cases']
                                              if r['test'] not in self.selected]}
        self.save()

    def save(self):
        (self.out / 'measurement.json').write_text(json.dumps(self.data, ensure_ascii=False, indent=2) + '\n')

    def run(self, label, cmd, timeout=720, env=None):
        begin = time.monotonic()
        entry = {'label': label, 'startedAt': now(), 'command': cmd}
        self.data['phases'].append(entry)
        self.save()
        print('SELECTED_START ' + label, flush=True)
        with (self.out / (label + '.log')).open('w') as log:
            process = subprocess.Popen(cmd, stdout=log, stderr=subprocess.STDOUT, env=env,
                                       start_new_session=True)
            try:
                code = process.wait(timeout=timeout)
            except subprocess.TimeoutExpired:
                entry['timedOut'] = True
                os.killpg(process.pid, signal.SIGTERM)
                try:
                    process.wait(timeout=15)
                except subprocess.TimeoutExpired:
                    os.killpg(process.pid, signal.SIGKILL)
                    process.wait()
                code = 124
        entry.update(exitCode=code, wallSeconds=time.monotonic() - begin, finishedAt=now())
        self.save()
        print('SELECTED_END ' + json.dumps(entry), flush=True)
        if code:
            tail = (self.out / (label + '.log')).read_text(errors='replace').splitlines()[-70:]
            print('\n'.join(tail), flush=True)
            raise RuntimeError(label + ' failed with exit code ' + str(code))
        return entry

    def measure_tests(self, label, include_unit, include_ui):
        result = self.out / (label + '.xcresult')
        command = ['xcodebuild', 'test-without-building', '-project', 'strius.xcodeproj', '-scheme', 'strius',
                   '-destination', 'id=' + self.udid, '-derivedDataPath', self.derived,
                   '-parallel-testing-enabled', 'NO', '-collect-test-diagnostics', 'never',
                   '-test-timeouts-enabled', 'YES', '-default-test-execution-time-allowance', '180',
                   '-maximum-test-execution-time-allowance', '600', '-resultBundlePath', str(result),
                   'ARCHS=arm64', 'STRUIS_AUTH_REQUIRED=YES']
        if include_unit:
            command.append('-only-testing:striusTests')
        if include_ui:
            command += ['-only-testing:striusUITests/' + s for s in self.selected + [PROBE]]
        if not include_unit and not include_ui:
            raise ValueError('Refuse empty xcodebuild test filter')
        error = None
        try:
            record = self.run(label, command, timeout=780)
        except RuntimeError as e:
            error = e
            record = self.data['phases'][-1]
        exports = {}
        for kind in ['summary', 'tests']:
            output = subprocess.run(['xcrun', 'xcresulttool', 'get', 'test-results', kind,
                                     '--path', str(result), '--format', 'json'],
                                    capture_output=True, text=True, timeout=90)
            (self.out / (label + '-' + kind + ('.json' if output.returncode == 0 else '-error.txt'))).write_text(
                output.stdout if output.returncode == 0 else output.stderr)
            if output.returncode == 0:
                exports[kind] = json.loads(output.stdout)
        if 'summary' in exports:
            record['counts'] = {k: exports['summary'].get(k) for k in
                                ['totalTestCount', 'passedTests', 'skippedTests', 'failedTests', 'result']}
        self.save()
        if error:
            raise error
        if set(exports) != {'summary', 'tests'}:
            raise RuntimeError('Missing xcresult export')
        record['validated'] = validate_exports(exports['summary'], exports['tests'], self.expected_unit,
                                                self.selected, include_unit, include_ui)
        self.save()

    def execute(self):
        self.derived = os.environ['RUNNER_TEMP'] + '/DerivedData'
        self.run('build', ['xcodebuild', 'build-for-testing', '-project', 'strius.xcodeproj',
                          '-scheme', 'strius', '-destination', 'platform=iOS Simulator,name=iPhone 17',
                          '-derivedDataPath', self.derived, 'ARCHS=arm64', 'STRUIS_AUTH_REQUIRED=YES'])
        listing = json.loads(subprocess.check_output(['xcrun', 'simctl', 'list', 'devices', 'available', '-j'], text=True))
        candidates = [(runtime, d) for runtime, devices in listing['devices'].items() if '.iOS-' in runtime
                      for d in devices if d['name'] == 'iPhone 17']
        candidates.sort(key=lambda pair: [int(x) for x in pair[0].rsplit('.iOS-', 1)[1].split('-')])
        if not candidates:
            raise RuntimeError('iPhone 17 missing')
        device = candidates[-1][1]
        self.udid = device['udid']
        self.data['simulator'] = {'udid': self.udid, 'initialState': device['state'], 'runtime': candidates[-1][0]}
        if device['state'] != 'Booted':
            self.run('sim-boot-request', ['xcrun', 'simctl', 'boot', self.udid], timeout=120)
        self.run('sim-boot-ready', ['xcrun', 'simctl', 'bootstatus', self.udid, '-b'], timeout=240)
        if self.args.warm == 'mock':
            app = self.derived + '/Build/Products/Debug-iphonesimulator/strius.app'
            bundle = subprocess.check_output(['/usr/libexec/PlistBuddy', '-c', 'Print :CFBundleIdentifier',
                                              app + '/Info.plist'], text=True).strip()
            self.run('warm-install', ['xcrun', 'simctl', 'install', self.udid, app], timeout=240)
            env = dict(os.environ, SIMCTL_CHILD_STRUIS_DEVICE_RUNTIME='0', SIMCTL_CHILD_STRUIS_DEVICE_TURNS='mock')
            self.run('warm-launch', ['xcrun', 'simctl', 'launch', self.udid, bundle, '-skip-onboarding'], env=env, timeout=240)
            begin = time.monotonic()
            container = subprocess.check_output(['xcrun', 'simctl', 'get_app_container', self.udid, bundle, 'data'], text=True).strip()
            ready = Path(container) / 'Library/Application Support/Struis'
            while not ready.is_dir() and time.monotonic() - begin < 240:
                time.sleep(1)
            if not ready.is_dir():
                raise RuntimeError('Warm-up never initialized learner data')
            time.sleep(5)
            self.data['phases'].append({'label': 'warm-data-ready', 'wallSeconds': time.monotonic() - begin,
                                        'exitCode': 0, 'finishedAt': now()})
            self.run('warm-terminate', ['xcrun', 'simctl', 'terminate', self.udid, bundle], timeout=30)
        if self.args.commands == 'combined':
            self.measure_tests('combined', self.units == 'all', bool(self.selected))
        else:
            if self.units == 'all':
                self.measure_tests('unit', True, False)
            if self.selected:
                self.measure_tests('ui', False, True)
        self.data.update(status='success', decisionReadyAt=now(), harnessElapsedSeconds=time.monotonic() - self.start)
        self.save()
        print('SELECTED_READY ' + json.dumps({k: self.data[k] for k in
              ['configuration', 'status', 'decisionReadyAt', 'harnessElapsedSeconds']}), flush=True)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--profile', default='reply_tail_contract')
    parser.add_argument('--warm', choices=['none', 'mock'], required=True)
    parser.add_argument('--commands', choices=['combined', 'separate'], required=True)
    parser.add_argument('--configuration', required=True)
    parser.add_argument('--ui-shards', type=int, default=1)
    parser.add_argument('--ui-shard', type=int, default=1)
    parser.add_argument('--units', choices=['all', 'none'], default='all')
    args = parser.parse_args()
    experiment = Experiment(args)
    try:
        experiment.execute()
    except Exception as error:
        experiment.data.update(status='failure', error=str(error), finishedAt=now(),
                               harnessElapsedSeconds=time.monotonic() - experiment.start)
        experiment.save()
        raise


if __name__ == '__main__':
    main()
