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
        self.assertEqual(state['repair'], {'includedComments': [20], 'includedIssueBody': False, 'head': 'head'})
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

    def prepare(self, state, comments, automatic, session_present=True, descends=True):
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
                mock.patch.object(agentctl, 'head_descends_from', return_value=descends), \
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

    # ---------------------------------- validation failure before finalize ---

    def validate(self, persisted):
        """Run validate against an in-memory state store; returns the state it left behind."""
        run = {'issue': 4, 'branch': 'agent/issue-4', 'headBefore': 'old', 'validationRequired': True,
               'includedComments': [20], 'includedIssueBody': False}
        (self.home / 'run.json').write_text(json.dumps(run))
        messages = [{'type': 'result', 'subtype': 'success', 'num_turns': 3, 'is_error': False}]
        store = mock.Mock()
        store.get_json.side_effect = lambda key: json.loads(json.dumps(persisted.get(key)))
        store.put_json.side_effect = lambda key, value: persisted.update({key: json.loads(json.dumps(value))})

        def git(*args, **kwargs):
            return '' if args[0] == 'status' else 'failedsha'

        def failing_ci(run, head):
            (self.home / 'validation.json').write_text(json.dumps(
                {'success': False, 'currentCheck': 'pr-ci', 'error': 'PR CI未成功: ios.yml: completed/failure'}))
            raise RuntimeError('PR CI未成功')

        with mock.patch.object(agentctl, 'load_execution', return_value=messages), \
                mock.patch.object(agentctl, 'Store', return_value=store), \
                mock.patch.object(agentctl, 'git', side_effect=git), \
                mock.patch.object(agentctl, 'verify_pr_ci', side_effect=failing_ci):
            with self.assertRaisesRegex(RuntimeError, 'PR CI未成功'):
                agentctl.cmd_validate(None)
        return persisted['sessions/4/state.json']

    def test_validation_failure_is_persisted_before_finalize_and_recovered_as_repair(self):
        persisted = {'sessions/4/state.json': {'issue': 4, 'lastCommentId': 10, 'workerStatus': 'running',
                                               'workerRun': 'https://github.com/owner/repo/actions/runs/777',
                                               'workerRunAttempt': '1'}}
        state = self.validate(persisted)
        self.assertEqual(state['pendingRestartKind'], 'validation')
        self.assertEqual(state['repair'], {'includedComments': [20], 'includedIssueBody': False, 'head': 'failedsha'})
        self.assertIn('PR CI未成功', state['validationFailure']['failures'][0])
        self.assertEqual(state['lastCommentId'], 10)

        # The runner is lost before finalize: the watchdog restarts as a repair, not a resume.
        gh = mock.Mock(repository='owner/repo')
        store = mock.Mock()
        store.get_json.return_value = json.loads(json.dumps(state))
        with mock.patch.dict(os.environ, {'RECOVER_TITLE': 'Issue agent #4', 'RECOVER_RUN_ID': '777',
                                          'RECOVER_RUN_ATTEMPT': '1'}), \
                mock.patch.object(agentctl, 'GitHub', return_value=gh), \
                mock.patch.object(agentctl, 'Store', return_value=store):
            agentctl.cmd_recover(None)
        gh.request.assert_called_once()
        recovered = store.put_json.call_args.args[1]
        self.assertEqual(recovered['restartKind'], 'validation')
        self.assertNotIn('pendingRestartKind', recovered)
        self.assertEqual(recovered['repair']['head'], 'failedsha')

    def test_finalize_after_persisted_validation_failure_keeps_the_same_repair(self):
        before = {'issue': 4, 'lastCommentId': 10, 'pendingRestartKind': 'validation',
                  'repair': {'includedComments': [20], 'includedIssueBody': False, 'head': 'head'}}
        state, gh = self.finalize(before)
        self.assertEqual(state['restartKind'], 'validation')
        self.assertEqual(state['repair'], before['repair'])
        self.assertNotIn('pendingRestartKind', state)
        gh.request.assert_called_once()
        # Even when the validate step was cancelled after recording the failure.
        state, _gh = self.finalize(before, validation_outcome='cancelled')
        self.assertEqual(state['restartKind'], 'validation')
        self.assertEqual(state['repair'], before['repair'])

    def test_prepare_treats_pending_kind_as_validation_restart(self):
        state = {'issue': 4, 'branch': 'agent/issue-4', 'sessionId': 'sess', 'lastCommentId': 10,
                 'pendingRestartKind': 'validation', 'autoRestarts': 1, 'issueBodyProcessed': True,
                 'repair': {'includedComments': [20], 'includedIssueBody': False, 'head': 'headsha'},
                 'lastRun': {'success': True, 'noOp': False, 'turnUsage': {'input': 5}}}
        run, prompt, saved, restore = self.prepare(state, [comment(20)], automatic=True)
        restore.assert_not_called()
        self.assertTrue(run['repair'])
        self.assertNotIn('pendingRestartKind', saved)
        self.assertIn('<validation-repair>', prompt)

    # -------------------------------------------- repair pinned to the HEAD ---

    def repair_state(self):
        return {'issue': 4, 'branch': 'agent/issue-4', 'sessionId': 'sess', 'lastCommentId': 10,
                'restartKind': 'validation', 'autoRestarts': 1, 'issueBodyProcessed': True,
                'repair': {'includedComments': [20], 'includedIssueBody': False, 'head': 'failedsha'},
                'lastRun': {'success': False, 'noOp': False, 'turnUsage': {'input': 5}}}

    def test_repair_stops_when_branch_no_longer_contains_failed_head(self):
        gh = mock.Mock(repository='owner/repo')
        gh.issue.return_value = {'number': 4, 'user': {'login': 'owner'}, 'author_association': 'OWNER'}
        gh.comments.return_value = [comment(20)]
        store = mock.Mock()
        store.get_json.return_value = self.repair_state()
        with mock.patch.dict(os.environ, {'AUTOMATIC_RETRY': 'true'}), \
                mock.patch.object(agentctl, 'GitHub', return_value=gh), \
                mock.patch.object(agentctl, 'Store', return_value=store), \
                mock.patch.object(agentctl, 'checkout_branch', return_value=True), \
                mock.patch.object(agentctl, 'restore_workspace', return_value=None), \
                mock.patch.object(agentctl, 'head_descends_from', return_value=False) as descends, \
                mock.patch.object(agentctl, 'restore_session') as restore, \
                mock.patch.object(agentctl, 'git', return_value='othersha'), \
                mock.patch.object(agentctl, 'write_output') as output, \
                mock.patch.object(progress, 'update'):
            with self.assertRaisesRegex(RuntimeError, '履歴にありません'):
                agentctl.cmd_prepare(None)
        descends.assert_called_once_with('failedsha')
        restore.assert_not_called()
        store.put_json.assert_not_called()  # state kept; the next human comment runs normally
        output.assert_not_called()
        self.assertFalse((self.home / 'run.json').exists())
        self.assertFalse((self.home / 'prompt.txt').exists())
        self.assertIn('failedsha'[:12], gh.comment.call_args.args[1])

    def test_repair_runs_on_descendant_of_failed_head(self):
        run, prompt, saved, _restore = self.prepare(self.repair_state(), [comment(20)], automatic=True, descends=True)
        self.assertTrue(run['repair'])
        self.assertEqual(saved['repair']['head'], 'failedsha')
        self.assertIn('<validation-repair>', prompt)

    def test_head_descends_from_uses_git_ancestry(self):
        with tempfile.TemporaryDirectory() as directory:
            env = {'GITHUB_WORKSPACE': directory, 'GIT_AUTHOR_NAME': 'a', 'GIT_AUTHOR_EMAIL': 'a@x',
                   'GIT_COMMITTER_NAME': 'a', 'GIT_COMMITTER_EMAIL': 'a@x'}
            with mock.patch.dict(os.environ, env):
                agentctl.git('init', '-q')
                agentctl.git('commit', '-q', '--allow-empty', '-m', 'one')
                first = agentctl.git('rev-parse', 'HEAD')
                agentctl.git('commit', '-q', '--allow-empty', '-m', 'two')
                second = agentctl.git('rev-parse', 'HEAD')
                self.assertTrue(agentctl.head_descends_from(first))
                self.assertTrue(agentctl.head_descends_from(second))
                agentctl.git('checkout', '-q', '--orphan', 'rewritten')
                agentctl.git('commit', '-q', '--allow-empty', '-m', 'force-pushed')
                self.assertFalse(agentctl.head_descends_from(first))
                self.assertFalse(agentctl.head_descends_from('0' * 40))

    # --------------------------------- repair without any pending comment ---

    def route(self, state, comments, automatic):
        issue = {'number': 4, 'labels': [{'name': 'agent'}], 'user': {'login': 'owner'}, 'author_association': 'OWNER'}
        gh = mock.Mock(repository='owner/repo')
        gh.issue.return_value = issue
        gh.comments.return_value = comments
        store = mock.Mock()
        store.get_json.return_value = json.loads(json.dumps(state))
        with mock.patch.dict(os.environ, {'AUTOMATIC_RETRY': 'true' if automatic else 'false'}), \
                mock.patch.object(agentctl, 'GitHub', return_value=gh), \
                mock.patch.object(agentctl, 'Store', return_value=store), \
                mock.patch.object(agentctl, 'write_output') as output:
            agentctl.cmd_route(None)
        return output.call_args.args[1]

    def test_route_runs_persisted_repair_without_pending_comments(self):
        state = dict(self.repair_state(), lastCommentId=20)
        self.assertEqual(self.route(state, [], automatic=True), 'true')  # original comment deleted
        self.assertEqual(self.route(state, [comment(20)], automatic=True), 'true')  # already processed
        self.assertEqual(self.route(state, [], automatic=False), 'false')  # a human run needs new input
        self.assertEqual(self.route(dict(state, repair=None), [], automatic=True), 'false')

    def test_prepare_runs_persisted_repair_without_pending_comments(self):
        state = dict(self.repair_state(), lastCommentId=20)
        run, prompt, saved, restore = self.prepare(state, [], automatic=True)
        restore.assert_not_called()
        self.assertFalse(run.get('skip'))
        self.assertTrue(run['repair'])
        self.assertEqual(run['includedComments'], [20])
        self.assertEqual(saved['lastCommentId'], 20)
        self.assertIn('<validation-repair>', prompt)

    def test_prepare_skips_without_repair_when_nothing_is_pending(self):
        state = dict(self.repair_state(), lastCommentId=20)
        state.pop('repair')
        with mock.patch.dict(os.environ, {'AUTOMATIC_RETRY': 'true'}):
            gh = mock.Mock(repository='owner/repo')
            gh.issue.return_value = {'number': 4, 'user': {'login': 'owner'}, 'author_association': 'OWNER'}
            gh.comments.return_value = []
            store = mock.Mock()
            store.get_json.return_value = state
            with mock.patch.object(agentctl, 'GitHub', return_value=gh), \
                    mock.patch.object(agentctl, 'Store', return_value=store), \
                    mock.patch.object(agentctl, 'checkout_branch') as checkout, \
                    mock.patch.object(agentctl, 'write_output'):
                agentctl.cmd_prepare(None)
        checkout.assert_not_called()
        self.assertTrue(json.loads((self.home / 'run.json').read_text())['skip'])


if __name__ == '__main__':
    unittest.main()
