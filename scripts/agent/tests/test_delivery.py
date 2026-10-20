import copy
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import delivery
import guard


def test_tree(name='Class/testWorks()', result='Passed'):
    return {'testNodes': [{'nodeType': 'Test Suite', 'children': [
        {'nodeType': 'Test Case', 'nodeIdentifier': name, 'result': result, 'duration': '0.1s'}]}]}


class DeliveryTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.home = Path(temporary.name)
        patch = mock.patch.dict(os.environ, {'AGENT_HOME': str(self.home), 'GITHUB_TOKEN': 'must-not-reach-xcodebuild'})
        patch.start()
        self.addCleanup(patch.stop)
        self.snapshot = {'issue': {'body': '1. Fix A\n2. Fix B'}, 'comments': [
            {'id': 9, 'body': 'also C', 'bot': False}, {'id': 10, 'body': 'bot reply', 'bot': True}]}
        delivery.write('request-snapshot.json', self.snapshot)
        delivery.write('run.json', {'issue': 4, 'branch': 'work'})
        delivery.initialize_items(self.snapshot)

    def complete(self):
        for item in delivery.read('work-items.json')['items']:
            delivery.complete_item(item['id'], 'implemented and checked')

    def test_all_numbered_items_and_authorized_comments_must_complete(self):
        items = delivery.read('work-items.json')['items']
        self.assertEqual([item['id'] for item in items], ['issue-1', 'issue-2', 'comment-9-1'])
        delivery.complete_item('issue-1', 'fixed A')
        self.assertFalse(delivery.items_complete())
        self.complete()
        self.assertTrue(delivery.items_complete())
        edited = copy.deepcopy(self.snapshot)
        edited['issue']['body'] = '1. Fix A\n2. Fix a different B'
        result = delivery.initialize_items(edited)
        self.assertTrue(result['items'][0]['complete'])
        self.assertFalse(result['items'][1]['complete'])

    def local_verify(self, unit_tree=None, code=0, changed_head=False):
        self.complete()
        calls = []
        def run(command, stream, timeout, environment):
            calls.append(command)
            self.assertNotIn('GITHUB_TOKEN', environment)
            if '-resultBundlePath' in command:
                Path(command[command.index('-resultBundlePath') + 1]).mkdir()
            return subprocess.CompletedProcess(command, code)
        clean = iter(['a' * 40, 'b' * 40 if changed_head else 'a' * 40])
        with mock.patch.object(delivery, 'clean_pushed', side_effect=lambda run: next(clean)), \
                mock.patch.object(delivery, 'select_ui', return_value={'unitTests': 'all', 'uiTests': ['Camera/testCamera', 'E2E/testLoop']}), \
                mock.patch.object(delivery, 'Store'), mock.patch.object(delivery.checkpoints, 'save', return_value={'saveId': 'saved'}), \
                mock.patch.object(guard, 'run_check', side_effect=run), \
                mock.patch.object(delivery.subprocess, 'check_output', return_value=json.dumps(unit_tree if unit_tree is not None else test_tree())):
            result = delivery.local_verify()
        return result, calls

    def test_local_verification_builds_once_runs_all_units_and_selected_camera_e2e(self):
        report, calls = self.local_verify()
        self.assertEqual(len(calls), 3)
        self.assertEqual(calls[0][1], 'build-for-testing')
        self.assertEqual(calls[1][1], 'test-without-building')
        self.assertIn('-only-testing:striusTests', calls[1])
        self.assertIn('-only-testing:striusUITests/Camera/testCamera', calls[2])
        self.assertIn('-only-testing:striusUITests/E2E/testLoop', calls[2])
        self.assertTrue(delivery.verified(report, 'a' * 40, self.snapshot, delivery.read('work-items.json')))
        self.assertFalse(delivery.verified(report, 'b' * 40, self.snapshot, delivery.read('work-items.json')))
        edited = copy.deepcopy(self.snapshot)
        edited['comments'][0]['body'] = 'changed scope'
        self.assertFalse(delivery.verified(report, 'a' * 40, edited, delivery.read('work-items.json')))
        self.assertIn('Class/testWorks()', delivery.summary(report))
        self.assertIn('0.1s', delivery.summary(report))

    def test_empty_results_expected_failure_and_changed_head_cannot_be_green(self):
        for result in ({'testNodes': []}, test_tree(result='Expected Failure')):
            with self.subTest(result=result), self.assertRaises(RuntimeError):
                self.local_verify(unit_tree=result)
            self.assertFalse(delivery.read('local-verification.json')['success'])
        with self.assertRaisesRegex(RuntimeError, 'HEAD changed'):
            self.local_verify(changed_head=True)
        self.assertFalse(delivery.read('local-verification.json')['success'])

    def test_test_failure_never_retries_or_produces_green_record(self):
        with self.assertRaises(RuntimeError):
            self.local_verify(code=65)
        report = delivery.read('local-verification.json')
        self.assertFalse(report['success'])
        self.assertEqual(len(report['checks']), 1)

    def test_ready_rejects_without_exact_head_local_record_before_any_api(self):
        with mock.patch.object(delivery, 'clean_pushed', return_value='a' * 40), \
                mock.patch.object(delivery, 'GitHub') as gh:
            with self.assertRaisesRegex(RuntimeError, 'Ready requires'):
                delivery.ready()
            gh.assert_not_called()

    def test_graphql_errors_are_not_successful_ready_transitions(self):
        gh = mock.Mock()
        gh.request.return_value = ({'errors': [{'message': 'permission denied'}]}, '')
        with self.assertRaisesRegex(RuntimeError, 'Draft state'):
            delivery.draft(gh, {'node_id': 'PR_id'}, False)
