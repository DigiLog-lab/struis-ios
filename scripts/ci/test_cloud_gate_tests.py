import contextlib
import io
import json
import os
from pathlib import Path
import sys
import tempfile
import unittest
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parent))
import cloud_gate_tests
import xcode_test_plan

ROOT = Path(__file__).resolve().parents[2]


class PlanTests(unittest.TestCase):
    def test_solo_class_runs_only_when_the_plan_selects_it(self):
        plan = json.loads((ROOT / 'TestPlans' / 'PRGate.xctestplan').read_text())
        self.assertEqual(cloud_gate_tests.solo_classes(plan), ['WorkbookLongConversationUITests'])
        narrow, _ = xcode_test_plan.generate('pr', ['strius/Features/Chat/ChatView.swift'])
        tests = cloud_gate_tests.selected_tests(narrow)
        self.assertEqual(cloud_gate_tests.solo_classes(narrow),
                         ['WorkbookLongConversationUITests'] if any(t.startswith('WorkbookLongConversationUITests/') for t in tests) else [])
        empty = {'testTargets': [{'target': {'name': 'striusUITests'}, 'selectedTests': ['ChatCameraUITests/testCameraAndChatPreservation()']}]}
        self.assertEqual(cloud_gate_tests.solo_classes(empty), [])

    def test_whole_target_and_skipped_tests(self):
        whole = {'testTargets': [{'target': {'name': 'striusUITests'}}]}
        self.assertIsNone(cloud_gate_tests.selected_tests(whole))
        self.assertEqual(cloud_gate_tests.solo_classes(whole), list(cloud_gate_tests.SOLO_CLASSES))
        skipped = {'testTargets': [{'target': {'name': 'striusUITests'},
                                    'selectedTests': ['WorkbookLongConversationUITests/testLongSubunitConversationDoesNotFreeze()'],
                                    'skippedTests': ['WorkbookLongConversationUITests/testLongSubunitConversationDoesNotFreeze()']}]}
        self.assertEqual(cloud_gate_tests.solo_classes(skipped), [])
        disabled = {'testTargets': [{'target': {'name': 'striusUITests'}, 'enabled': False}]}
        self.assertEqual(cloud_gate_tests.selected_tests(disabled), [])


class ResultTests(unittest.TestCase):
    TREE = {'testNodes': [{'nodeType': 'Test Plan', 'children': [
        {'nodeType': 'Unit test bundle', 'name': 'striusUITests', 'children': [
            {'nodeType': 'Test Suite', 'name': 'ReplyTailUITests', 'children': [
                {'nodeType': 'Test Case', 'nodeIdentifier': 'ReplyTailUITests/testA()', 'result': 'Passed'},
                {'nodeType': 'Test Case', 'nodeIdentifier': 'ReplyTailUITests/testB()', 'result': 'Failed', 'children': [
                    {'nodeType': 'Failure Message', 'name': 'ReplyTailUITests.swift:10: XCTAssertTrue failed\n- 出ない'},
                    {'nodeType': 'Device', 'name': 'iPhone 16'}]},
                {'nodeType': 'Test Case', 'nodeIdentifier': 'ReplyTailUITests/testC()', 'result': 'Skipped'}]}]}]}]}

    def test_rows_lines_and_verdict(self):
        rows = cloud_gate_tests.test_rows(self.TREE)
        self.assertEqual([row['test'] for row in rows], ['ReplyTailUITests/testA()', 'ReplyTailUITests/testB()', 'ReplyTailUITests/testC()'])
        self.assertEqual(rows[1]['failures'], ['ReplyTailUITests.swift:10: XCTAssertTrue failed\n- 出ない'])
        self.assertEqual(cloud_gate_tests.result_lines(rows)[1], 'STRUIS_GATE_TEST\tFailed\tReplyTailUITests/testB()')
        self.assertFalse(cloud_gate_tests.verdict([0], rows))
        passing = [rows[0], rows[2]]
        self.assertTrue(cloud_gate_tests.verdict([0, 0], passing))
        # A failed xcodebuild, or no test at all, is never green.
        self.assertFalse(cloud_gate_tests.verdict([0, 65], passing))
        self.assertFalse(cloud_gate_tests.verdict([0], []))

    def test_lines_keep_one_field_per_tab(self):
        line = cloud_gate_tests.result_lines([{'test': 'A/b()\tx', 'result': 'Passed\n'}])[0]
        self.assertEqual(line.split('\t'), ['STRUIS_GATE_TEST', 'Passed ', 'A/b() x'])


class WorkerTests(unittest.TestCase):
    def test_worker_count(self):
        with mock.patch.dict('os.environ', {}, clear=True):
            self.assertEqual(cloud_gate_tests.worker_count(12, 1), 7)
            self.assertEqual(cloud_gate_tests.worker_count(4, 1), 2)
        with mock.patch.dict('os.environ', {'STRUIS_GATE_WORKERS': '5'}):
            self.assertEqual(cloud_gate_tests.worker_count(12, 1), 5)


class MainTests(unittest.TestCase):
    """The whole run with xcodebuild and simctl replaced: what is started, in which order, and what is printed."""

    def run_main(self, results, build_exit=0, test_exits=(0, 0), selected=None):
        root = Path(tempfile.mkdtemp())
        (root / 'repo' / 'TestPlans').mkdir(parents=True)
        tests = selected or ['WorkbookLongConversationUITests/testLongSubunitConversationDoesNotFreeze()', 'ReplyTailUITests/testA()']
        plan = {'testTargets': [{'target': {'name': 'striusTests'}}, {'target': {'name': 'striusUITests'}, 'selectedTests': tests}]}
        (root / 'repo' / 'TestPlans' / 'PRGate.xctestplan').write_text(json.dumps(plan))
        started = []
        exits = iter([build_exit, *test_exits])

        class Process:
            def __init__(self, command, stdout=None, stderr=None):
                self.command = command
                started.append(command)
                self.code = 0 if command[0] == '/bin/sh' else next(exits)

            def wait(self):
                return self.code

        def check_output(command, text=False):
            if command[:4] == ['xcrun', 'simctl', 'list', 'runtimes']:
                return json.dumps({'runtimes': [
                    {'platform': 'iOS', 'isAvailable': True, 'version': '26.4', 'identifier': 'ios-26-4'},
                    {'platform': 'iOS', 'isAvailable': True, 'version': '27.0', 'identifier': 'ios-27-0'},
                    {'platform': 'iOS', 'isAvailable': False, 'version': '28.0', 'identifier': 'ios-28-0'}]}).encode()
            if command[:3] == ['xcrun', 'simctl', 'create']:
                return f'UDID-{command[3]}\n'
            if command[:4] == ['xcrun', 'xcresulttool', 'get', 'test-results']:
                name = Path(command[command.index('--path') + 1]).stem
                return json.dumps({'testNodes': [{'nodeType': 'Test Case', 'nodeIdentifier': test, 'result': result}
                                                 for test, result in results[name]]}).encode()
            raise AssertionError(command)

        out = io.StringIO()
        environment = {'CI_PRIMARY_REPOSITORY_PATH': str(root / 'repo'), 'CI_DERIVED_DATA_PATH': str(root / 'dd'),
                       'STRUIS_GATE_WORK': str(root / 'work')}
        with mock.patch.dict(os.environ, environment), mock.patch.object(cloud_gate_tests.subprocess, 'Popen', Process), \
                mock.patch.object(cloud_gate_tests.subprocess, 'check_output', check_output), \
                mock.patch.object(cloud_gate_tests.os, 'cpu_count', return_value=12), contextlib.redirect_stdout(out):
            code = cloud_gate_tests.main()
        return code, started, out.getvalue().splitlines()

    def test_green_run_starts_the_long_class_alone_and_prints_every_result(self):
        results = {'parallel': [('ReplyTailUITests/testA()', 'Passed'), ('ChatStoreTests/testB()', 'Passed')],
                   'WorkbookLongConversationUITests': [('WorkbookLongConversationUITests/testLongSubunitConversationDoesNotFreeze()', 'Passed')]}
        code, started, lines = self.run_main(results)
        self.assertEqual(code, 0)
        builds = [command for command in started if command[0] == 'xcodebuild']
        self.assertEqual([command[1] for command in builds], ['build-for-testing', 'test-without-building', 'test-without-building'])
        self.assertIn('platform=iOS Simulator,id=UDID-struis-gate-parallel', builds[0])
        parallel, solo = builds[1], builds[2]
        self.assertEqual(parallel[parallel.index('-parallel-testing-worker-count') + 1], '7')
        self.assertIn('-skip-testing:striusUITests/WorkbookLongConversationUITests', parallel)
        self.assertIn('-only-testing:striusUITests/WorkbookLongConversationUITests', solo)
        self.assertIn('platform=iOS Simulator,id=UDID-struis-gate-WorkbookLongConversationUITests', solo)
        self.assertEqual([line for line in lines if line.startswith('STRUIS_GATE_TEST')], [
            'STRUIS_GATE_TEST\tPassed\tReplyTailUITests/testA()', 'STRUIS_GATE_TEST\tPassed\tChatStoreTests/testB()',
            'STRUIS_GATE_TEST\tPassed\tWorkbookLongConversationUITests/testLongSubunitConversationDoesNotFreeze()'])
        self.assertIn('STRUIS_GATE_RESULT ok=true tests=3 exits=0,0', lines)
        self.assertIn('STRUIS_GATE_DEVICES runtime=ios-27-0 parallel=UDID-struis-gate-parallel solo=UDID-struis-gate-WorkbookLongConversationUITests', lines)

    def test_a_failed_test_or_xcodebuild_fails_the_action(self):
        results = {'parallel': [('ReplyTailUITests/testA()', 'Failed')],
                   'WorkbookLongConversationUITests': [('WorkbookLongConversationUITests/testLongSubunitConversationDoesNotFreeze()', 'Passed')]}
        code, _, lines = self.run_main(results, test_exits=(65, 0))
        self.assertEqual(code, 1)
        self.assertIn('STRUIS_GATE_RESULT ok=false tests=2 exits=65,0', lines)

    def test_a_failed_build_runs_no_tests(self):
        code, started, lines = self.run_main({}, build_exit=65)
        self.assertEqual(code, 1)
        self.assertEqual([command[1] for command in started if command[0] == 'xcodebuild'], ['build-for-testing'])
        self.assertIn('STRUIS_GATE_RESULT ok=false reason=build-for-testing exit=65', lines)

    def test_without_the_long_class_only_the_parallel_run_starts(self):
        results = {'parallel': [('ReplyTailUITests/testA()', 'Passed')]}
        code, started, lines = self.run_main(results, test_exits=(0,), selected=['ReplyTailUITests/testA()'])
        self.assertEqual(code, 0)
        builds = [command for command in started if command[0] == 'xcodebuild']
        self.assertEqual(len(builds), 2)
        self.assertEqual(builds[1][builds[1].index('-parallel-testing-worker-count') + 1], '8')
        self.assertFalse(any(argument.startswith('-skip-testing') for argument in builds[1]))


if __name__ == '__main__':
    unittest.main()
