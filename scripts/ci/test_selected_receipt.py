from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path
import tempfile
import unittest
import zipfile

from benchmark_selected import PROBE
from selected_receipt import REPOSITORY_ID, WORKFLOW, verify


class ExactHeadOriginTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.archive = Path(self.temp.name) / 'evidence.zip'
        self.sha = 'a' * 40
        self.job = {'id': 5, 'run_id': 7, 'head_sha': self.sha, 'status': 'completed',
                    'conclusion': 'success', 'completed_at': '2026-10-22T00:00:00Z'}
        self.run = {'id': 7, 'head_sha': self.sha, 'path': WORKFLOW}
        self.artifact = {'name': 'ci-selected-7-case', 'expired': False,
                         'workflow_run': {'id': 7, 'head_sha': self.sha, 'repository_id': REPOSITORY_ID}}
        self.units = {'Rules/testRule()': 'Passed'}
        self.ui = ['Buttons/testButton']
        def case(target, key):
            return {'nodeType': 'Test Case', 'nodeIdentifier': key, 'result': 'Passed',
                    'nodeIdentifierURL': 'test://app/' + target + '/' + key}
        self.nodes = {'testNodes': [case('striusTests', 'Rules/testRule()'),
                                  case('striusUITests', 'Buttons/testButton()'),
                                  case('striusUITests', PROBE + '()')]}
        self.write()

    def write(self):
        record = {'status': 'success', 'commit': self.sha, 'runId': 7, 'retries': 0,
                  'configuration': 'case', 'selection': {'selected': self.ui},
                  'phases': [{'label': 'combined', 'exitCode': 0}]}
        count = len(self.nodes['testNodes'])
        summary = {'totalTestCount': count, 'passedTests': count, 'skippedTests': 0, 'failedTests': 0, 'result': 'Passed'}
        with zipfile.ZipFile(self.archive, 'w') as bundle:
            for name, value in [('measurement.json', record), ('combined-summary.json', summary),
                                ('combined-tests.json', self.nodes)]:
                bundle.writestr(name, json.dumps(value))
        self.artifact['digest'] = 'sha256:' + hashlib.sha256(self.archive.read_bytes()).hexdigest()

    def check(self, expected=None, trusted=None):
        return verify(self.archive, self.job, self.run, self.artifact, expected or self.sha,
                      self.ui, self.units, trusted if trusted is not None else {self.sha},
                      now=datetime(2026, 10, 22, 1, tzinfo=timezone.utc))

    def test_accepts_same_head_complete_inventory_and_trusted_artifact(self):
        self.assertEqual(self.check()['unitCount'], 1)

    def test_rejects_previous_head_even_if_tests_passed(self):
        with self.assertRaisesRegex(ValueError, 'HEAD'):
            self.check(expected='b' * 40)

    def test_rejects_failed_job_with_successful_looking_artifact(self):
        self.job['conclusion'] = 'failure'
        with self.assertRaisesRegex(ValueError, 'did not succeed'):
            self.check()

    def test_rejects_artifact_from_another_run(self):
        self.artifact['workflow_run']['id'] = 8
        with self.assertRaisesRegex(ValueError, 'origin'):
            self.check()

    def test_rejects_altered_archive(self):
        with self.archive.open('ab') as target:
            target.write(b'altered')
        with self.assertRaisesRegex(ValueError, 'digest'):
            self.check()

    def test_rejects_missing_required_ui_despite_matching_digest(self):
        self.nodes['testNodes'].pop(1)
        self.write()
        with self.assertRaisesRegex(ValueError, 'missing'):
            self.check()

    def test_rejects_changed_workflow_definition(self):
        with self.assertRaisesRegex(ValueError, 'Unapproved'):
            self.check(trusted={'b' * 40})

    def test_explicit_zero_ui_accepts_only_the_complete_unit_result(self):
        self.ui = []
        self.nodes['testNodes'] = self.nodes['testNodes'][:1]
        self.write()
        self.assertEqual(self.check()['selectedUI'], [])

    def test_zero_ui_cannot_silently_execute_unrequested_ui(self):
        self.ui = []
        self.write()
        with self.assertRaisesRegex(ValueError, 'unexpected'):
            self.check()


if __name__ == '__main__':
    unittest.main()
