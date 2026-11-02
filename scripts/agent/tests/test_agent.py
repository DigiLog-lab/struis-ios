"""Unit tests for the Issue agent scripts: python3 -m unittest discover -s scripts/agent/tests"""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import agentctl  # noqa: E402
import agentlib  # noqa: E402
import appstoreconnect  # noqa: E402
import cleanup  # noqa: E402
import prototype  # noqa: E402
import refresh  # noqa: E402
import verify_report  # noqa: E402

SHA = 'a' * 40


def comment(identifier, login='owner', association='OWNER', kind='User', body='hello'):
    return {'id': identifier, 'user': {'login': login, 'type': kind}, 'author_association': association,
            'body': body, 'created_at': '2026-10-10T00:00:00Z'}


ISSUE = {'number': 4, 'title': 'T', 'html_url': 'https://github.com/o/r/issues/4', 'user': {'login': 'owner'},
         'author_association': 'OWNER', 'created_at': '2026-10-09T00:00:00Z', 'body': 'やること', 'state': 'open',
         'labels': [{'name': 'agent'}]}


def git(cwd, *args):
    return subprocess.run(['git', *args], cwd=cwd, check=True, capture_output=True, text=True).stdout.strip()


class FakeStore:
    def __init__(self, objects=None):
        self.objects = dict(objects or {})
        self.uploaded = []

    def get_json(self, key):
        return json.loads(json.dumps(self.objects[key])) if key in self.objects else None

    def put_json(self, key, value, **_):
        self.objects[key] = json.loads(json.dumps(value))

    def update_json(self, key, change, default=None, attempts=8):
        self.objects[key] = change(self.get_json(key) or json.loads(json.dumps(default)))
        return self.objects[key]

    def upload_file(self, key, path, content_type):
        self.uploaded.append(key)

    def list(self, prefix):
        return []


class PendingWorkTests(unittest.TestCase):
    def setUp(self):
        patch = mock.patch.dict(os.environ, {'AGENT_ALLOWED_USERS': ''})
        patch.start()
        self.addCleanup(patch.stop)

    def test_only_new_comments_from_allowed_people(self):
        comments = [comment(1), comment(5), comment(6, 'github-actions[bot]', 'NONE', 'Bot'),
                    comment(7, 'stranger', 'NONE'), comment(8, body=f'{agentlib.REPLY_MARKER} reply'),
                    comment(9, 'member', 'COLLABORATOR')]
        pending = agentlib.pending_comments(comments, {'lastCommentId': 4})
        self.assertEqual([item['id'] for item in pending], [5, 9])

    def test_explicit_allow_list_overrides_association(self):
        with mock.patch.dict(os.environ, {'AGENT_ALLOWED_USERS': 'Alice'}):
            comments = [comment(1, 'alice', 'NONE'), comment(2, 'owner', 'OWNER')]
            self.assertEqual([item['id'] for item in agentlib.pending_comments(comments, {})], [1])

    def test_a_red_verification_is_work_even_without_a_new_comment(self):
        state = {'issueBodyProcessed': True, 'lastCommentId': 9, 'verifyFailure': {'pr': 3}}
        pending, body, failure = agentctl.has_work(ISSUE, [comment(9)], state)
        self.assertEqual((pending, body), ([], False))
        self.assertEqual(failure, {'pr': 3})


class PromptTests(unittest.TestCase):
    def test_first_run_sees_the_issue_body_only(self):
        prompt = agentctl.build_prompt('<ctx/>', ISSUE, [], [comment(2)], {}, None)
        self.assertIn('<issue-body', prompt)
        self.assertNotIn('<thread>', prompt)
        self.assertIn('<comment id="2"', prompt)

    def test_later_runs_rebuild_the_thread_with_agent_replies_and_decisions(self):
        reply = comment(3, 'github-actions[bot]', 'NONE', 'Bot',
                        f'{agentlib.REPLY_MARKER}\n\n答え\n\n<details><summary>セッション情報</summary>表</details>')
        state = {'issueBodyProcessed': True, 'decisions': [{'at': 'x', 'text': 'SwiftMathにする'}]}
        prompt = agentctl.build_prompt('<ctx/>', ISSUE, [comment(2), reply], [comment(4, body='次')], state, None)
        self.assertIn('<thread>', prompt)
        self.assertIn('role="agent"', prompt)
        self.assertIn('答え', prompt)
        self.assertNotIn('セッション情報', prompt)
        self.assertIn('SwiftMathにする', prompt)
        self.assertIn('<comment id="4"', prompt)

    def test_a_red_verification_is_handed_over_with_its_failures(self):
        failure = {'pr': 3, 'sha': SHA, 'failed': [{'job': 'verify', 'steps': ['単体テスト']}]}
        prompt = agentctl.build_prompt('<ctx/>', ISSUE, [], [], {'issueBodyProcessed': True}, failure)
        self.assertIn('<verify-failure>', prompt)
        self.assertIn('単体テスト', prompt)

    def test_merge_outcomes_are_described_for_claude(self):
        self.assertIn('最新のmainを含んで', agentctl.describe_merge({'status': 'up-to-date'}))
        self.assertIn('3コミット', agentctl.describe_merge({'status': 'merged', 'behind': 3}))
        self.assertIn('a.swift', agentctl.describe_merge({'status': 'conflict', 'behind': 1, 'files': ['a.swift']}))


class BranchTests(unittest.TestCase):
    """merge_main and fetch_handoff against a real origin."""

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        root = Path(self.temp.name)
        self.origin, self.work = root / 'origin.git', root / 'work'
        git(root, 'init', '--bare', '-b', 'main', str(self.origin))
        git(root, 'clone', str(self.origin), str(self.work))
        for key, value in (('user.name', 't'), ('user.email', 't@example.com')):
            git(self.work, 'config', key, value)
        (self.work / 'a.txt').write_text('base\n')
        git(self.work, 'add', '.')
        git(self.work, 'commit', '-m', 'base')
        git(self.work, 'push', 'origin', 'main')
        patch = mock.patch.dict(os.environ, {'GITHUB_WORKSPACE': str(self.work)})
        patch.start()
        self.addCleanup(patch.stop)

    def advance_main(self, text):
        other = Path(self.temp.name) / f'other-{len(text)}'
        git(self.temp.name, 'clone', str(self.origin), str(other))
        for key, value in (('user.name', 't'), ('user.email', 't@example.com')):
            git(other, 'config', key, value)
        (other / 'a.txt').write_text(text)
        git(other, 'commit', '-am', 'main moves')
        git(other, 'push', 'origin', 'main')

    def test_new_branch_starts_from_main_and_is_up_to_date(self):
        self.assertFalse(agentctl.checkout_branch('agent/issue-4'))
        self.assertEqual(agentctl.merge_main(), {'status': 'up-to-date'})

    def test_main_is_merged_into_an_existing_branch(self):
        git(self.work, 'checkout', '-b', 'agent/issue-4')
        (self.work / 'b.txt').write_text('work\n')
        git(self.work, 'add', '.')
        git(self.work, 'commit', '-m', 'work')
        git(self.work, 'push', 'origin', 'agent/issue-4')
        self.advance_main('main\n')
        self.assertTrue(agentctl.checkout_branch('agent/issue-4'))
        merge = agentctl.merge_main()
        self.assertEqual((merge['status'], merge['behind']), ('merged', 1))
        self.assertEqual((self.work / 'a.txt').read_text(), 'main\n')
        self.assertEqual((self.work / 'b.txt').read_text(), 'work\n')

    def test_a_conflict_is_aborted_and_reported(self):
        git(self.work, 'checkout', '-b', 'agent/issue-4')
        (self.work / 'a.txt').write_text('branch\n')
        git(self.work, 'commit', '-am', 'work')
        git(self.work, 'push', 'origin', 'agent/issue-4')
        self.advance_main('main side\n')
        agentctl.checkout_branch('agent/issue-4')
        merge = agentctl.merge_main()
        self.assertEqual((merge['status'], merge['files']), ('conflict', ['a.txt']))
        self.assertEqual(git(self.work, 'status', '--porcelain'), '')
        self.assertEqual((self.work / 'a.txt').read_text(), 'branch\n')

    def test_handoff_files_are_unpacked_and_absent_branch_is_none(self):
        home = Path(self.temp.name) / 'home'
        home.mkdir()
        self.assertIsNone(agentctl.fetch_handoff(4, home))
        git(self.work, 'checkout', '--orphan', 'handoff/issue-4')
        git(self.work, 'rm', '-rfq', '.')
        (self.work / 'ref').mkdir()
        (self.work / 'ref' / 'card.png').write_bytes(b'png')
        git(self.work, 'add', '.')
        git(self.work, 'commit', '-m', 'handoff')
        git(self.work, 'push', 'origin', 'handoff/issue-4')
        git(self.work, 'checkout', 'main')
        destination = agentctl.fetch_handoff(4, home)
        self.assertEqual((destination / 'ref' / 'card.png').read_bytes(), b'png')


class PrepareTests(BranchTests):
    def test_prepare_builds_the_turn_from_the_thread_main_and_handoff(self):
        home = Path(self.temp.name) / 'home'
        output = Path(self.temp.name) / 'output'
        store = FakeStore({'sessions/4/state.json': {'issueBodyProcessed': True, 'lastCommentId': 2,
                                                     'branch': 'agent/issue-4'}})
        gh = mock.Mock(repository='o/r')
        gh.issue.return_value = ISSUE
        gh.comments.return_value = [comment(2, body='前の指示'), comment(3, body='画面を直して')]
        env = {'AGENT_HOME': str(home), 'GITHUB_OUTPUT': str(output), 'ISSUE_NUMBER': '4',
               'GITHUB_REPOSITORY': 'o/r', 'AGENT_ALLOWED_USERS': ''}
        with mock.patch.dict(os.environ, env), mock.patch.object(agentctl, 'GitHub', return_value=gh), \
                mock.patch.object(agentctl, 'Store', return_value=store), mock.patch('progress.update'):
            agentctl.cmd_prepare(None)
        prompt = (home / 'prompt.txt').read_text()
        self.assertIn('<thread>', prompt)
        self.assertIn('前の指示', prompt)
        self.assertIn('<comment id="3"', prompt)
        self.assertIn('main: 最新のmainを含んでいます', prompt)
        run = json.loads((home / 'run.json').read_text())
        self.assertEqual(run['includedComments'], [3])
        self.assertEqual(git(self.work, 'rev-parse', '--abbrev-ref', 'HEAD'), 'agent/issue-4')
        self.assertIn('skip=false', output.read_text())
        self.assertEqual(store.objects['sessions/4/state.json']['workerStatus'], 'running')

    def test_nothing_new_skips_the_runner(self):
        home = Path(self.temp.name) / 'home'
        store = FakeStore({'sessions/4/state.json': {'issueBodyProcessed': True, 'lastCommentId': 3}})
        gh = mock.Mock(repository='o/r')
        gh.issue.return_value = ISSUE
        gh.comments.return_value = [comment(3)]
        with mock.patch.dict(os.environ, {'AGENT_HOME': str(home), 'GITHUB_OUTPUT': str(home / 'out'), 'ISSUE_NUMBER': '4'}), \
                mock.patch.object(agentctl, 'GitHub', return_value=gh), mock.patch.object(agentctl, 'Store', return_value=store):
            agentctl.cmd_prepare(None)
        self.assertIn('skip=true', (home / 'out').read_text())


class FinalizeTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.home = Path(self.temp.name)
        (self.home / 'artifacts').mkdir()
        self.execution = self.home / 'execution.json'
        patch = mock.patch.dict(os.environ, {
            'AGENT_HOME': str(self.home), 'CLAUDE_EXECUTION_FILE': str(self.execution), 'GITHUB_REPOSITORY': 'o/r',
            'GITHUB_RUN_ID': '7', 'GITHUB_STEP_SUMMARY': str(self.home / 'summary.md'), 'SOME_API_KEY': 'topsecret-value'})
        patch.start()
        self.addCleanup(patch.stop)
        failure = {'pr': 3, 'sha': SHA}
        (self.home / 'run.json').write_text(json.dumps({
            'issue': 4, 'branch': 'agent/issue-4', 'model': 'opus', 'startedAt': '2026-11-02T00:00:00Z',
            'includedComments': [5], 'includedIssueBody': True, 'verifyFailure': failure}))
        self.store = FakeStore({'sessions/4/state.json': {'lastCommentId': 2, 'verifyFailure': failure}})
        self.gh = mock.Mock(repository='o/r')
        (self.home / 'artifacts' / 'log.txt').write_text('key=topsecret-value\n')

    def finalize(self, messages):
        self.execution.write_text(json.dumps(messages))
        with mock.patch.object(agentctl, 'GitHub', return_value=self.gh), \
                mock.patch.object(agentctl, 'Store', return_value=self.store), \
                mock.patch('progress.update'), mock.patch('progress.stop_owned_commands'):
            agentctl.cmd_finalize(None)
        return self.store.objects['sessions/4/state.json'], self.gh.comment.call_args.args[1]

    def test_success_marks_the_requests_processed_and_clears_the_fixed_failure(self):
        state, body = self.finalize([{'type': 'result', 'subtype': 'success', 'is_error': False, 'num_turns': 3,
                                      'result': '直しました', 'session_id': 's'}])
        self.assertEqual(state['lastCommentId'], 5)
        self.assertTrue(state['issueBodyProcessed'])
        self.assertNotIn('verifyFailure', state)
        self.assertIn('直しました', body)
        self.assertNotIn('topsecret-value', (self.home / 'artifacts' / 'log.txt').read_text())

    def test_failure_leaves_the_requests_pending_and_does_not_restart(self):
        with self.assertRaises(SystemExit):
            self.finalize([{'type': 'result', 'subtype': 'error_max_turns', 'is_error': True, 'num_turns': 3}])
        state = self.store.objects['sessions/4/state.json']
        self.assertEqual(state['lastCommentId'], 2)
        self.assertIn('verifyFailure', state)
        body = self.gh.comment.call_args.args[1]
        self.assertIn('途中で止まりました', body)
        self.gh.request.assert_not_called()  # no dispatch: nothing restarts on its own


class RecordTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.home = Path(self.temp.name)
        patch = mock.patch.dict(os.environ, {'AGENT_HOME': str(self.home)})
        patch.start()
        self.addCleanup(patch.stop)

    def test_redaction_of_values_patterns_and_binary_files(self):
        environment = {'X_TOKEN': 'value-123456', 'PLAIN': 'not-a-secret'}
        text = agentlib.redact('a value-123456 b sk-ant-oat01-AAAAAAAAAAAAAAAAAAAAAAAA Authorization: Bearer xyz not-a-secret', environment)
        self.assertNotIn('value-123456', text)
        self.assertNotIn('sk-ant-', text)
        self.assertNotIn('xyz', text)
        self.assertIn('not-a-secret', text)
        (self.home / 'a.log').write_text('value-123456')
        (self.home / 'b.bin').write_bytes(b'\x00value-123456\x00')
        self.assertEqual(agentlib.redact_tree(self.home, environment), 2)
        self.assertEqual((self.home / 'b.bin').read_bytes(), b'\x00************\x00')

    def test_session_records_stay_valid_json_and_keep_usage_numbers(self):
        environment = {'X_TOKEN': 'value-123456'}
        record = {'type': 'assistant', 'message': {'usage': {'input_tokens': 10, 'cache_read_input_tokens': 90},
                  'content': [{'type': 'text', 'text': 'got value-123456'}]}, 'oauth_token': 'abc', 'max_tokens': 4096}
        (self.home / 's.jsonl').write_text(json.dumps(record) + '\n' + 'not json api_key=abcdef\n')
        (self.home / 'r.json').write_text(json.dumps({'access_token': 'zzz', 'count': 2}))
        agentlib.redact_tree(self.home, environment)
        first, second = (self.home / 's.jsonl').read_text().split('\n')[:2]
        line = json.loads(first)
        self.assertEqual(line['message']['usage'], {'input_tokens': 10, 'cache_read_input_tokens': 90})
        self.assertEqual(line['max_tokens'], 4096)
        self.assertEqual(line['oauth_token'], '[REDACTED]')
        self.assertNotIn('value-123456', first)
        self.assertNotIn('abcdef', second)
        self.assertEqual(json.loads((self.home / 'r.json').read_text()), {'access_token': '[REDACTED]', 'count': 2})
        self.assertEqual(agentlib.redact('max_tokens=4096 "input_tokens": 10', {}), 'max_tokens=4096 "input_tokens": 10')

    def test_shot_records_state_commit_and_attaches(self):
        args = mock.Mock(device='booted', launch_args='-learning-feed-e2e', caption='カード', no_attach=False)
        args.name = 'timeline card'
        def capture(command, **_):
            Path(command[-1]).write_bytes(b'png')
            return mock.Mock(returncode=0)
        with mock.patch.object(agentctl.subprocess, 'run', side_effect=capture), \
                mock.patch.object(agentctl, 'git', side_effect=lambda *a, **k: SHA if a[0] == 'rev-parse' else ''):
            agentctl.cmd_shot(args)
        screens = json.loads((self.home / 'artifacts' / 'screens.json').read_text())
        self.assertEqual(screens[0]['file'], 'screens/timeline-card.png')
        self.assertEqual((screens[0]['commit'], screens[0]['launchArgs']), (SHA, '-learning-feed-e2e'))
        self.assertIn('"attach"', (self.home / 'outbox.jsonl').read_text())

    def test_failed_tests_and_their_messages_are_extracted(self):
        tree = {'testNodes': [{'nodeType': 'Unit test bundle', 'children': [
            {'nodeType': 'Test Case', 'nodeIdentifier': 'A/testOk', 'result': 'Passed'},
            {'nodeType': 'Test Case', 'nodeIdentifier': 'A/testBad', 'result': 'Failed',
             'children': [{'nodeType': 'Failure Message', 'name': 'A.swift:3: XCTAssertEqual failed'}]}]}]}
        self.assertEqual(agentctl.failure_details(tree),
                         [{'test': 'A/testBad', 'result': 'Failed', 'messages': ['A.swift:3: XCTAssertEqual failed']}])


class VerifyReportTests(unittest.TestCase):
    def event(self, conclusion):
        return {'workflow_run': {'id': 11, 'display_title': f'Verify PR #3 {SHA}', 'conclusion': conclusion,
                                 'html_url': 'https://github.com/o/r/actions/runs/11'}}

    def gh(self, head=SHA, state='open'):
        gh = mock.Mock(repository='o/r')
        pr = {'state': state, 'head': {'sha': head}, 'body': 'x <!-- struis-agent:issue=4 -->'}
        jobs = {'jobs': [{'name': 'verify', 'conclusion': 'failure', 'html_url': 'u',
                          'steps': [{'name': '単体テスト', 'conclusion': 'failure'}, {'name': 'x', 'conclusion': 'success'}]}]}
        gh.get.side_effect = lambda path: jobs if path.endswith('/jobs?per_page=100') else pr
        return gh

    def test_titles_name_the_pr_and_the_exact_commit(self):
        self.assertEqual(verify_report.parse(f'Verify PR #3 {SHA}'), (3, SHA))
        self.assertIsNone(verify_report.parse('iOS'))

    def test_red_on_the_current_head_records_and_wakes_the_agent(self):
        gh, store = self.gh(), FakeStore()
        with mock.patch.object(verify_report, 'append_summary'):
            verify_report.report(self.event('failure'), gh, store)
        status = gh.request.call_args_list[0].args
        self.assertEqual((status[1], status[2]['state']), (f'/repos/o/r/statuses/{SHA}', 'failure'))
        failure = store.objects['sessions/4/state.json']['verifyFailure']
        self.assertEqual(failure['failed'][0]['steps'], ['単体テスト'])
        self.assertEqual(gh.request.call_args_list[1].args[2]['event_type'], 'agent-issue')

    def test_green_clears_and_tells_the_issue(self):
        gh, store = self.gh(), FakeStore({'sessions/4/state.json': {'verifyFailure': {'pr': 3}}})
        with mock.patch.object(verify_report, 'append_summary'):
            verify_report.report(self.event('success'), gh, store)
        self.assertNotIn('verifyFailure', store.objects['sessions/4/state.json'])
        self.assertIn('マージできます', gh.comment.call_args.args[1])

    def test_a_stale_head_only_gets_its_status(self):
        gh, store = self.gh(head='b' * 40), FakeStore()
        with mock.patch.object(verify_report, 'append_summary'):
            verify_report.report(self.event('failure'), gh, store)
        self.assertEqual(gh.request.call_count, 1)
        gh.comment.assert_not_called()
        self.assertEqual(store.objects, {})


class CancelledVerifyTests(VerifyReportTests):
    def test_a_cancelled_run_is_an_error_and_wakes_nobody(self):
        gh, store = self.gh(), FakeStore()
        with mock.patch.object(verify_report, 'append_summary'):
            verify_report.report(self.event('cancelled'), gh, store)
        self.assertEqual(gh.request.call_args.args[2]['state'], 'error')
        self.assertEqual(gh.request.call_count, 1)
        gh.comment.assert_not_called()


class RefreshTests(unittest.TestCase):
    MAIN = 'm' * 40

    def gh(self, behind, update_error=None, heads=('a' * 40, 'n' * 40)):
        gh = mock.Mock(repository='o/r')
        pr = {'number': 3, 'draft': False, 'body': '<!-- struis-agent:issue=4 -->',
              'head': {'sha': heads[0], 'repo': {'full_name': 'o/r'}}}
        draft = dict(pr, number=5, draft=True)
        gh.paginate.return_value = [pr, draft]
        seen = iter(heads[1:] * 5)
        def get(path):
            if '/compare/' in path:
                return {'behind_by': behind}
            return {'head': {'sha': next(seen)}}
        gh.get.side_effect = get
        if update_error:
            gh.request_once.side_effect = RuntimeError(update_error)
        return gh

    def run_refresh(self, gh, store):
        with mock.patch.object(refresh, 'append_summary'):
            refresh.refresh(gh, store, self.MAIN, wait=0)

    def test_a_waiting_pr_takes_main_and_is_verified_again(self):
        gh, store = self.gh(behind=2), FakeStore()
        self.run_refresh(gh, store)
        update = gh.request_once.call_args.args
        self.assertEqual((update[1], update[2]), ('/repos/o/r/pulls/3/update-branch', {'expected_head_sha': 'a' * 40}))
        dispatched = gh.request.call_args.args[2]
        self.assertEqual(dispatched['event_type'], 'verify')
        self.assertEqual(dispatched['client_payload'], {'pr': '3', 'sha': 'n' * 40, 'issue': '4'})
        self.assertEqual(gh.request_once.call_count, 1)  # the Draft PR is left alone

    def test_a_pr_that_already_contains_main_is_untouched(self):
        gh, store = self.gh(behind=0), FakeStore()
        self.run_refresh(gh, store)
        gh.request_once.assert_not_called()
        gh.request.assert_not_called()

    def test_a_conflict_wakes_the_agent_with_the_reason(self):
        gh, store = self.gh(behind=1, update_error="GitHub PUT x: HTTP 422 b'merge conflict between base and head'"), FakeStore()
        self.run_refresh(gh, store)
        failure = store.objects['sessions/4/state.json']['verifyFailure']
        self.assertTrue(failure['conflict'])
        self.assertEqual(gh.request.call_args.args[2]['event_type'], 'agent-issue')
        prompt = agentctl.build_prompt('<ctx/>', ISSUE, [], [], {'issueBodyProcessed': True}, failure)
        self.assertIn('衝突', prompt)

    def test_a_head_that_moved_meanwhile_is_not_treated_as_a_conflict(self):
        gh, store = self.gh(behind=1, update_error="GitHub PUT x: HTTP 422 b'expected head sha didn't match current head ref.'"), FakeStore()
        self.run_refresh(gh, store)
        self.assertEqual(store.objects, {})
        gh.request.assert_not_called()


class CleanupTests(unittest.TestCase):
    def test_missing_handoff_branch_is_not_an_error(self):
        gh = mock.Mock(repository='o/r')
        gh.request.side_effect = RuntimeError("GitHub DELETE x: HTTP 422 b'Reference does not exist'")
        self.assertFalse(cleanup.delete_handoff(gh, 4))
        gh.request.side_effect = RuntimeError('GitHub DELETE x: HTTP 403')
        with self.assertRaises(RuntimeError):
            cleanup.delete_handoff(gh, 4)


class PrototypeTests(unittest.TestCase):
    def test_slot_identifiers(self):
        self.assertEqual(prototype.slot_name(7), 's07')
        record = prototype.slot_record('s07')
        self.assertEqual(record['bundleBase'], f'{prototype.PREFIX}.s07')
        self.assertEqual(record['appGroup'], f'group.{prototype.PREFIX}.s07')

    def test_redaction(self):
        with mock.patch.dict(os.environ, {'STRUIS_DELIVERY_APP_KEY': 'delivery-secret'}):
            text = prototype.redact('export STRUIS_DELIVERY_APP_KEY\\=delivery-secret and delivery-secret')
        self.assertNotIn('delivery-secret', text)

    def test_workspace_patch_changes_only_the_checkout_identity(self):
        source = Path(__file__).resolve().parents[3]
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            for relative in (prototype.WORKER_SOURCE, 'Info.plist', prototype.ICON):
                (root / relative).parent.mkdir(parents=True, exist_ok=True)
                (root / relative).write_bytes((source / relative).read_bytes())
            (root / 'Config').mkdir()
            meta = {'issue': 2, 'variant': 'b', 'bundleId': 'com.example.preview.s01'}
            with mock.patch.object(prototype, 'run') as run, mock.patch.dict(os.environ, {'STRUIS_DELIVERY_APP_KEY': ''}):
                name = prototype.patch_workspace(meta, 1, root)
            self.assertEqual(name, '2B Struis')
            self.assertIn('host: "com.example.preview.s01"', (root / prototype.WORKER_SOURCE).read_text())
            self.assertIn('badge_icon.swift', str(run.call_args[0][0][1]))



class AppStoreConnectTests(unittest.TestCase):
    def test_der_signature_conversion(self):
        r = (1).to_bytes(1, 'big')
        s = (0x80).to_bytes(1, 'big')
        der = bytes([0x30, 7, 0x02, 1]) + r + bytes([0x02, 2, 0x00]) + s
        raw = appstoreconnect._der_to_raw_signature(der)
        self.assertEqual(len(raw), 64)
        self.assertEqual(int.from_bytes(raw[:32], 'big'), 1)
        self.assertEqual(int.from_bytes(raw[32:], 'big'), 0x80)



if __name__ == '__main__':
    unittest.main()
