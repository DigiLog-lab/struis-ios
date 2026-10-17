"""Restart kinds: validation repair stays on the pushed HEAD; only interruption resumes the session."""
import json
import os
from pathlib import Path
import sys
import tempfile
import unittest
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import agentctl  # noqa: E402
import progress  # noqa: E402


def comment(identifier, login='owner', body='hello'):
    return {'id': identifier, 'user': {'login': login, 'type': 'User'}, 'author_association': 'OWNER',
            'body': body, 'created_at': '2026-10-10T00:00:00Z'}


class RestartKindTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.home = Path(self.temp.name)
        patch = mock.patch.dict(os.environ, {'AGENT_HOME': str(self.home), 'RUNNER_TEMP': str(self.home),
                                             'ISSUE_NUMBER': '4', 'GITHUB_RUN_ID': '777'})
        patch.start()
        self.addCleanup(patch.stop)

    # ---------------------------------------------------------- finalize ---

    def finalize(self, state, claude_outcome='success', validation_outcome='failure', num_turns=1):
        run = {'issue': 4, 'branch': 'agent/issue-4', 'restored': True, 'recovery': False,
               'startedAt': '2026-10-10T00:00:00Z', 'model': 'opus', 'includedComments': [20], 'includedIssueBody': False}
        (self.home / 'run.json').write_text(json.dumps(run))
        messages = ([{'type': 'result', 'subtype': 'success', 'num_turns': num_turns, 'is_error': False,
                      'result': 'done', 'session_id': 'sess'}] if claude_outcome == 'success' else [])
        gh = mock.Mock(repository='owner/repo')
        store = mock.Mock()
        store.get_json.return_value = json.loads(json.dumps(state))
        env = {'VALIDATION_OUTCOME': validation_outcome, 'CLAUDE_OUTCOME': claude_outcome}
        with mock.patch.dict(os.environ, env), \
                mock.patch.object(agentctl, 'GitHub', return_value=gh), \
                mock.patch.object(agentctl, 'Store', return_value=store), \
                mock.patch.object(agentctl, 'load_execution', return_value=messages), \
                mock.patch.object(agentctl, 'save_session', return_value=0), \
                mock.patch.object(agentctl, 'save_workspace'), \
                mock.patch.object(agentctl, 'read_outbox', return_value=[]), \
                mock.patch.object(agentctl, 'upload_attachments', return_value=[]), \
                mock.patch.object(agentctl, 'record_prototype_events'), \
                mock.patch.object(agentctl, 'append_summary'), \
                mock.patch.object(agentctl, 'git', return_value='head'), \
                mock.patch.object(agentctl, 'CLAUDE_DIR', self.home / 'claude'), \
                mock.patch.object(progress, 'stop_owned_commands'), \
                mock.patch.object(progress, 'update'):
            if validation_outcome == 'success' and claude_outcome == 'success' and num_turns:
                agentctl.cmd_finalize(None)
            else:
                with self.assertRaises(SystemExit):
                    agentctl.cmd_finalize(None)
        return store.put_json.call_args.args[1], gh

    def test_validation_failure_schedules_repair_restart_without_consuming_requests(self):
        (self.home / 'validation.json').write_text(json.dumps(
            {'success': False, 'currentCheck': 'pr-ci', 'error': 'PR CI未成功: ios.yml: completed/failure'}))
        state, gh = self.finalize({'issue': 4, 'lastCommentId': 10})
        self.assertEqual(state['restartKind'], 'validation')
        self.assertEqual(state['repair'], {'includedComments': [20], 'includedIssueBody': False})
        self.assertEqual(state['lastCommentId'], 10)
        self.assertIn('PR CI未成功', state['validationFailure']['failures'][0])
        gh.request.assert_called_once()
        self.assertIn('/actions/workflows/agent.yml/dispatches', gh.request.call_args.args[1])
        self.assertIn('CIの失敗だけ', gh.comment.call_args.args[1])

    def test_cancelled_claude_schedules_interrupted_restart(self):
        state, gh = self.finalize({'issue': 4}, claude_outcome='cancelled', validation_outcome='skipped')
        self.assertEqual(state['restartKind'], 'interrupted')
        self.assertNotIn('repair', state)
        gh.request.assert_called_once()

    def test_zero_turn_schedules_interrupted_restart(self):
        state, _gh = self.finalize({'issue': 4}, validation_outcome='failure', num_turns=0)
        self.assertEqual(state['restartKind'], 'interrupted')
        self.assertTrue(state['lastRun']['noOp'])
        self.assertNotIn('repair', state)

    def test_successful_repair_clears_restart_state_and_marks_scope_processed(self):
        state, gh = self.finalize({'issue': 4, 'restartKind': 'validation', 'autoRestarts': 1, 'lastCommentId': 10,
                                   'repair': {'includedComments': [20], 'includedIssueBody': False},
                                   'validationFailure': {'check': 'pr-ci'}},
                                  validation_outcome='success')
        self.assertNotIn('restartKind', state)
        self.assertNotIn('repair', state)
        self.assertNotIn('validationFailure', state)
        self.assertEqual(state['autoRestarts'], 0)
        self.assertEqual(state['lastCommentId'], 20)
        gh.request.assert_not_called()

    # ----------------------------------------------------------- prepare ---

    def prepare(self, state, comments, automatic, session_present=True):
        issue = {'number': 4, 'title': 'T', 'html_url': 'https://github.com/owner/repo/issues/4', 'body': 'body',
                 'created_at': '2026-10-01T00:00:00Z', 'user': {'login': 'owner'}, 'author_association': 'OWNER'}
        gh = mock.Mock(repository='owner/repo')
        gh.issue.return_value = issue
        gh.comments.return_value = comments
        store = mock.Mock()
        store.get_json.return_value = json.loads(json.dumps(state))
        store.list.return_value = []

        def git(*args, **kwargs):
            return {'log': 'abc commit', 'status': ''}.get(args[0], 'headsha')

        with mock.patch.dict(os.environ, {'AUTOMATIC_RETRY': 'true' if automatic else 'false'}), \
                mock.patch.object(agentctl, 'GitHub', return_value=gh), \
                mock.patch.object(agentctl, 'Store', return_value=store), \
                mock.patch.object(agentctl, 'checkout_branch', return_value=True), \
                mock.patch.object(agentctl, 'restore_workspace', return_value=None), \
                mock.patch.object(agentctl, 'restore_session', return_value=session_present) as restore, \
                mock.patch.object(agentctl, 'git', side_effect=git), \
                mock.patch.object(agentctl, 'write_output'), \
                mock.patch.object(progress, 'update'):
            agentctl.cmd_prepare(None)
        run = json.loads((self.home / 'run.json').read_text())
        prompt = (self.home / 'prompt.txt').read_text()
        return run, prompt, store.put_json.call_args.args[1], restore

    def test_validation_repair_starts_new_session_and_fixes_only_current_head(self):
        state = {'issue': 4, 'branch': 'agent/issue-4', 'sessionId': 'sess', 'lastCommentId': 10,
                 'restartKind': 'validation', 'autoRestarts': 1, 'issueBodyProcessed': True,
                 'repair': {'includedComments': [20], 'includedIssueBody': False},
                 'validationFailure': {'check': 'pr-ci', 'failures': ['Test Case scroll failed'], 'run': 'url'},
                 'lastRun': {'success': False, 'noOp': False, 'turnUsage': {'input': 5}}}
        comments = [comment(20, body='二つ目の項目をやって'), comment(30, body='新しい依頼')]
        run, prompt, saved, restore = self.prepare(state, comments, automatic=True)
        restore.assert_not_called()
        self.assertFalse(run['restored'])
        self.assertTrue(run['recovery'])
        self.assertTrue(run['repair'])
        self.assertEqual(run['includedComments'], [20])
        self.assertEqual(saved['lastCommentId'], 10)
        self.assertEqual(saved['autoRestarts'], 1)
        self.assertNotIn('restartKind', saved)
        self.assertIn('<validation-repair>', prompt)
        self.assertIn('Test Case scroll failed', prompt)
        self.assertIn('次の項目', prompt)
        self.assertIn('skip', prompt)
        self.assertIn('Re-run', prompt)
        self.assertIn('request-pr', prompt)
        self.assertIn('PR CIの検証に失敗したため、新しいセッション', prompt)
        self.assertIn('二つ目の項目をやって', prompt)  # scope of the failed run, as history
        self.assertNotIn('新しい依頼', prompt)  # newer comment is left for the next human run
        self.assertNotIn('<comment id=', prompt)
        self.assertNotIn('<validation-failure>', prompt)

    def test_interrupted_restart_resumes_saved_session(self):
        state = {'issue': 4, 'branch': 'agent/issue-4', 'sessionId': 'sess', 'lastCommentId': 10,
                 'restartKind': 'interrupted', 'autoRestarts': 1,
                 'lastRun': {'success': False, 'noOp': False, 'turnUsage': {'input': 5}}}
        run, prompt, saved, restore = self.prepare(state, [comment(20)], automatic=True)
        restore.assert_called_once_with(mock.ANY, 4, 'sess')
        self.assertTrue(run['restored'])
        self.assertFalse(run['repair'])
        self.assertEqual(run['includedComments'], [20])
        self.assertIn('<comment id="20"', prompt)
        self.assertNotIn('<validation-repair>', prompt)

    def test_zero_turn_restart_uses_fresh_session_with_history(self):
        state = {'issue': 4, 'branch': 'agent/issue-4', 'sessionId': 'sess', 'lastCommentId': 10,
                 'restartKind': 'interrupted', 'autoRestarts': 1,
                 'lastRun': {'success': False, 'noOp': True, 'turnUsage': {'input': 0}}}
        run, prompt, _saved, restore = self.prepare(state, [comment(20)], automatic=True)
        restore.assert_not_called()
        self.assertFalse(run['restored'])
        self.assertTrue(run['recovery'])
        self.assertIn('0ターンで終了', prompt)
        self.assertEqual(run['includedComments'], [20])

    def test_legacy_restart_without_kind_still_resumes(self):
        state = {'issue': 4, 'branch': 'agent/issue-4', 'sessionId': 'sess', 'lastCommentId': 10,
                 'autoRestarts': 1, 'lastRun': {'success': False, 'noOp': False, 'turnUsage': {'input': 5}}}
        run, _prompt, _saved, restore = self.prepare(state, [comment(20)], automatic=True)
        restore.assert_called_once()
        self.assertTrue(run['restored'])

    def test_human_rerun_after_failure_starts_new_session_with_all_pending_comments(self):
        state = {'issue': 4, 'branch': 'agent/issue-4', 'sessionId': 'sess', 'lastCommentId': 10,
                 'restartKind': 'validation', 'autoRestarts': 2, 'issueBodyProcessed': True,
                 'repair': {'includedComments': [20], 'includedIssueBody': False},
                 'validationFailure': {'check': 'pr-ci', 'failures': [], 'run': 'url'},
                 'lastRun': {'success': False, 'noOp': False, 'turnUsage': {'input': 5}}}
        run, prompt, saved, restore = self.prepare(state, [comment(20), comment(30, body='新しい依頼')], automatic=False)
        restore.assert_not_called()
        self.assertFalse(run['restored'])
        self.assertTrue(run['recovery'])
        self.assertFalse(run['repair'])
        self.assertEqual(run['includedComments'], [20, 30])
        self.assertEqual(saved['autoRestarts'], 0)
        self.assertNotIn('repair', saved)
        self.assertNotIn('restartKind', saved)
        self.assertIn('失敗した後の再実行', prompt)
        self.assertIn('<comment id="30"', prompt)
        self.assertIn('<validation-failure>', prompt)

    def test_next_comment_after_success_resumes_session(self):
        state = {'issue': 4, 'branch': 'agent/issue-4', 'sessionId': 'sess', 'lastCommentId': 10,
                 'issueBodyProcessed': True, 'lastRun': {'success': True, 'noOp': False, 'turnUsage': {'input': 5}}}
        run, _prompt, _saved, restore = self.prepare(state, [comment(20)], automatic=False)
        restore.assert_called_once()
        self.assertTrue(run['restored'])


if __name__ == '__main__':
    unittest.main()
