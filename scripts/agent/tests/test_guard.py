import io
import json
import os
from pathlib import Path
import sys
import tempfile
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
                mock.patch.object(guard.subprocess, 'run', return_value=mock.Mock(returncode=1)) as run:
            with self.assertRaises(RuntimeError):
                guard.verify()
        self.assertEqual(run.call_count, 1)
        self.assertFalse(json.loads(path.read_text())['success'])

    def test_code_changed_during_test_cannot_be_approved(self):
        with mock.patch.object(guard, 'tree_to_test', side_effect=['before', 'after']), \
                mock.patch.object(guard.subprocess, 'run', return_value=mock.Mock(returncode=0)):
            with self.assertRaises(RuntimeError):
                guard.verify()
        self.assertFalse(json.loads((self.home / 'validation.json').read_text())['success'])

    def test_timeout_is_not_success(self):
        with mock.patch.object(guard, 'tree_to_test', return_value='tree'), \
                mock.patch.object(guard.subprocess, 'run', side_effect=guard.subprocess.TimeoutExpired('test', 1)):
            with self.assertRaises(guard.subprocess.TimeoutExpired):
                guard.verify()
        self.assertFalse(json.loads((self.home / 'validation.json').read_text())['success'])

    def test_signed_gate_runs_cd_script_without_upload_and_all_test_suites(self):
        with mock.patch.object(guard, 'tree_to_test', return_value='tree'), \
                mock.patch.object(guard, 'git', return_value='work-head'), \
                mock.patch.object(guard.subprocess, 'run', return_value=mock.Mock(returncode=0)) as run:
            result = guard.verify(signed=True)
        commands = [call.args[0] for call in run.call_args_list]
        self.assertTrue(result['signedArchiveVerified'])
        self.assertTrue(any('-only-testing:striusUITests' in command for command in commands))
        self.assertTrue(any('-only-testing:striusTests' in command for command in commands))
        self.assertEqual(commands[-1][1], 'scripts/ci_archive.py')
        self.assertNotIn('--upload', commands[-1])
        self.assertEqual(run.call_args_list[-1].kwargs['env']['GITHUB_SHA'], 'work-head')

    def test_unsigned_checks_do_not_receive_credentials(self):
        with mock.patch.dict(os.environ, {'STRUIS_DELIVERY_APP_KEY': 'secret', 'GITHUB_TOKEN': 'secret'}), \
                mock.patch.object(guard, 'tree_to_test', return_value='tree'), \
                mock.patch.object(guard.subprocess, 'run', return_value=mock.Mock(returncode=0)) as run:
            guard.verify()
        for call in run.call_args_list:
            self.assertNotIn('STRUIS_DELIVERY_APP_KEY', call.kwargs['env'])
            self.assertNotIn('GITHUB_TOKEN', call.kwargs['env'])

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

    def test_failed_validation_suppresses_pr_reply_attachments_and_ack(self):
        run = {'issue': 1, 'branch': 'agent/issue-1', 'restored': False, 'recovery': False,
               'startedAt': 'now', 'model': 'opus', 'includedComments': [123], 'includedIssueBody': True}
        (self.home / 'run.json').write_text(json.dumps(run))
        result = [{'type': 'result', 'subtype': 'success', 'result': 'finished commit secret-result'}]
        gh = mock.Mock()
        store = mock.Mock()
        store.get_json.return_value = {}
        entries = [{'type': 'request-pr', 'title': 'PR', 'body': 'body'}, {'type': 'attach', 'path': 'photo'}]
        with mock.patch.dict(os.environ, {'VALIDATION_OUTCOME': 'failure'}), \
                mock.patch.object(agentctl, 'GitHub', return_value=gh), \
                mock.patch.object(agentctl, 'Store', return_value=store), \
                mock.patch.object(agentctl, 'load_execution', return_value=result), \
                mock.patch.object(agentctl, 'save_session', return_value=0), \
                mock.patch.object(agentctl, 'read_outbox', return_value=entries), \
                mock.patch.object(agentctl, 'upload_attachments') as upload, \
                mock.patch.object(agentctl, 'record_prototype_events'), \
                mock.patch.object(agentctl, 'append_summary'), \
                mock.patch.object(progress, 'update'):
            with self.assertRaises(SystemExit):
                agentctl.cmd_finalize(None)
        gh.request.assert_not_called()
        upload.assert_not_called()
        body = gh.comment.call_args.args[1]
        self.assertNotIn('secret-result', body)
        self.assertIn('検証が失敗', body)
        state = store.put_json.call_args.args[1]
        self.assertNotIn('lastCommentId', state)
        self.assertNotIn('issueBodyProcessed', state)


if __name__ == '__main__':
    unittest.main()
