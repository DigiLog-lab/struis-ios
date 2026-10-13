import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest import mock

import agentctl


class MemoryStore:
    def __init__(self):
        self.data = {}
    def put(self, key, data, _type):
        self.data[key] = data
    def get(self, key):
        return self.data.get(key)
    def put_json(self, key, data):
        self.data[key] = data
    def get_json(self, key):
        return self.data.get(key)


    def upload_file(self, key, path, _type):
        self.data[key] = Path(path).read_bytes()


class CheckpointTests(unittest.TestCase):
    def test_actual_git_changes_survive_runner_replacement(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            workspace = root / 'repo'
            workspace.mkdir()
            def git(*args):
                return subprocess.check_output(['git', '-C', str(workspace), *args], stderr=subprocess.DEVNULL).decode().strip()
            git('init')
            git('config', 'user.email', 'test@example.com')
            git('config', 'user.name', 'test')
            (workspace / 'tracked.txt').write_text('before')
            (workspace / '.gitignore').write_text('secret.key\n')
            git('add', '.')
            git('commit', '-m', 'initial')
            head = git('rev-parse', 'HEAD')
            git('update-ref', 'refs/remotes/origin/main', head)
            (workspace / 'tracked.txt').write_text('after')
            (workspace / 'staged.txt').write_text('staged change')
            git('add', 'staged.txt')
            (workspace / 'untracked.txt').write_text('untracked change')
            (workspace / 'secret.key').write_text('excluded secret')
            store = MemoryStore()
            with mock.patch.dict(os.environ, {'GITHUB_WORKSPACE': str(workspace), 'AGENT_HOME': str(root / 'agent')}), \
                    mock.patch.object(agentctl, 'git', side_effect=lambda *args, **kwargs: '' if args[0] == 'ls-remote' else git(*args)):
                agentctl.save_workspace(store, 4, {'headBefore': head, 'branch': 'agent/issue-4'})
                git('reset', '--hard', 'HEAD')
                git('clean', '-fd')
                agentctl.restore_workspace(store, 4, 'agent/issue-4')
                self.assertEqual((workspace / 'tracked.txt').read_text(), 'after')
                self.assertEqual((workspace / 'staged.txt').read_text(), 'staged change')
                self.assertEqual((workspace / 'untracked.txt').read_text(), 'untracked change')
                self.assertFalse(any(b'excluded secret' in value for value in store.data.values() if isinstance(value, bytes)))
                with self.assertRaises(RuntimeError):
                    agentctl.restore_workspace(store, 4, 'different-branch')
                # A local commit that was never pushed survives the next runner too.
                git('add', '.')
                git('commit', '-m', 'unpublished')
                local_head = git('rev-parse', 'HEAD')
                agentctl.save_workspace(store, 4, {'headBefore': local_head, 'branch': 'agent/issue-4'})
                git('reset', '--hard', head)
                agentctl.restore_workspace(store, 4, 'agent/issue-4')
                self.assertEqual(git('rev-parse', 'HEAD'), local_head)
                self.assertEqual((workspace / 'tracked.txt').read_text(), 'after')
