import json
import os
from pathlib import Path
import sys
import tempfile
import unittest
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import cloud_dispatch


class CloudDispatchTests(unittest.TestCase):
    def payload(self, data):
        with tempfile.NamedTemporaryFile('w', suffix='.json', delete=False) as handle:
            json.dump({'client_payload': data}, handle)
        self.addCleanup(os.unlink, handle.name)
        with mock.patch.dict(os.environ, {'GITHUB_EVENT_PATH': handle.name}):
            return cloud_dispatch.payload()

    def test_on_request_builds_run_only_from_main(self):
        self.assertEqual(self.payload({'workflow': 'release', 'issue': '4'}), ('release', 'main', 4))
        self.assertEqual(self.payload({'workflow': 'pr-gate', 'branch': 'main'}), ('pr-gate', 'main', None))
        for workflow in ('release', 'pr-gate'):
            with self.subTest(workflow=workflow), self.assertRaisesRegex(SystemExit, 'only from main'):
                self.payload({'workflow': workflow, 'branch': 'agent/issue-4'})

    def test_unknown_workflow_and_malformed_input_are_refused(self):
        for data in ({'workflow': 'archive'}, {'workflow': 'release', 'branch': '../main'},
                     {'workflow': 'release', 'issue': '4; rm'}):
            with self.subTest(data=data), self.assertRaises(SystemExit):
                self.payload(data)
