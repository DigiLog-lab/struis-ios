import io
import json
import os
from pathlib import Path
import sys
import tempfile
import subprocess
import time
import unittest
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import guard
import progress
import agentctl


class GateTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.home = Path(self.temp.name)
        patch = mock.patch.dict(os.environ, {'AGENT_HOME': str(self.home), 'RUNNER_TEMP': str(self.home)})
        patch.start()
        self.addCleanup(patch.stop)

    def test_failing_test_invalidates_previous_success_and_stops_checks(self):
        path = self.home / 'validation.json'
        path.write_text(json.dumps({'tree': 'old', 'success': True}))
        with mock.patch.object(guard, 'tree_to_test', return_value='new'), \
                mock.patch.object(guard, 'run_check', return_value=mock.Mock(returncode=1)) as run:
            with self.assertRaises(RuntimeError):
                guard.verify()
        self.assertEqual(run.call_count, 1)
        self.assertFalse(json.loads(path.read_text())['success'])

    def test_code_changed_during_test_cannot_be_approved(self):
        with mock.patch.object(guard, 'tree_to_test', side_effect=['before', 'after']), \
                mock.patch.object(guard, 'run_check', return_value=mock.Mock(returncode=0)):
            with self.assertRaises(RuntimeError):
                guard.verify()
        self.assertFalse(json.loads((self.home / 'validation.json').read_text())['success'])

    def test_timeout_is_not_success(self):
        with mock.patch.object(guard, 'tree_to_test', return_value='tree'), \
                mock.patch.object(guard, 'run_check', side_effect=guard.subprocess.TimeoutExpired('test', 1)):
            with self.assertRaises(guard.subprocess.TimeoutExpired):
                guard.verify()
        self.assertFalse(json.loads((self.home / 'validation.json').read_text())['success'])

    def test_signed_gate_runs_cd_script_without_upload_and_all_test_suites(self):
        with mock.patch.object(guard, 'tree_to_test', return_value='tree'), \
                mock.patch.object(guard, 'git', return_value='work-head'), \
                mock.patch.object(guard, 'run_check', return_value=mock.Mock(returncode=0)) as run:
            result = guard.verify(signed=True)
        commands = [call.args[0] for call in run.call_args_list]
        self.assertTrue(result['signedArchiveVerified'])
        self.assertTrue(any('-only-testing:striusUITests' in command for command in commands))
        self.assertTrue(any('-only-testing:striusTests' in command for command in commands))
        self.assertEqual(commands[-1][1], 'scripts/ci_archive.py')
        self.assertNotIn('--upload', commands[-1])
        self.assertEqual(run.call_args_list[-1].args[3]['GITHUB_SHA'], 'work-head')

    def test_unsigned_checks_do_not_receive_credentials(self):
        with mock.patch.dict(os.environ, {'STRUIS_DELIVERY_APP_KEY': 'secret', 'GITHUB_TOKEN': 'secret'}), \
                mock.patch.object(guard, 'tree_to_test', return_value='tree'), \
                mock.patch.object(guard, 'run_check', return_value=mock.Mock(returncode=0)) as run:
            guard.verify()
        for call in run.call_args_list:
            self.assertNotIn('STRUIS_DELIVERY_APP_KEY', call.args[3])
            self.assertNotIn('GITHUB_TOKEN', call.args[3])

    def test_publication_requires_current_tree_and_signed_archive(self):
        path = self.home / 'validation.json'
        with mock.patch.object(guard, 'git', side_effect=lambda *args: {
            ('status', '--porcelain'): '', ('rev-parse', 'HEAD'): 'new',
            ('rev-parse', 'HEAD^{tree}'): 'current',
        }[args]):
            for record in [None, {'success': False, 'tree': 'current'},
                           {'success': True, 'tree': 'old', 'signedArchiveVerified': True},
                           {'success': True, 'tree': 'current'}]:
                path.unlink(missing_ok=True)
                if record:
                    path.write_text(json.dumps(record))
                self.assertFalse(guard.publication_allowed({'headBefore': 'old'}))
            path.write_text(json.dumps({'success': True, 'tree': 'current', 'signedArchiveVerified': True}))
            self.assertTrue(guard.publication_allowed({'headBefore': 'old'}))

    def test_conversation_without_edits_needs_no_tests(self):
        with mock.patch.object(guard, 'git', side_effect=['', 'same']):
            self.assertTrue(guard.publication_allowed({'headBefore': 'same'}))
        with mock.patch.object(guard, 'git', return_value='M changed'):
            self.assertFalse(guard.publication_allowed({'headBefore': 'same'}))
        with mock.patch.object(guard, 'git', side_effect=['', 'same', 'tree']):
            self.assertFalse(guard.publication_allowed({'headBefore': 'same', 'validationRequired': True}))

    def test_push_of_main_or_other_commit_is_blocked(self):
        for update in ['refs/heads/topic head refs/heads/main old', 'refs/heads/topic other refs/heads/topic old']:
            with mock.patch.object(guard, 'git', side_effect=['', 'head']), \
                    mock.patch.object(sys, 'stdin', io.StringIO(update)), \
                    mock.patch.object(guard, 'commit_gate') as verify:
                with self.assertRaises(RuntimeError):
                    guard.push_gate()
                verify.assert_not_called()

    def test_allowed_head_push_runs_no_tests(self):
        update = 'refs/heads/topic head refs/heads/topic old\nrefs/heads/topic head refs/heads/prototype/4/a old'
        with mock.patch.object(guard, 'git', side_effect=['', 'head']), mock.patch.object(sys, 'stdin', io.StringIO(update)), mock.patch.object(guard, 'commit_gate') as commit_gate, mock.patch.object(guard, 'verify') as verify:
            guard.push_gate()
        commit_gate.assert_not_called()
        verify.assert_not_called()

    def test_matching_commit_reuses_tests_but_edit_runs_again(self):
        (self.home / 'validation.json').write_text(json.dumps({'success': True, 'tree': 'tested'}))
        with mock.patch.object(guard, 'tree_to_test', return_value='tested'), mock.patch.object(guard, 'verify') as verify:
            guard.commit_gate()
            verify.assert_not_called()
        with mock.patch.object(guard, 'tree_to_test', return_value='changed'), mock.patch.object(guard, 'verify') as verify:
            guard.commit_gate()
            verify.assert_called_once()

    def test_progress_never_records_command_secret_or_output(self):
        event = {'hook_event_name': 'PreToolUse', 'tool_name': 'Bash',
                 'tool_input': {'command': 'echo secret'}, 'tool_response': 'secret'}
        with mock.patch.object(sys, 'stdin', io.StringIO(json.dumps(event))):
            progress.hook()
        text = (self.home / 'activity.json').read_text()
        self.assertNotIn('secret', text)
        self.assertEqual(json.loads(text)['phase'], 'Bash 実行中')

    def test_final_validation_skips_build_for_conversation(self):
        (self.home / 'run.json').write_text(json.dumps({'headBefore': 'same'}))
        with mock.patch.object(agentctl, 'git', side_effect=['', 'same']), mock.patch.object(guard, 'verify') as verify:
            agentctl.cmd_validate(None)
            verify.assert_not_called()

    def test_final_validation_rejects_unpushed_head(self):
        (self.home / 'run.json').write_text(json.dumps({'headBefore': 'old', 'branch': 'agent/issue-1'}))
        with mock.patch.object(agentctl, 'git', side_effect=['', 'new', '', 'old', 'new']), \
                mock.patch.object(guard, 'verify') as verify:
            with self.assertRaises(SystemExit):
                agentctl.cmd_validate(None)
            verify.assert_not_called()

    def test_zero_turn_success_suppresses_pr_reply_attachments_and_ack(self):
        self.check_failed_finalization(no_op=True)

    def test_failed_validation_suppresses_pr_reply_attachments_and_ack(self):
        self.check_failed_finalization(no_op=False)

    def check_failed_finalization(self, no_op):
        run = {'issue': 1, 'branch': 'agent/issue-1', 'restored': False, 'recovery': False,
               'startedAt': 'now', 'model': 'opus', 'includedComments': [123], 'includedIssueBody': True}
        (self.home / 'run.json').write_text(json.dumps(run))
        result = [{'type': 'result', 'subtype': 'success', 'num_turns': 0 if no_op else 1, 'result': 'finished commit secret-result'}]
        gh = mock.Mock()
        store = mock.Mock()
        store.get_json.return_value = {}
        entries = [{'type': 'request-pr', 'title': 'PR', 'body': 'body'}, {'type': 'attach', 'path': 'photo'}]
        with mock.patch.dict(os.environ, {'VALIDATION_OUTCOME': 'success' if no_op else 'failure'}), \
                mock.patch.object(agentctl, 'GitHub', return_value=gh), \
                mock.patch.object(agentctl, 'Store', return_value=store), \
                mock.patch.object(agentctl, 'load_execution', return_value=result), \
                mock.patch.object(agentctl, 'save_session', return_value=0), \
                mock.patch.object(agentctl, 'save_workspace'), \
                mock.patch.object(guard, 'publication_allowed', return_value=no_op), \
                mock.patch.object(agentctl, 'read_outbox', return_value=entries), \
                mock.patch.object(agentctl, 'upload_attachments') as upload, \
                mock.patch.object(agentctl, 'record_prototype_events'), \
                mock.patch.object(agentctl, 'append_summary'), \
                mock.patch.object(progress, 'update'):
            with self.assertRaises(SystemExit):
                agentctl.cmd_finalize(None)
        gh.request.assert_called_once()
        self.assertIn('/actions/workflows/agent.yml/dispatches', gh.request.call_args.args[1])
        upload.assert_not_called()
        body = gh.comment.call_args.args[1]
        self.assertNotIn('secret-result', body)
        self.assertIn('0ターン' if no_op else 'PR CIが失敗', body)
        state = store.put_json.call_args.args[1]
        self.assertNotIn('lastCommentId', state)
        self.assertNotIn('issueBodyProcessed', state)
        self.assertEqual(state['lastRun']['noOp'], no_op)

    def test_failed_test_stops_running_command_immediately(self):
        start = time.monotonic()
        command = [sys.executable, '-u', '-c', 'import time; print("Test Case example failed (1 seconds)."); time.sleep(60)']
        with (self.home / 'failed.log').open('w') as stream:
            result = guard.run_check(command, stream, 60, dict(os.environ))
        self.assertEqual(result.returncode, 1)
        self.assertLess(time.monotonic() - start, 5)

    def test_zero_turn_resume_never_starts_validation(self):
        messages = [{'type': 'result', 'subtype': 'success', 'num_turns': 0, 'is_error': False}]
        with mock.patch.object(agentctl, 'load_execution', return_value=messages), \
                mock.patch.object(guard, 'verify') as verify:
            with self.assertRaisesRegex(SystemExit, '0ターン'):
                agentctl.cmd_validate(None)
        verify.assert_not_called()

    def test_zero_turn_and_legacy_zero_usage_failure_use_fresh_session(self):
        self.assertTrue(agentctl.session_needs_recovery({'lastRun': {'noOp': True}}))
        usage = dict(input=0, output=0, cacheRead=0, cacheCreation=0)
        self.assertTrue(agentctl.session_needs_recovery({'lastRun': {'success': False, 'turnUsage': usage}}))
        self.assertFalse(agentctl.session_needs_recovery({'lastRun': {'success': True, 'turnUsage': usage}}))
        self.assertFalse(agentctl.session_needs_recovery({'lastRun': {'success': False, 'turnUsage': {'input': None}}}))
        report = agentctl.analyze([{'type': 'result', 'num_turns': 1, 'subtype': 'success'}])
        self.assertFalse(agentctl.execution_is_noop(report))

    def test_validation_failure_context_survives_runner_replacement_without_env(self):
        (self.home / 'validation.json').write_text(json.dumps({'success': False, 'currentCheck': 'ui-tests'}))
        logs = self.home / 'artifacts' / 'validation-123'
        logs.mkdir(parents=True)
        (logs / 'ui-tests.log').write_text('API_TOKEN=secret\nfile.swift:75: error: scroll jumped\nTest Case scroll failed (140 seconds).\n')
        feedback = agentctl.validation_feedback(self.home)
        self.assertEqual(feedback['check'], 'ui-tests')
        self.assertIn('scroll jumped', str(feedback))
        self.assertNotIn('secret', str(feedback))

    def test_real_timeout_terminates_command(self):
        start = time.monotonic()
        with (self.home / 'timeout.log').open('w') as stream:
            with self.assertRaises(subprocess.TimeoutExpired):
                guard.run_check([sys.executable, '-c', 'import time; time.sleep(60)'], stream, 0.05, dict(os.environ))
        self.assertLess(time.monotonic() - start, 5)

    def test_final_signed_check_reuses_exact_successful_tree(self):
        with mock.patch.object(guard, 'tree_to_test', return_value='tree'), \
                mock.patch.object(guard, 'git', return_value='head'), \
                mock.patch.object(guard, 'run_check', return_value=mock.Mock(returncode=0)) as run:
            guard.verify()
            run.reset_mock()
            guard.verify(signed=True)
        self.assertEqual(run.call_count, 1)
        self.assertEqual(run.call_args.args[0][1], 'scripts/ci_archive.py')

    def test_restart_is_bounded_and_only_for_interruption(self):
        gh = mock.Mock(repository='owner/repo')
        state = {'issue': 4}
        self.assertIsNone(agentctl.restart_interrupted(gh, state, 'skipped'))
        gh.request.assert_not_called()
        for count in range(1, 4):
            self.assertIn(f'{count}/3', agentctl.restart_interrupted(gh, state, 'cancelled'))
        self.assertEqual(gh.request.call_count, 3)
        self.assertIn('停止', agentctl.restart_interrupted(gh, state, 'cancelled'))
        self.assertEqual(gh.request.call_count, 3)

    def test_claude_cancellation_is_not_reported_as_validation_failure(self):
        reason = agentctl.failure_reason({}, False, False, 'cancelled')
        self.assertIn('cancelled', reason)
        self.assertIn('検証は実行されていません', reason)
        self.assertNotIn('検証が失敗', reason)
        self.assertEqual(agentctl.failure_reason({'api_error_status': 429}, False, False, 'failure'), 429)
        self.assertIn('PR CIが失敗', agentctl.failure_reason({}, True, False, 'success'))

    def test_cleanup_does_not_kill_reused_or_unregistered_pid(self):
        (self.home / 'claude-process-123.json').write_text(json.dumps({'pid': 123, 'name': 'claude'}))
        with mock.patch.object(progress, 'process_name', return_value='different'), mock.patch.object(progress.os, 'kill') as kill:
            progress.stop_owned_commands()
        kill.assert_not_called()

    def test_cleanup_only_terminates_registered_claude(self):
        (self.home / 'claude-process-123.json').write_text(json.dumps({'pid': 123, 'name': 'claude'}))
        with mock.patch.object(progress, 'process_name', side_effect=['claude', '', '']), mock.patch.object(progress.os, 'kill') as kill:
            progress.stop_owned_commands()
        kill.assert_called_once_with(123, progress.signal.SIGTERM)

    def test_watchdog_resumes_only_current_unfinalized_run(self):
        gh = mock.Mock(repository='owner/repo')
        store = mock.Mock()
        base = {'issue': 4, 'workerRun': 'https://github.com/owner/repo/actions/runs/123', 'workerStatus': 'running'}
        with mock.patch.dict(os.environ, {'RECOVER_TITLE': 'Issue agent #4', 'RECOVER_RUN_ID': '123', 'RECOVER_RUN_ATTEMPT': '1'}), \
                mock.patch.object(agentctl, 'GitHub', return_value=gh), mock.patch.object(agentctl, 'Store', return_value=store):
            for update in [{'finalizedRun': '123'}, {'restartFromRun': '123'}, {'workerRunAttempt': '2'}, {'workerRun': 'new-run'}]:
                store.get_json.return_value = dict(base, **update)
                agentctl.cmd_recover(None)
                gh.request.assert_not_called()
            store.get_json.return_value = dict(base)
            agentctl.cmd_recover(None)
            gh.request.assert_called_once()


if __name__ == '__main__':
    unittest.main()
