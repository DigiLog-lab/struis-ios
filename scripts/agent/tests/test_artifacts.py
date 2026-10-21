import base64
import io
import json
from pathlib import Path
import sys
import unittest
import zipfile

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import artifacts


def token(scopes):
    payload = base64.urlsafe_b64encode(json.dumps({'scp': scopes}).encode()).decode().rstrip('=')
    return f'header.{payload}.signature'


class FakeGitHub:
    repository = 'owner/repo'
    token = 't'

    def __init__(self, runs):
        self.runs = runs

    def get(self, path):
        return self.runs[int(path.rsplit('/', 1)[1])]


class ArtifactTests(unittest.TestCase):
    def test_backend_ids_come_from_the_runtime_token_scope(self):
        self.assertEqual(artifacts.backend_ids(token('Actions.GenericRead:abc Actions.Results:run-1:job-2')), ('run-1', 'job-2'))
        with self.assertRaises(artifacts.ArtifactError):
            artifacts.backend_ids(token('Actions.GenericRead:abc'))

    def test_zip_round_trip_is_byte_exact_and_rejects_escaping_paths(self):
        files = {'manifest.json': b'{}', 'commits.bundle': bytes(range(256)) * 4, 'changes.patch': b''}
        self.assertEqual(artifacts.unzip_bytes(artifacts.zip_bytes(files)), files)
        buffer = io.BytesIO()
        with zipfile.ZipFile(buffer, 'w') as archive:
            archive.writestr('../outside', b'x')
        with self.assertRaises(artifacts.ArtifactError):
            artifacts.unzip_bytes(buffer.getvalue())

    def test_only_main_agent_workflow_artifacts_of_this_repository_are_trusted(self):
        runs = {1: {'path': '.github/workflows/agent.yml', 'head_branch': 'main'},
                2: {'path': '.github/workflows/agent-tests.yml', 'head_branch': 'main'},
                3: {'path': '.github/workflows/agent.yml@refs/heads/main', 'head_branch': 'main'}}
        client = artifacts.ArtifactClient(FakeGitHub(runs))
        def meta(run_id, **overrides):
            base = {'name': 'agent-ckpt-4-save', 'expired': False,
                    'workflow_run': {'id': run_id, 'repository_id': 10, 'head_repository_id': 10, 'head_branch': 'main'}}
            base['workflow_run'].update(overrides.pop('run', {}))
            base.update(overrides)
            return base
        self.assertTrue(client.trusted(meta(1), 'agent-ckpt-4-'))
        self.assertTrue(client.trusted(meta(3), 'agent-ckpt-4-'))
        self.assertFalse(client.trusted(meta(2), 'agent-ckpt-4-'))  # another workflow
        self.assertFalse(client.trusted(meta(1, run={'head_repository_id': 99}), 'agent-ckpt-4-'))  # a fork
        self.assertFalse(client.trusted(meta(1, run={'head_branch': 'feature'}), 'agent-ckpt-4-'))  # a branch run
        self.assertFalse(client.trusted(meta(1), 'agent-ckpt-44-'))  # another Issue
        self.assertFalse(client.trusted(meta(1, expired=True), 'agent-ckpt-4-'))


if __name__ == '__main__':
    unittest.main()
