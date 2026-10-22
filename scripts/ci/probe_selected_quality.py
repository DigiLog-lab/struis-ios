#!/usr/bin/env python3
"""Check two concrete regressions against existing fast integration tests.

Mutations exist only in this job's working tree and are restored in finally.
An expected mutant assertion failure is recorded as detection, never as an app pass.
"""
from argparse import Namespace
import difflib
import json
import os
from pathlib import Path
import subprocess
import time

from benchmark_selected import Experiment, now, validate_exports, test_cases


MUTANTS = [
    {'id': 'tail-input-becomes-busy', 'path': 'strius/Features/Chat/ChatStore.swift',
     'old': 'var isReplyBusy: Bool { isSending && !replyFinishingInBackground }',
     'new': 'var isReplyBusy: Bool { isSending }',
     'test': 'ReplyTailQueueTests/testSendDuringPrivateTailQueuesWithoutStoppingTheRecord',
     'message': '記録だけを書いている間は入力欄を停止ボタンにしない'},
    {'id': 'partial-set-closes-early', 'path': 'strius/Engine/WorkbookRules.swift',
     'old': 'if isOpenForCapture(setRow), !missing.isEmpty {',
     'new': 'if isOpenForCapture(setRow), !missing.isEmpty, false {',
     'test': 'WorkbookRulesTests/testSetCapturedInThreePhotosIsGradedAsOneSet',
     'message': '1 枚目で一枚を締めた'},
]


def unit_command(experiment, label, tests):
    return ['xcodebuild', 'test-without-building', '-project', 'strius.xcodeproj', '-scheme', 'strius',
            '-destination', 'id=' + experiment.udid, '-derivedDataPath', experiment.derived,
            '-parallel-testing-enabled', 'NO', '-collect-test-diagnostics', 'never',
            '-test-timeouts-enabled', 'YES', '-default-test-execution-time-allowance', '120',
            '-maximum-test-execution-time-allowance', '180', '-resultBundlePath', str(experiment.out / (label + '.xcresult')),
            'ARCHS=arm64', 'STRUIS_AUTH_REQUIRED=YES'] + ['-only-testing:striusTests/' + test for test in tests]


def results(experiment, label):
    exports = {}
    for kind in ['summary', 'tests']:
        output = subprocess.run(['xcrun', 'xcresulttool', 'get', 'test-results', kind,
                                 '--path', str(experiment.out / (label + '.xcresult')), '--format', 'json'],
                                capture_output=True, text=True, timeout=90)
        (experiment.out / (label + '-' + kind + ('.json' if output.returncode == 0 else '-error.txt'))).write_text(
            output.stdout if output.returncode == 0 else output.stderr)
        if output.returncode:
            raise RuntimeError('Cannot export ' + label + '/' + kind)
        exports[kind] = json.loads(output.stdout)
    return exports


def build(experiment, label):
    experiment.run(label, ['xcodebuild', 'build-for-testing', '-project', 'strius.xcodeproj', '-scheme', 'strius',
                          '-destination', 'platform=iOS Simulator,name=iPhone 17', '-derivedDataPath', experiment.derived,
                          '-only-testing:striusTests', 'ARCHS=arm64', 'STRUIS_AUTH_REQUIRED=YES'], timeout=720)


def main():
    experiment = Experiment(Namespace(profile='grading_boundary_logic_only', warm='none', commands='combined',
                                      configuration='fast-regression-detection-probe'))
    experiment.data.update(purpose='Quality comparison only; not a timed merge gate',
                           mutations=[], selection={'unit': [m['test'] for m in MUTANTS], 'ui': []})
    experiment.derived = os.environ['RUNNER_TEMP'] + '/DerivedData'
    originals = {m['path']: Path(m['path']).read_text() for m in MUTANTS}
    try:
        for mutant in MUTANTS:
            if originals[mutant['path']].count(mutant['old']) != 1:
                raise RuntimeError('Mutation anchor is not unique: ' + mutant['id'])
        build(experiment, 'baseline-build')
        devices = json.loads(subprocess.check_output(['xcrun', 'simctl', 'list', 'devices', 'available', '-j'], text=True))
        candidates = [(runtime, d) for runtime, ds in devices['devices'].items() if '.iOS-' in runtime
                      for d in ds if d['name'] == 'iPhone 17']
        candidates.sort(key=lambda item: [int(x) for x in item[0].rsplit('.iOS-', 1)[1].split('-')])
        device = candidates[-1][1]
        experiment.udid = device['udid']
        if device['state'] != 'Booted':
            experiment.run('boot-request', ['xcrun', 'simctl', 'boot', experiment.udid], timeout=120)
        experiment.run('boot-ready', ['xcrun', 'simctl', 'bootstatus', experiment.udid, '-b'], timeout=240)
        experiment.run('baseline-fast-tests', unit_command(experiment, 'baseline-fast-tests', [m['test'] for m in MUTANTS]), timeout=300)
        exports = results(experiment, 'baseline-fast-tests')
        experiment.data['baseline'] = validate_exports(exports['summary'], exports['tests'],
            {m['test'] + '()': 'Passed' for m in MUTANTS}, [], include_ui=False)
        experiment.save()
        for mutant in MUTANTS:
            path = Path(mutant['path'])
            changed = originals[mutant['path']].replace(mutant['old'], mutant['new'], 1)
            (experiment.out / (mutant['id'] + '.patch')).write_text(''.join(difflib.unified_diff(
                originals[mutant['path']].splitlines(True), changed.splitlines(True),
                fromfile=mutant['path'], tofile=mutant['path'])))
            path.write_text(changed)
            try:
                build(experiment, mutant['id'] + '-build')
                label = mutant['id'] + '-test'
                try:
                    experiment.run(label, unit_command(experiment, label, [mutant['test']]), timeout=240)
                except RuntimeError:
                    pass
                record = experiment.data['phases'][-1]
                exports = results(experiment, label)
                cases = list(test_cases(exports['tests']['testNodes']))
                summary = exports['summary']
                messages = json.dumps(summary.get('testFailures', []), ensure_ascii=False)
                detected = (record['exitCode'] != 0 and not record.get('timedOut')
                            and len(cases) == 1 and cases[0].get('nodeIdentifier') == mutant['test'] + '()'
                            and cases[0].get('result') == 'Failed' and summary.get('failedTests') == 1
                            and mutant['message'] in messages and 'XCTAssert' in messages)
                experiment.data['mutations'].append({'id': mutant['id'], 'test': mutant['test'],
                    'detectedByExpectedAssertion': detected, 'commandExitCode': record['exitCode'],
                    'counts': {k: summary.get(k) for k in ['totalTestCount', 'passedTests', 'skippedTests', 'failedTests']},
                    'failureMessages': summary.get('testFailures', [])})
                experiment.save()
                if not detected:
                    raise RuntimeError('Mutant survived, failed for another reason, or was not executed: ' + mutant['id'])
            finally:
                path.write_text(originals[mutant['path']])
        experiment.data.update(status='mutation-probes-complete', finishedAt=now(),
                               restoredSources=True, detectedDefects=2,
                               harnessElapsedSeconds=time.monotonic() - experiment.start)
    except Exception as error:
        experiment.data.update(status='failure', error=str(error), finishedAt=now())
        raise
    finally:
        for path, text in originals.items():
            Path(path).write_text(text)
        experiment.data['restoredSources'] = all(Path(path).read_text() == text for path, text in originals.items())
        experiment.save()
        print('QUALITY_PROBE ' + json.dumps(experiment.data, ensure_ascii=False), flush=True)


if __name__ == '__main__':
    main()
