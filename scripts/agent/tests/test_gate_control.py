import json
import os
from pathlib import Path
import sys
import unittest
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import agentctl
import delivery
import progress
from gate_fakes import MemoryStore
import test_restart as fixtures


class GateFinalizationTests(unittest.TestCase):
    setUp = fixtures.RestartKindTests.setUp
    finalize = fixtures.RestartKindTests.finalize

    def test_waiting_gate_releases_worker_without_consuming_requests_or_restarting(self):
        with mock.patch.dict(os.environ, {'AGENT_VALIDATION_MODE': 'gate'}), \
                mock.patch.object(delivery, 'waiting', return_value=True), mock.patch.object(delivery, 'paused', return_value=False):
            state, gh = self.finalize({'issue': 4, 'lastCommentId': 10}, validation_outcome='success')
        self.assertEqual(state['workerStatus'], 'waiting-gate')
        self.assertEqual(state['lastCommentId'], 10)
        self.assertNotIn('validatedHead', state)
        gh.request.assert_not_called()
        self.assertIn('macOS workerは終了', gh.comment.call_args.args[1])

    def test_claude_interruption_after_ready_does_not_restart_to_wait(self):
        with mock.patch.dict(os.environ, {'AGENT_VALIDATION_MODE': 'gate'}), \
                mock.patch.object(delivery, 'waiting', return_value=True), mock.patch.object(delivery, 'paused', return_value=False):
            state, gh = self.finalize({'issue': 4, 'lastCommentId': 10}, claude_outcome='cancelled')
        self.assertEqual(state['workerStatus'], 'waiting-gate')
        gh.request.assert_not_called()

    def test_gate_limit_pause_does_not_mark_done_or_schedule_retry(self):
        delivery.write('delivery-blocked.json', {'reason': 'limit reached'})
        with mock.patch.dict(os.environ, {'AGENT_VALIDATION_MODE': 'gate'}), \
                mock.patch.object(delivery, 'waiting', return_value=False), mock.patch.object(delivery, 'paused', return_value=True):
            state, gh = self.finalize({'issue': 4, 'lastCommentId': 10}, validation_outcome='success')
        self.assertEqual(state['workerStatus'], 'waiting-instructions')
        self.assertNotIn('validatedHead', state)
        self.assertEqual(state['lastCommentId'], 10)
        gh.request.assert_not_called()


class GateRecoveryScopeTests(unittest.TestCase):
    setUp = fixtures.RestartKindTests.setUp

    def prepare(self, automatic):
        store = MemoryStore()
        state = {'issue': 4, 'branch': 'work', 'sessionId': 'old-session', 'sessionStale': True,
                 'lastCommentId': 10, 'issueBodyProcessed': True, 'restartKind': 'interrupted'}
        store.put_json('sessions/4/state.json', state)
        store.put_json('sessions/4/workspace.json', {'schema': 2, 'prefix': 'sessions/4/checkpoints/saved', 'sessionId': 'new-session'})
        old_issue = {'number': 4, 'title': 'original title', 'body': 'original request', 'user': {'login': 'owner'},
                     'created_at': '2026-10-01T00:00:00Z', 'html_url': 'https://github.com/owner/repo/issues/4', 'author_association': 'OWNER'}
        snapshot = agentctl.request_snapshot(old_issue, [fixtures.comment(20, body='original work')], '2026-10-01T00:00:00Z')
        live_issue = dict(old_issue, title='edited title', body='edited request')
        gh = mock.Mock(repository='owner/repo')
        gh.issue.return_value = live_issue
        gh.comments.return_value = [fixtures.comment(20, body='edited comment'), fixtures.comment(30, body='new work')]
        def restored(*args):
            delivery.write('request-snapshot.json', snapshot)
            delivery.write('checkpoint-run.json', {'includedComments': [20], 'includedIssueBody': False})
            return True
        with mock.patch.dict(os.environ, {'AUTOMATIC_RETRY': 'true' if automatic else 'false', 'AGENT_VALIDATION_MODE': 'gate'}), \
                mock.patch.object(agentctl, 'GitHub', return_value=gh), mock.patch.object(agentctl, 'Store', return_value=store), \
                mock.patch.object(agentctl, 'checkout_branch', return_value=True), \
                mock.patch.object(agentctl, 'restore_workspace', side_effect=restored), \
                mock.patch.object(agentctl, 'restore_session', return_value=True) as resume, \
                mock.patch.object(agentctl, 'git', side_effect=lambda *args, **kwargs: '' if args[0] == 'status' else 'headsha'), \
                mock.patch.object(agentctl.subprocess, 'check_output', return_value='Xcode 27'), \
                mock.patch.object(agentctl, 'write_output'), mock.patch.object(progress, 'update'):
            agentctl.cmd_prepare(None)
        return delivery.read('run.json'), delivery.read('request-snapshot.json'), resume

    def test_interrupted_recovery_uses_checkpoint_session_and_original_scope(self):
        run, snapshot, resume = self.prepare(True)
        self.assertTrue(run['restored'])
        self.assertEqual(run['includedComments'], [20])
        self.assertEqual(snapshot['issue']['body'], 'original request')
        self.assertEqual(snapshot['comments'][0]['body'], 'original work')
        resume.assert_called_once_with(mock.ANY, 4, 'new-session')

    def test_human_instruction_uses_new_session_and_live_authorized_requests(self):
        run, snapshot, resume = self.prepare(False)
        resume.assert_not_called()
        self.assertFalse(run['restored'])
        self.assertEqual(run['includedComments'], [20, 30])
        self.assertEqual(snapshot['issue']['body'], 'edited request')

    def test_progress_saves_periodically_during_claude_execution(self):
        delivery.write('run.json', {'issue': 4, 'branch': 'work'})
        def saved(*args, **kwargs):
            (self.home / 'progress-stop').touch()
        with mock.patch.dict(os.environ, {'AGENT_VALIDATION_MODE': 'gate', 'AGENT_CHECKPOINT_SECONDS': '900'}), \
                mock.patch.object(progress, 'update'), mock.patch.object(progress, 'Store'), \
                mock.patch.object(progress.time, 'monotonic', side_effect=[0, 901, 901]), \
                mock.patch('checkpoints.save', side_effect=saved) as checkpoint:
            progress.watch()
        checkpoint.assert_called_once_with(mock.ANY, 4, {'issue': 4, 'branch': 'work'}, periodic=True)
