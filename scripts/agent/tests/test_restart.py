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


def comment(identifier, login='owner', body='hello', association='OWNER'):
    return {'id': identifier, 'user': {'login': login, 'type': 'User'}, 'author_association': association,
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

    def finalize(self, state, claude_outcome='success', validation_outcome='failure', num_turns=1,
                 ci_failed=None, is_error=False, repair_run=False, store=None, head='head', gh=None):
        run = {'issue': 4, 'branch': 'agent/issue-4', 'restored': True, 'recovery': False, 'repair': repair_run,
               'startedAt': '2026-10-10T00:00:00Z', 'model': 'opus', 'includedComments': [20], 'includedIssueBody': False}
        (self.home / 'run.json').write_text(json.dumps(run))
        # validate marks a CI failure of a clean, pushed HEAD for finalize on the same runner.
        marker = self.home / agentctl.CI_FAILURE_FILE
        marker.unlink(missing_ok=True)
        if ci_failed if ci_failed is not None else validation_outcome == 'failure':
            marker.write_text(json.dumps({'head': head}))
        messages = ([{'type': 'result', 'subtype': 'success' if not is_error else 'error_during_execution',
                      'num_turns': num_turns, 'is_error': is_error, 'result': 'done', 'session_id': 'sess'}]
                    if claude_outcome == 'success' else [])
        gh = gh or mock.Mock(repository='owner/repo')
        if store is None:
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
                mock.patch.object(agentctl, 'git', return_value=head), \
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

    def test_validation_kind_is_saved_with_the_repair_before_the_restart_is_dispatched(self):
        # The write after the dispatch may be lost; the state saved before it
        # must already tell the queued run that this is a repair, not a resume.
        saved, dispatched_after = [], []
        store = mock.Mock()
        store.get_json.return_value = {'issue': 4, 'lastCommentId': 10}
        store.put_json.side_effect = lambda key, value: saved.append((key, json.loads(json.dumps(value))))
        gh = mock.Mock(repository='owner/repo')
        gh.request.side_effect = lambda *_args, **_kwargs: dispatched_after.append(len(saved))
        state, _gh = self.finalize({'issue': 4, 'lastCommentId': 10}, store=store, gh=gh)
        self.assertEqual(len(dispatched_after), 1)
        states_before_dispatch = [value for key, value in saved[:dispatched_after[0]] if key.endswith('state.json')]
        self.assertEqual(len(states_before_dispatch), 1)
        before = states_before_dispatch[0]
        self.assertEqual(before['pendingRestartKind'], 'validation')
        self.assertEqual(before['repair']['head'], 'head')
        self.assertNotIn('restartKind', before)
        self.assertEqual(state['restartKind'], 'validation')
        self.assertNotIn('pendingRestartKind', state)

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

    def test_failed_claude_execution_drops_a_recorded_repair_and_resumes(self):
        stale = {'issue': 4, 'lastCommentId': 10, 'pendingRestartKind': 'validation',
                 'repair': {'includedComments': [20], 'includedIssueBody': False, 'head': 'head'}}
        for kwargs in ({'is_error': True}, {'claude_outcome': 'failure', 'validation_outcome': 'skipped'},
                       {'num_turns': 0}):
            state, gh = self.finalize(stale, **kwargs)
            self.assertEqual(state['restartKind'], 'interrupted', kwargs)
            self.assertNotIn('repair', state, kwargs)
            self.assertNotIn('pendingRestartKind', state, kwargs)
            gh.request.assert_called_once()

    def test_interrupted_repair_run_keeps_its_repair_for_the_resume(self):
        before = {'issue': 4, 'lastCommentId': 10, 'autoRestarts': 1,
                  'repair': {'includedComments': [20], 'includedIssueBody': False, 'head': 'head'}}
        # The repair's own session exists (Claude failed inside it): the restart resumes it.
        state, _gh = self.finalize(before, is_error=True, validation_outcome='skipped', repair_run=True)
        self.assertEqual(state['restartKind'], 'interrupted')
        self.assertTrue(state['sessionRepair'])
        self.assertEqual(state['repair'], before['repair'])
        # Cancelled before any session of its own was written: a resume would load
        # the pre-repair session, so the restart is a repair in a new session.
        state, _gh = self.finalize(before, claude_outcome='cancelled', validation_outcome='skipped', repair_run=True)
        self.assertEqual(state['restartKind'], 'validation')
        self.assertFalse(state['sessionRepair'])
        self.assertEqual(state['repair'], before['repair'])

    def test_unfinished_workspace_failure_restarts_interrupted_not_as_repair(self):
        # validate failed before any CI check (uncommitted or unpushed work): no CI marker.
        (self.home / 'validation.json').write_text(json.dumps({'success': False, 'currentCheck': 'unit-tests'}))
        state, gh = self.finalize({'issue': 4, 'lastCommentId': 10}, validation_outcome='failure', ci_failed=False)
        self.assertEqual(state['restartKind'], 'interrupted')
        self.assertNotIn('repair', state)
        self.assertNotIn('pendingRestartKind', state)
        gh.request.assert_called_once()
        self.assertIn('保存した作業とセッションから', gh.comment.call_args.args[1])

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

    def test_validation_repair_history_is_the_failed_runs_authorized_snapshot(self):
        state = {'issue': 4, 'branch': 'agent/issue-4', 'sessionId': 'sess', 'lastCommentId': 10,
                 'restartKind': 'validation', 'autoRestarts': 1, 'issueBodyProcessed': True,
                 'repair': {'includedComments': [20], 'includedIssueBody': False, 'head': 'headsha'},
                 'lastRun': {'success': False, 'noOp': False, 'turnUsage': {'input': 5}}}
        comments = [comment(5, login='stranger', body='古い部外者コメント', association='NONE'),
                    comment(10, body='処理済みの依頼'),
                    comment(20, body='失敗したrunの依頼'),
                    comment(25, login='stranger', body='部外者の後出しコメント', association='NONE'),
                    comment(30, body='権限者の新しい依頼')]
        _run, prompt, _saved, _restore = self.prepare(state, comments, automatic=True)
        self.assertIn('処理済みの依頼', prompt)
        self.assertIn('失敗したrunの依頼', prompt)
        self.assertNotIn('古い部外者コメント', prompt)
        self.assertNotIn('部外者の後出しコメント', prompt)
        self.assertNotIn('権限者の新しい依頼', prompt)
        self.assertNotIn('<comment id=', prompt)

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

    def test_human_run_after_unfinalized_validation_failure_starts_new_session(self):
        # validate recorded the failure but finalize never ran: lastRun still says success.
        state = {'issue': 4, 'branch': 'agent/issue-4', 'sessionId': 'sess', 'lastCommentId': 10,
                 'pendingRestartKind': 'validation', 'issueBodyProcessed': True,
                 'repair': {'includedComments': [20], 'includedIssueBody': False, 'head': 'headsha'},
                 'validationFailure': {'check': 'pr-ci', 'failures': ['PR CI未成功'], 'run': 'url'},
                 'lastRun': {'success': True, 'noOp': False, 'turnUsage': {'input': 5}}}
        run, prompt, saved, restore = self.prepare(state, [comment(20), comment(30, body='新しい依頼')], automatic=False)
        restore.assert_not_called()
        self.assertFalse(run['restored'])
        self.assertTrue(run['recovery'])
        self.assertFalse(run['repair'])
        self.assertEqual(run['includedComments'], [20, 30])
        self.assertNotIn('pendingRestartKind', saved)
        self.assertNotIn('repair', saved)
        self.assertIn('失敗した後の再実行', prompt)
        self.assertIn('<comment id="30"', prompt)
        self.assertIn('<validation-failure>', prompt)

    # ---------------------------------- validation failure before finalize ---

    def validate(self, persisted, messages=None, git_state='', pushed=True):
        """Run validate against an in-memory state store; returns the state it left behind."""
        run = {'issue': 4, 'branch': 'agent/issue-4', 'headBefore': 'old', 'validationRequired': True,
               'includedComments': [20], 'includedIssueBody': False}
        (self.home / 'run.json').write_text(json.dumps(run))
        if messages is None:
            messages = [{'type': 'result', 'subtype': 'success', 'num_turns': 3, 'is_error': False}]
        store = mock.Mock()
        store.get_json.side_effect = lambda key: json.loads(json.dumps(persisted.get(key)))
        store.put_json.side_effect = lambda key, value: persisted.update({key: json.loads(json.dumps(value))})

        def git(*args, **kwargs):
            if args[0] == 'status':
                return git_state
            if args[:2] == ('rev-parse', 'FETCH_HEAD'):
                return 'failedsha' if pushed else 'remotesha'
            return 'failedsha'

        def failing_ci(run, head):
            (self.home / 'validation.json').write_text(json.dumps(
                {'success': False, 'currentCheck': 'pr-ci', 'error': 'PR CI未成功: ios.yml: completed/failure'}))
            raise agentctl.CIVerificationFailed('PR CI未成功')

        with mock.patch.object(agentctl, 'load_execution', return_value=messages), \
                mock.patch.object(agentctl, 'Store', return_value=store), \
                mock.patch.object(agentctl, 'git', side_effect=git), \
                mock.patch.object(agentctl, 'verify_pr_ci', side_effect=failing_ci) as ci:
            if git_state or not pushed:
                with self.assertRaises(SystemExit):
                    agentctl.cmd_validate(None)
                ci.assert_not_called()
            else:
                with self.assertRaisesRegex(RuntimeError, 'PR CI未成功'):
                    agentctl.cmd_validate(None)
        return persisted['sessions/4/state.json']

    def test_validate_does_not_record_a_repair_when_claude_failed(self):
        original = {'issue': 4, 'lastCommentId': 10}
        persisted = {'sessions/4/state.json': dict(original)}
        failed = [{'type': 'result', 'subtype': 'error_during_execution', 'num_turns': 3, 'is_error': True}]
        self.assertEqual(self.validate(persisted, messages=failed), original)
        self.assertFalse((self.home / agentctl.CI_FAILURE_FILE).exists())

    def test_validate_does_not_record_a_repair_for_unfinished_work(self):
        original = {'issue': 4, 'lastCommentId': 10}
        for kwargs in ({'git_state': ' M Sources/App.swift'}, {'pushed': False}):
            persisted = {'sessions/4/state.json': dict(original)}
            self.assertEqual(self.validate(persisted, **kwargs), original, kwargs)
            self.assertFalse((self.home / agentctl.CI_FAILURE_FILE).exists(), kwargs)

    def test_validation_failure_is_persisted_before_finalize_and_recovered_as_repair(self):
        persisted = {'sessions/4/state.json': {'issue': 4, 'lastCommentId': 10, 'workerStatus': 'running',
                                               'workerRun': 'https://github.com/owner/repo/actions/runs/777',
                                               'workerRunAttempt': '1'}}
        state = self.validate(persisted)
        self.assertEqual(state['pendingRestartKind'], 'validation')
        self.assertEqual(state['repair'], {'includedComments': [20], 'includedIssueBody': False, 'head': 'failedsha'})
        self.assertEqual(json.loads((self.home / agentctl.CI_FAILURE_FILE).read_text()), {'head': 'failedsha'})
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

    def recover(self, state):
        gh = mock.Mock(repository='owner/repo')
        store = mock.Mock()
        store.get_json.return_value = json.loads(json.dumps(state))
        with mock.patch.dict(os.environ, {'RECOVER_TITLE': 'Issue agent #4', 'RECOVER_RUN_ID': '777',
                                          'RECOVER_RUN_ATTEMPT': '1'}), \
                mock.patch.object(agentctl, 'GitHub', return_value=gh), \
                mock.patch.object(agentctl, 'Store', return_value=store):
            agentctl.cmd_recover(None)
        gh.request.assert_called_once()
        return store.put_json.call_args.args[1]

    def test_lost_repair_runner_restarts_as_validation_unless_its_session_was_saved(self):
        # prepare consumed both kind fields; the repair run was lost before finalize.
        running = {'issue': 4, 'workerStatus': 'running', 'workerRun': 'https://github.com/owner/repo/actions/runs/777',
                   'workerRunAttempt': '1', 'sessionId': 'pre-repair',
                   'repair': {'includedComments': [20], 'includedIssueBody': False, 'head': 'failedsha'}}
        self.assertEqual(self.recover(running)['restartKind'], 'validation')
        # The repair's own session was saved by an earlier interrupted finalize: resume it.
        self.assertEqual(self.recover(dict(running, sessionRepair=True))['restartKind'], 'interrupted')
        # No repair at all: resume as before.
        plain = {key: value for key, value in running.items() if key != 'repair'}
        self.assertEqual(self.recover(plain)['restartKind'], 'interrupted')

    def test_prepare_resumes_a_saved_repair_session_when_the_kind_was_lost(self):
        state = {'issue': 4, 'branch': 'agent/issue-4', 'sessionId': 'repair-sess', 'lastCommentId': 10,
                 'autoRestarts': 1, 'issueBodyProcessed': True, 'sessionRepair': True,
                 'repair': {'includedComments': [20], 'includedIssueBody': False, 'head': 'headsha'},
                 'lastRun': {'success': False, 'noOp': False, 'turnUsage': {'input': 5}}}
        run, prompt, _saved, restore = self.prepare(state, [comment(20)], automatic=True)
        restore.assert_called_once()
        self.assertTrue(run['repair'])
        self.assertTrue(run['restored'])
        self.assertIn('<validation-repair>', prompt)

    def test_finalize_records_whether_the_saved_session_is_the_repairs_own(self):
        # A normal run: not a repair session.
        state, _gh = self.finalize({'issue': 4, 'lastCommentId': 10}, validation_outcome='success')
        self.assertFalse(state['sessionRepair'])
        # A repair run that produced its own session (whose CI failed again): the saved session is the repair's.
        repair = {'issue': 4, 'lastCommentId': 10, 'sessionId': 'pre-repair',
                  'repair': {'includedComments': [20], 'includedIssueBody': False, 'head': 'head'}}
        state, _gh = self.finalize(repair, repair_run=True)
        self.assertTrue(state['sessionRepair'])
        self.assertEqual(state['sessionId'], 'sess')
        self.assertEqual(state['restartKind'], 'validation')
        # A repair run cancelled before it produced any session: the saved session is still the earlier
        # one, so the restart is a repair in a new session, not a resume.
        state, _gh = self.finalize(repair, claude_outcome='cancelled', validation_outcome='skipped', repair_run=True)
        self.assertFalse(state['sessionRepair'])
        self.assertEqual(state['restartKind'], 'validation')
        self.assertIn('repair', state)
        # The same interruption of a repair run that resumed its own saved session: resume it again.
        state, _gh = self.finalize(dict(repair, sessionRepair=True), claude_outcome='cancelled',
                                   validation_outcome='skipped', repair_run=True)
        self.assertTrue(state['sessionRepair'])
        self.assertEqual(state['restartKind'], 'interrupted')

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

    def test_prepare_treats_a_repair_without_any_kind_as_validation_restart(self):
        # finalize dispatched the restart but the write recording restartKind
        # was lost: the repair alone must not resume the session.
        state = {'issue': 4, 'branch': 'agent/issue-4', 'sessionId': 'sess', 'lastCommentId': 10,
                 'autoRestarts': 1, 'issueBodyProcessed': True,
                 'repair': {'includedComments': [20], 'includedIssueBody': False, 'head': 'headsha'},
                 'lastRun': {'success': True, 'noOp': False, 'turnUsage': {'input': 5}}}
        run, prompt, saved, restore = self.prepare(state, [comment(20)], automatic=True)
        restore.assert_not_called()
        self.assertTrue(run['repair'])
        self.assertNotIn('restartKind', saved)
        self.assertNotIn('pendingRestartKind', saved)
        self.assertIn('<validation-repair>', prompt)

    def test_prepare_still_resumes_an_interrupted_run_without_a_repair(self):
        state = {'issue': 4, 'branch': 'agent/issue-4', 'sessionId': 'sess', 'lastCommentId': 10,
                 'autoRestarts': 1, 'issueBodyProcessed': True,
                 'lastRun': {'success': False, 'noOp': False, 'turnUsage': {'input': 5}}}
        run, prompt, _saved, restore = self.prepare(state, [comment(20)], automatic=True)
        restore.assert_called_once()
        self.assertFalse(run['repair'])
        self.assertNotIn('<validation-repair>', prompt)

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

    # ------------------------------ repair replays the failed run's request text ---

    def persisted_store(self, persisted):
        store = mock.Mock()
        store.get_json.side_effect = lambda key: json.loads(json.dumps(persisted.get(key)))
        store.put_json.side_effect = lambda key, value: persisted.update({key: json.loads(json.dumps(value))})
        store.list.return_value = []
        return store

    def prepare_with(self, persisted, issue, comments, automatic, store=None, real_checkpoint=False, restored=False):
        gh = mock.Mock(repository='owner/repo')
        gh.issue.return_value = json.loads(json.dumps(issue))
        gh.comments.return_value = json.loads(json.dumps(comments))

        def git(*args, **kwargs):
            if args[:2] == ('rev-parse', 'origin/main'):
                return 'mainsha'  # the branch is ahead of main: its HEAD needs PR CI
            return {'log': 'abc commit', 'status': ''}.get(args[0], 'failedsha')

        restore = (mock.patch.object(agentctl, 'restore_workspace', wraps=agentctl.restore_workspace) if real_checkpoint
                   else mock.patch.object(agentctl, 'restore_workspace', return_value=None))
        with mock.patch.dict(os.environ, {'AUTOMATIC_RETRY': 'true' if automatic else 'false'}), \
                mock.patch.object(agentctl, 'GitHub', return_value=gh), \
                mock.patch.object(agentctl, 'Store', return_value=store or self.persisted_store(persisted)), \
                mock.patch.object(agentctl, 'checkout_branch', return_value=True), \
                restore, \
                mock.patch.object(agentctl, 'restore_session', return_value=restored), \
                mock.patch.object(agentctl, 'head_descends_from', return_value=True), \
                mock.patch.object(agentctl, 'git', side_effect=git), \
                mock.patch.object(agentctl, 'write_output'), \
                mock.patch.object(progress, 'update'):
            agentctl.cmd_prepare(None)
        return json.loads((self.home / 'run.json').read_text()), (self.home / 'prompt.txt').read_text()

    def fail_validation(self, persisted, store=None, ci=None):
        """validate against the run prepare left in AGENT_HOME, with a failing PR CI."""
        messages = [{'type': 'result', 'subtype': 'success', 'num_turns': 3, 'is_error': False}]

        def git(*args, **kwargs):
            return '' if args[0] == 'status' else 'failedsha'

        def failing_ci(run, head):
            (self.home / 'validation.json').write_text(json.dumps(
                {'success': False, 'currentCheck': 'pr-ci', 'error': 'PR CI未成功: ios.yml: completed/failure'}))
            raise agentctl.CIVerificationFailed('PR CI未成功')

        with mock.patch.object(agentctl, 'load_execution', return_value=messages), \
                mock.patch.object(agentctl, 'Store', return_value=store or self.persisted_store(persisted)), \
                mock.patch.object(agentctl, 'git', side_effect=git), \
                mock.patch.object(agentctl, 'verify_pr_ci', side_effect=ci or failing_ci):
            with self.assertRaisesRegex(RuntimeError, 'PR CI未成功'):
                agentctl.cmd_validate(None)

    def failed_run(self):
        """A normal run on comment 20 whose PR CI failed: returns the persisted store, issue and comments."""
        issue = {'number': 4, 'title': 'T', 'html_url': 'https://github.com/owner/repo/issues/4',
                 'body': '元のIssue本文', 'created_at': '2026-10-01T00:00:00Z',
                 'user': {'login': 'owner'}, 'author_association': 'OWNER'}
        comments = [comment(10, body='処理済みの依頼'),
                    {'id': 15, 'user': {'login': 'agent[bot]', 'type': 'Bot'}, 'author_association': 'NONE',
                     'body': '一つ目を実装しました', 'created_at': '2026-10-10T00:00:00Z'},
                    comment(20, body='元の依頼: 二つ目の項目をやって')]
        persisted = {'sessions/4/state.json': {'issue': 4, 'branch': 'agent/issue-4', 'sessionId': 'sess',
                                               'lastCommentId': 10, 'issueBodyProcessed': True,
                                               'lastRun': {'success': True, 'noOp': False, 'turnUsage': {'input': 5}}}}
        run, _prompt = self.prepare_with(persisted, issue, comments, automatic=False)
        self.assertEqual(run['includedComments'], [20])
        snapshot = json.loads((self.home / agentctl.REQUEST_SNAPSHOT_FILE).read_text())
        self.assertEqual(snapshot['issue']['body'], '元のIssue本文')
        self.assertEqual([(c['id'], c['body']) for c in snapshot['comments']],
                         [(10, '処理済みの依頼'), (15, '一つ目を実装しました'), (20, '元の依頼: 二つ目の項目をやって')])
        self.fail_validation(persisted)
        state = persisted['sessions/4/state.json']
        self.assertTrue(state['repair']['requestSnapshot'])
        self.assertEqual(state['repair']['requestSha256'], agentctl.snapshot_digest(snapshot))
        self.assertEqual(persisted['sessions/4/repair-request.json'], snapshot)
        return persisted, issue, comments

    def test_repair_uses_the_comment_text_the_failed_run_saw_even_after_an_edit(self):
        persisted, issue, comments = self.failed_run()
        comments[2]['body'] = '編集後の依頼: 三つ目の項目もやって'  # same ID, edited in place
        comments[1]['body'] = '編集されたagent返信'
        run, prompt = self.prepare_with(persisted, issue, comments, automatic=True)
        self.assertTrue(run['repair'])
        self.assertIn('元の依頼: 二つ目の項目をやって', prompt)
        self.assertIn('一つ目を実装しました', prompt)
        self.assertNotIn('編集後の依頼', prompt)
        self.assertNotIn('編集されたagent返信', prompt)
        self.assertNotIn('依頼本文の記録がない', prompt)
        # A repair that fails again keeps the same record instead of re-reading GitHub.
        self.assertEqual(json.loads((self.home / agentctl.REQUEST_SNAPSHOT_FILE).read_text()),
                         persisted['sessions/4/repair-request.json'])

    def test_repair_uses_the_issue_body_the_failed_run_saw_even_after_an_edit(self):
        persisted, issue, comments = self.failed_run()
        issue['body'] = '編集後のIssue本文: 範囲を広げた'
        _run, prompt = self.prepare_with(persisted, issue, comments, automatic=True)
        self.assertIn('元のIssue本文', prompt)
        self.assertNotIn('編集後のIssue本文', prompt)

    def test_repair_without_a_snapshot_falls_back_to_live_filtered_history_and_says_so(self):
        persisted, issue, comments = self.failed_run()
        for drop in ('object', 'pointer'):
            with self.subTest(drop=drop):
                missing = json.loads(json.dumps(persisted))
                if drop == 'object':
                    del missing['sessions/4/repair-request.json']
                else:  # state written by an older controller version: IDs only
                    missing['sessions/4/state.json']['repair'] = {'includedComments': [20], 'includedIssueBody': False,
                                                                 'head': 'failedsha'}
                edited = json.loads(json.dumps(comments))
                edited[2]['body'] = '編集後の依頼'
                edited.append(comment(25, login='stranger', body='部外者の後出し', association='NONE'))
                edited.append(comment(30, body='権限者の新しい依頼'))
                run, prompt = self.prepare_with(missing, dict(issue, body='編集後のIssue本文'), edited, automatic=True)
                self.assertTrue(run['repair'])
                self.assertEqual(run['includedComments'], [20])
                self.assertIn('<validation-repair>', prompt)
                self.assertIn('依頼本文の記録がない', prompt)
                self.assertIn('編集後の依頼', prompt)
                self.assertIn('編集後のIssue本文', prompt)
                self.assertNotIn('部外者の後出し', prompt)
                self.assertNotIn('権限者の新しい依頼', prompt)

    def test_stale_snapshot_object_is_not_replayed(self):
        persisted, issue, comments = self.failed_run()
        persisted['sessions/4/repair-request.json']['comments'][2]['body'] = '改ざんされた依頼'
        _run, prompt = self.prepare_with(persisted, issue, comments, automatic=True)
        self.assertNotIn('改ざんされた依頼', prompt)
        self.assertIn('依頼本文の記録がない', prompt)

    def test_finalize_keeps_the_snapshot_validate_stored_without_uploading_it_again(self):
        persisted, _issue, _comments = self.failed_run()
        before = json.loads(json.dumps(persisted['sessions/4/state.json']['repair']))
        store = self.persisted_store(persisted)
        state, _gh = self.finalize(persisted['sessions/4/state.json'], store=store, head='failedsha')
        self.assertEqual(state['repair'], before)
        self.assertEqual(state['restartKind'], 'validation')
        self.assertNotIn('sessions/4/repair-request.json', [call.args[0] for call in store.put_json.call_args_list])
        self.assertTrue(agentctl.snapshot_is_valid(persisted['sessions/4/repair-request.json']))

    def test_successful_repair_clears_the_snapshot_object(self):
        persisted, _issue, _comments = self.failed_run()
        store = self.persisted_store(persisted)
        state, _gh = self.finalize(persisted['sessions/4/state.json'], validation_outcome='success',
                                   store=store, head='failedsha')
        self.assertNotIn('repair', state)
        self.assertEqual(state['lastCommentId'], 20)
        self.assertEqual(persisted['sessions/4/repair-request.json']['cleared'], True)
        self.assertFalse(agentctl.snapshot_is_valid(persisted['sessions/4/repair-request.json']))

    def test_human_run_dropping_the_repair_clears_the_snapshot_object(self):
        persisted, issue, comments = self.failed_run()
        run, prompt = self.prepare_with(persisted, issue, comments + [comment(30, body='新しい依頼')], automatic=False)
        self.assertFalse(run['repair'])
        self.assertNotIn('repair', persisted['sessions/4/state.json'])
        self.assertEqual(persisted['sessions/4/repair-request.json']['cleared'], True)
        self.assertIn('<comment id="30"', prompt)

    def test_repair_uses_the_issue_title_the_failed_run_saw_even_after_an_edit(self):
        persisted, issue, comments = self.failed_run()
        self.assertEqual(persisted['sessions/4/repair-request.json']['issue']['title'], 'T')
        issue['title'] = '編集後のタイトル: 範囲を広げた'
        _run, prompt = self.prepare_with(persisted, issue, comments, automatic=True)
        self.assertIn('Issue: #4 T\n', prompt)
        self.assertNotIn('編集後のタイトル', prompt)
        # A snapshot stored before the title was captured keeps replaying and shows the live title.
        legacy = json.loads(json.dumps(persisted))
        del legacy['sessions/4/repair-request.json']['issue']['title']
        legacy['sessions/4/state.json']['repair']['requestSha256'] = agentctl.snapshot_digest(
            legacy['sessions/4/repair-request.json'])
        _run, prompt = self.prepare_with(legacy, issue, comments, automatic=True)
        self.assertIn('Issue: #4 編集後のタイトル', prompt)
        self.assertIn('元のIssue本文', prompt)
        self.assertNotIn('依頼本文の記録がない', prompt)

    # -------- a resumed session's snapshot keeps the text earlier runs were given ---

    def test_resumed_run_snapshots_earlier_requests_as_they_were_supplied(self):
        # Run 1 (new session) is shown the live thread and records it.
        persisted, issue, comments = self.failed_run()
        record = persisted['sessions/4/request-history.json']
        self.assertEqual(record['issue']['body'], '元のIssue本文')
        self.assertEqual([c['id'] for c in record['comments']], [10, 15, 20])
        # The repair succeeds: state carries no repair, the session resumes next time.
        state = persisted['sessions/4/state.json']
        state.pop('repair'); state.pop('pendingRestartKind'); state.pop('validationFailure', None)
        state.update({'lastCommentId': 20, 'lastRun': {'success': True, 'noOp': False, 'turnUsage': {'input': 5}}})
        # Earlier text is edited in place, then a new request arrives.
        issue['body'] = '編集後のIssue本文: 範囲を広げた'
        comments[2]['body'] = '編集後の依頼: 三つ目の項目もやって'
        comments.append({'id': 25, 'user': {'login': 'agent[bot]', 'type': 'Bot'}, 'author_association': 'NONE',
                         'body': '二つ目を実装しました', 'created_at': '2026-10-11T00:00:00Z'})
        comments.append(comment(30, body='三つ目の依頼'))
        run, prompt = self.prepare_with(persisted, issue, comments, automatic=False, restored=True)
        self.assertTrue(run['restored'])
        self.assertEqual(run['includedComments'], [30])
        self.assertIn('三つ目の依頼', prompt)
        self.assertNotIn('編集後の依頼', prompt)  # the transcript holds the original; only comment 30 is shown
        snapshot = json.loads((self.home / agentctl.REQUEST_SNAPSHOT_FILE).read_text())
        self.assertEqual(snapshot['issue']['body'], '元のIssue本文')
        self.assertEqual([(c['id'], c['body']) for c in snapshot['comments']],
                         [(10, '処理済みの依頼'), (15, '一つ目を実装しました'), (20, '元の依頼: 二つ目の項目をやって'),
                          (25, '二つ目を実装しました'), (30, '三つ目の依頼')])
        self.assertEqual(persisted['sessions/4/request-history.json'], snapshot)
        # Its CI fails: the repair sees what the resumed run saw, not the edited text.
        self.fail_validation(persisted)
        _run, prompt = self.prepare_with(persisted, issue, comments, automatic=True)
        self.assertIn('<validation-repair>', prompt)
        self.assertIn('元のIssue本文', prompt)
        self.assertIn('元の依頼: 二つ目の項目をやって', prompt)
        self.assertIn('三つ目の依頼', prompt)
        self.assertNotIn('編集後', prompt)

    def test_run_shown_the_live_thread_records_the_live_text(self):
        # A new session (recovery) is shown the live thread: its edited text is what the run saw.
        persisted, issue, comments = self.failed_run()
        state = persisted['sessions/4/state.json']
        state.pop('repair'); state.pop('pendingRestartKind'); state.pop('validationFailure', None)
        state.update({'lastCommentId': 20, 'lastRun': {'success': True, 'noOp': False, 'turnUsage': {'input': 5}}})
        comments[2]['body'] = '編集後の依頼'
        comments.append(comment(30, body='三つ目の依頼'))
        run, prompt = self.prepare_with(persisted, issue, comments, automatic=False, restored=False)
        self.assertTrue(run['recovery'])
        self.assertIn('編集後の依頼', prompt)
        snapshot = json.loads((self.home / agentctl.REQUEST_SNAPSHOT_FILE).read_text())
        self.assertEqual([c['body'] for c in snapshot['comments'] if c['id'] == 20], ['編集後の依頼'])
        self.assertEqual(persisted['sessions/4/request-history.json'], snapshot)

    def test_resumed_run_without_a_record_snapshots_the_live_text(self):
        persisted, issue, comments = self.failed_run()
        state = persisted['sessions/4/state.json']
        state.pop('repair'); state.pop('pendingRestartKind'); state.pop('validationFailure', None)
        state.update({'lastCommentId': 20, 'lastRun': {'success': True, 'noOp': False, 'turnUsage': {'input': 5}}})
        del persisted['sessions/4/request-history.json']  # state older than the record
        comments[2]['body'] = '編集後の依頼'
        comments.append(comment(30, body='三つ目の依頼'))
        self.prepare_with(persisted, issue, comments, automatic=False, restored=True)
        snapshot = json.loads((self.home / agentctl.REQUEST_SNAPSHOT_FILE).read_text())
        self.assertEqual([c['body'] for c in snapshot['comments'] if c['id'] == 20], ['編集後の依頼'])
        self.assertEqual(persisted['sessions/4/request-history.json'], snapshot)

    def test_lost_history_record_write_does_not_stop_the_run(self):
        persisted, issue, comments = self.failed_run()
        state = persisted['sessions/4/state.json']
        state.pop('repair'); state.pop('pendingRestartKind'); state.pop('validationFailure', None)
        state.update({'lastCommentId': 20, 'lastRun': {'success': True, 'noOp': False, 'turnUsage': {'input': 5}}})
        comments.append(comment(30, body='三つ目の依頼'))
        store = self.persisted_store(persisted)
        original = store.put_json.side_effect

        def put_json(key, value):
            if key.endswith('request-history.json'):
                raise RuntimeError('R2 down')
            return original(key, value)

        store.put_json.side_effect = put_json
        run, _prompt = self.prepare_with(persisted, issue, comments, automatic=False, store=store, restored=True)
        self.assertEqual(run['includedComments'], [30])
        self.assertEqual(persisted['sessions/4/state.json']['workerStatus'], 'running')

    # ------------------- the snapshot pointer goes before its object is cleared ---

    def ordered_store(self, persisted, fail_clear=False):
        """A persisted store whose put_json order is observable; optionally the clear overwrite fails."""
        store = self.persisted_store(persisted)
        writes = []

        def put_json(key, value):
            if fail_clear and key == 'sessions/4/repair-request.json' and value.get('cleared'):
                raise RuntimeError('store unavailable')
            writes.append((key, json.loads(json.dumps(value))))
            persisted[key] = json.loads(json.dumps(value))

        store.put_json.side_effect = put_json
        return store, writes

    def assert_pointer_removed_before_clear(self, writes):
        cleared = [i for i, (key, value) in enumerate(writes)
                   if key == 'sessions/4/repair-request.json' and value.get('cleared')]
        self.assertEqual(len(cleared), 1)
        states = [i for i, (key, _value) in enumerate(writes) if key == 'sessions/4/state.json']
        self.assertTrue(states and states[0] < cleared[0], writes)
        self.assertTrue(all('repair' not in writes[i][1] for i in states if i < cleared[0]), writes)

    def test_successful_repair_removes_the_pointer_before_clearing_the_object(self):
        persisted, _issue, _comments = self.failed_run()
        store, writes = self.ordered_store(persisted)
        state, _gh = self.finalize(persisted['sessions/4/state.json'], validation_outcome='success',
                                   store=store, head='failedsha')
        self.assertNotIn('repair', state)
        self.assert_pointer_removed_before_clear(writes)

    def test_successful_repair_survives_a_failed_object_clear(self):
        persisted, _issue, _comments = self.failed_run()
        store, _writes = self.ordered_store(persisted, fail_clear=True)
        state, gh = self.finalize(persisted['sessions/4/state.json'], validation_outcome='success',
                                  store=store, head='failedsha')
        self.assertNotIn('repair', state)
        self.assertNotIn('repair', persisted['sessions/4/state.json'])
        self.assertTrue(agentctl.snapshot_is_valid(persisted['sessions/4/repair-request.json']))  # dead object left behind
        gh.request.assert_not_called()
        self.assertNotIn('失敗', gh.comment.call_args.args[1])

    def test_human_run_removes_the_pointer_before_clearing_the_object(self):
        persisted, issue, comments = self.failed_run()
        store, writes = self.ordered_store(persisted)
        run, _prompt = self.prepare_with(persisted, issue, comments + [comment(30)], automatic=False, store=store)
        self.assertFalse(run['repair'])
        self.assert_pointer_removed_before_clear(writes)

    def test_human_run_survives_a_failed_object_clear(self):
        persisted, issue, comments = self.failed_run()
        store, _writes = self.ordered_store(persisted, fail_clear=True)
        run, prompt = self.prepare_with(persisted, issue, comments + [comment(30)], automatic=False, store=store)
        self.assertFalse(run['repair'])
        self.assertNotIn('repair', persisted['sessions/4/state.json'])
        self.assertIn('<comment id="30"', prompt)

    # ------------------------- only an explicit CI result is a CI verification failure ---

    def verify(self, find, messages=None):
        """cmd_validate on a clean, pushed HEAD whose PR CI lookup behaves like `find`."""
        run = {'issue': 4, 'branch': 'agent/issue-4', 'headBefore': 'old', 'validationRequired': True,
               'includedComments': [20], 'includedIssueBody': False}
        (self.home / 'run.json').write_text(json.dumps(run))
        (self.home / 'pr-ci.json').write_text(json.dumps(
            {'head': 'failedsha', 'branch': 'agent/issue-4', 'request': 'unique', 'dispatched': list(agentctl.PR_CI_WORKFLOWS)}))
        (self.home / agentctl.CI_FAILURE_FILE).unlink(missing_ok=True)
        persisted = {'sessions/4/state.json': {'issue': 4, 'lastCommentId': 10}}
        if messages is None:
            messages = [{'type': 'result', 'subtype': 'success', 'num_turns': 3, 'is_error': False}]
        with mock.patch.object(agentctl, 'load_execution', return_value=messages), \
                mock.patch.object(agentctl, 'Store', return_value=self.persisted_store(persisted)), \
                mock.patch.object(agentctl, 'GitHub', return_value=mock.Mock(repository='owner/repo')), \
                mock.patch.object(agentctl, 'git', side_effect=lambda *args, **kwargs: '' if args[0] == 'status' else 'failedsha'), \
                mock.patch.object(agentctl, 'find_pr_ci_run', side_effect=find):
            try:
                agentctl.cmd_validate(None)
            except Exception as error:  # noqa: BLE001 - the test inspects the type
                return error, persisted['sessions/4/state.json']
        return None, persisted['sessions/4/state.json']

    def test_ci_status_query_errors_are_not_ci_verification_failures(self):
        for error in (RuntimeError('GitHub API unavailable'), KeyError('workflow_runs'), TypeError('unexpected response')):
            with self.subTest(error=type(error).__name__):
                raised, state = self.verify(mock.Mock(side_effect=error))
                self.assertIsNotNone(raised)
                self.assertNotIsInstance(raised, agentctl.CIVerificationFailed)
                self.assertNotIsInstance(raised, SystemExit)
                self.assertEqual(state, {'issue': 4, 'lastCommentId': 10})  # no repair recorded
                self.assertFalse((self.home / agentctl.CI_FAILURE_FILE).exists())
                self.assertFalse(json.loads((self.home / 'validation.json').read_text())['success'])

    def test_explicit_ci_result_is_a_ci_verification_failure(self):
        failed = {'id': 10, 'run_attempt': 1, 'html_url': 'https://github.com/owner/repo/actions/runs/10',
                  'head_sha': 'failedsha', 'status': 'completed', 'conclusion': 'failure'}
        for name, find in (('failed conclusion', mock.Mock(return_value=failed)),
                           ('run for the request not found', mock.Mock(return_value=None))):
            with self.subTest(name):
                raised, state = self.verify(find)
                self.assertIsInstance(raised, agentctl.CIVerificationFailed)
                self.assertEqual(state['pendingRestartKind'], 'validation')
                self.assertEqual(state['repair']['head'], 'failedsha')
                self.assertTrue((self.home / agentctl.CI_FAILURE_FILE).exists())
                self.assertIn('PR CI未成功', state['validationFailure']['failures'][0])

    # --------------- a restored checkpoint is cleared when the failure is recorded ---

    def test_validation_failure_clears_the_checkpoint_the_failed_run_restored(self):
        issue = {'number': 4, 'title': 'T', 'html_url': 'https://github.com/owner/repo/issues/4', 'body': 'body',
                 'created_at': '2026-10-01T00:00:00Z', 'user': {'login': 'owner'}, 'author_association': 'OWNER'}
        # The failed run restored this checkpoint: it describes the HEAD before the run's commits.
        stale = {'head': 'oldsha', 'remoteHead': 'oldsha', 'branch': 'agent/issue-4',
                 'prefix': 'sessions/4/checkpoints/700-1', 'bundle': False}
        persisted = {'sessions/4/state.json': {'issue': 4, 'branch': 'agent/issue-4', 'lastCommentId': 10,
                                               'issueBodyProcessed': True,
                                               'lastRun': {'success': True, 'noOp': False, 'turnUsage': {'input': 5}}},
                     'sessions/4/workspace.json': dict(stale)}
        self.prepare_with(persisted, issue, [comment(20)], automatic=False)
        persisted['sessions/4/workspace.json'] = dict(stale)  # prepare is mocked out of restoring it
        with mock.patch.object(agentctl, 'git', return_value='failedsha'):
            with self.assertRaisesRegex(RuntimeError, 'ブランチが更新されています'):
                agentctl.restore_workspace(self.persisted_store(persisted), 4, 'agent/issue-4')
        self.fail_validation(persisted)  # the runner is lost right after this, before finalize
        self.assertEqual(persisted['sessions/4/workspace.json'], {'empty': True})
        self.assertEqual(persisted['sessions/4/state.json']['pendingRestartKind'], 'validation')
        run, prompt = self.prepare_with(persisted, issue, [comment(20)], automatic=True, real_checkpoint=True)
        self.assertTrue(run['repair'])
        self.assertIn('<validation-repair>', prompt)
        self.assertIn('Workspace checkpoint: なし', prompt)

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
