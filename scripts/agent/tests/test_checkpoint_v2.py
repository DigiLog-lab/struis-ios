import io
import json
import os
from pathlib import Path
import subprocess
import sys
import tarfile
import tempfile
import unittest
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import checkpoints
from gate_fakes import MemoryStore


class ImmutableCheckpointTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.repo, self.home = self.root / 'repo', self.root / 'agent'
        self.repo.mkdir()
        self.git('init', '-b', 'work')
        self.git('config', 'user.email', 'test@example.com')
        self.git('config', 'user.name', 'test')
        (self.repo / 'tracked').write_text('initial')
        (self.repo / '.gitignore').write_text('secret.key\n')
        self.git('add', '.')
        self.git('commit', '-m', 'base')
        self.base = self.git('rev-parse', 'HEAD')
        remote = self.root / 'remote.git'
        subprocess.run(['git', 'init', '--bare', str(remote)], check=True, capture_output=True)
        self.git('remote', 'add', 'origin', str(remote))
        self.git('push', '-u', 'origin', 'work')
        patch = mock.patch.dict(os.environ, {'GITHUB_WORKSPACE': str(self.repo), 'AGENT_HOME': str(self.home)})
        patch.start()
        self.addCleanup(patch.stop)
        patch = mock.patch.object(checkpoints, 'session_archive', return_value=checkpoints.tar_bytes([('projects/session.jsonl', b'{}\n', 0o600)]))
        patch.start()
        self.addCleanup(patch.stop)
        self.store = MemoryStore()
        self.run = {'issue': 4, 'branch': 'work'}

    def git(self, *args):
        return subprocess.check_output(['git', '-C', str(self.repo), *args], stderr=subprocess.DEVNULL).decode().strip()

    def test_complete_save_restores_dirty_untracked_unpushed_and_verification(self):
        (self.repo / 'committed').write_text('not pushed')
        self.git('add', '.')
        self.git('commit', '-m', 'unpublished')
        head = self.git('rev-parse', 'HEAD')
        (self.repo / 'tracked').write_text('edited')
        (self.repo / 'scratch').write_text('untracked')
        (self.repo / 'secret.key').write_text('must not upload')
        self.home.mkdir()
        for name in checkpoints.FILES:
            (self.home / name).write_text(json.dumps({'id': 'session', 'example': name}))
        saved = checkpoints.save(self.store, 4, self.run)
        self.assertEqual(saved['head'], head)
        self.assertTrue(saved['bundle'])
        self.assertEqual(saved['sessionId'], 'session')
        self.assertNotIn(b'must not upload', b''.join(self.store.data.values()))
        self.git('reset', '--hard', self.base)
        self.git('clean', '-fd')
        self.assertTrue(checkpoints.restore(self.store, 4, 'work'))
        self.assertEqual(self.git('rev-parse', 'HEAD'), head)
        self.assertEqual((self.repo / 'tracked').read_text(), 'edited')
        self.assertEqual((self.repo / 'scratch').read_text(), 'untracked')
        self.assertEqual(json.loads((self.home / 'local-verification.json').read_text())['example'], 'local-verification.json')

    def test_unique_saves_keep_previous_and_prune_only_after_pointer_commit(self):
        first = checkpoints.save(self.store, 4, self.run)
        second = checkpoints.save(self.store, 4, self.run)
        third = checkpoints.save(self.store, 4, self.run)
        self.assertEqual(len({first['saveId'], second['saveId'], third['saveId']}), 3)
        self.assertEqual(third['previous']['saveId'], second['saveId'])
        self.assertNotIn('previous', third['previous'])
        self.assertEqual(self.store.pruned[-1][1], [third['saveId'], second['saveId']])

    def test_upload_failure_and_lost_cas_preserve_complete_pointer(self):
        first = checkpoints.save(self.store, 4, self.run)
        self.store.fail_upload = True
        with self.assertRaises(RuntimeError):
            checkpoints.save(self.store, 4, self.run)
        self.assertEqual(self.store.get_json('sessions/4/workspace.json'), first)
        self.store.fail_upload = False
        original = self.store.upload_file
        def race(key, path):
            original(key, path)
            self.store.put_json('sessions/4/workspace.json', {'closed': True, 'winner': True})
        with mock.patch.object(self.store, 'upload_file', side_effect=race):
            self.assertIsNone(checkpoints.save(self.store, 4, self.run))
        self.assertTrue(self.store.get_json('sessions/4/workspace.json')['winner'])
        self.assertEqual(self.store.pruned, [])

    def test_integrity_failure_is_detected_before_checkout_modification(self):
        saved = checkpoints.save(self.store, 4, self.run)
        self.store.data[saved['prefix'] + '/untracked.tar.gz'] = b'corrupt'
        with self.assertRaisesRegex(RuntimeError, 'Incomplete checkpoint'):
            checkpoints.restore(self.store, 4, 'work')
        self.assertEqual(self.git('status', '--porcelain'), '')

    def test_remote_update_stops_restore_and_tombstone_stops_resurrection(self):
        checkpoints.save(self.store, 4, self.run)
        (self.repo / 'new').write_text('new remote')
        self.git('add', '.')
        self.git('commit', '-m', 'new remote')
        self.git('push', 'origin', 'work')
        with self.assertRaisesRegex(RuntimeError, 'Remote changed'):
            checkpoints.restore(self.store, 4, 'work')
        checkpoints.clear(self.store, 4, 'complete')
        self.assertIsNone(checkpoints.save(self.store, 4, self.run))
        self.assertFalse(checkpoints.restore(self.store, 4, 'work'))
        self.assertEqual(self.store.pruned[-1][1], [])

    def test_changed_workspace_during_periodic_capture_is_not_published(self):
        first = checkpoints.save(self.store, 4, self.run)
        original = checkpoints.working_copy
        calls = 0
        def changing():
            nonlocal calls
            calls += 1
            if calls == 2:
                (self.repo / 'tracked').write_text('edit while taking backup')
            return original()
        with mock.patch.object(checkpoints, 'working_copy', side_effect=changing):
            self.assertIsNone(checkpoints.save(self.store, 4, self.run, periodic=True))
        self.assertEqual(self.store.get_json('sessions/4/workspace.json'), first)
