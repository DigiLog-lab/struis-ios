import copy
import base64
import hashlib
import json
import os
from pathlib import Path
import sys
import unittest
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import checkpoints
import delivery
import gate
from gate_fakes import FakeStatuses, MemoryStore, job_permissions, required_permission
from test_delivery import test_tree


class FakeGitHub:
    repository = 'owner/repo'

    def __init__(self):
        self.calls = []
        self.runs = {}
        self.gate_lists = []  # ios.yml gate-mode test lists: artifact listings
        # The token of the `control` job: a write it is not granted fails as on GitHub (HTTP 403).
        self.permissions = job_permissions('agent.yml', 'control')
        self.statuses = FakeStatuses()
        self.pr = {'number': 8, 'node_id': 'PR_8', 'state': 'open', 'draft': False,
                   'html_url': 'https://github.com/owner/repo/pull/8', 'body': '<!-- struis-agent:issue=4 -->',
                   'head': {'sha': 'a' * 40, 'ref': 'work', 'repo': {'full_name': self.repository}}}

    def get(self, path):
        if '/contents/scripts/ci/xcode-cloud-exclusions.json' in path:
            return {'content': base64.b64encode(json.dumps({'version': 1, 'methods': []}).encode()).decode()}
        if '/pulls/8' in path:
            return copy.deepcopy(self.pr)
        if '/actions/workflows/' in path:
            workflow = path.split('/workflows/')[1].split('/')[0]
            return {'workflow_runs': copy.deepcopy(self.runs.get(workflow, []))}
        if '/artifacts?' in path:
            identifier = int(path.split('/actions/runs/')[1].split('/')[0])
            return {'artifacts': [item for item in self.gate_lists if item['workflow_run']['id'] == identifier]}
        if '/actions/runs/' in path:
            identifier = int(path.rsplit('/', 1)[1])
            return copy.deepcopy(next(run for runs in self.runs.values() for run in runs if run['id'] == identifier))
        raise AssertionError(path)

    def check(self, method, path):
        needed = required_permission(method, path)
        if needed and self.permissions.get(needed) != 'write':
            raise RuntimeError(f'GitHub {method} {path}: HTTP 403 Resource not accessible by integration ({needed}: write)')

    def request(self, method, path, body=None):
        self.check(method, path)
        self.calls.append((method, path, copy.deepcopy(body)))
        if method == 'POST' and '/statuses/' in path:
            self.statuses.post(path.rsplit('/', 1)[1], body)
            return {}, ''
        if path == '/graphql':
            value = 'convertPullRequestToDraft' in body['query']
            self.pr['draft'] = value
            field = 'convertPullRequestToDraft' if value else 'markPullRequestReadyForReview'
            return {'data': {field: {'pullRequest': {'isDraft': value}}}}, ''
        return {}, ''

    def comment(self, number, body):
        self.check('comment', '')
        self.calls.append(('comment', number, body))

    def paginate(self, path):
        if '/statuses' in path:
            return self.statuses.list(path.split('/commits/')[1].split('/')[0])
        if path.endswith('/commits'):
            return [{'sha': self.pr['head']['sha']}]
        return [copy.deepcopy(self.pr)]


class GateTests(unittest.TestCase):
    def setUp(self):
        patch = mock.patch.dict(os.environ, {'AGENT_GATE_MAX_ATTEMPTS': '3', 'AGENT_GATE_BACKEND': 'github',
                                             'XCODE_CLOUD_REMAINING_MINUTES': '', 'AGENT_GATE_ESTIMATED_MINUTES': ''})
        patch.start()
        self.addCleanup(patch.stop)
        self.gh, self.store = FakeGitHub(), MemoryStore()
        self.controller = gate.Controller(self.gh, self.store, key=b"test-key", artifacts=self.store.artifacts)
        snapshot = {'issue': {'body': 'the original request'}, 'comments': []}
        items = {'items': [{'id': 'issue-1', 'complete': True, 'note': 'done'}]}
        local = {'schema': 1, 'head': 'a' * 40, 'success': True,
                 'startedAt': '2026-10-20T00:00:00Z', 'finishedAt': '2026-10-20T00:10:00Z',
                 'selection': {'uiTests': ['Class/testWorks']},
                 'scopeSha256': delivery.scope_digest(snapshot), 'itemsSha256': delivery.item_digest(items),
                 'checks': [{'name': name, 'exitCode': 0, 'seconds': 1, 'testResults': test_tree()} for name in ('build-for-testing', 'unit-tests', 'ui-tests')]}
        components = {'request-snapshot.json': snapshot, 'work-items.json': items, 'local-verification.json': local,
                      'run.json': {'includedComments': [20], 'includedIssueBody': True}}
        prefix = 'sessions/4/checkpoints/save-1'
        files = {name: json.dumps(value, ensure_ascii=False, indent=2).encode() for name, value in components.items()}
        artifact = self.store.artifacts.upload('agent-ckpt-4-save-1', files, 14)
        checkpoint = {'schema': 3, 'saveId': 'save-1', 'prefix': prefix, 'head': 'a' * 40, 'artifact': artifact,
                      'components': {name: checkpoints.digest(data) for name, data in files.items()}}
        self.request = {'request': 'req1', 'issue': 4, 'pr': 8, 'head': 'a' * 40, 'branch': 'work', 'checkpoint': checkpoint,
                        'scope': {'includedComments': [20], 'includedIssueBody': True}}
        self.store.put_json('sessions/4/gate-request.json', self.request)
        self.store.put_json('sessions/4/workspace.json', checkpoint)

    def results(self, failed=None, ui_tests=(('Class/testWorks()', 'Passed'),)):
        # What ios.yml uploads in gate mode for run 2, attempt 1.
        self.gh.gate_lists = []
        for part, tests in [('unit', [('Class/testWorks()', 'Passed')]), ('ui-0', ui_tests)]:
            tree = {'testNodes': [{'nodeType': 'Test Case', 'nodeIdentifier': name, 'result': result} for name, result in tests]}
            artifact = self.store.artifacts.upload(f'ios-gate-tests-2-1-{part}', {f'{part}.json': json.dumps(tree).encode()}, 1)
            self.gh.gate_lists.append({'id': artifact['id'], 'name': artifact['name'], 'workflow_run': {'id': 2}})
        for index, workflow in enumerate(['agent-tests.yml', 'ios.yml'], 1):
            self.gh.runs[workflow] = [{'id': index, 'run_attempt': 1, 'head_branch': 'main',
                                      'path': f'.github/workflows/{workflow}', 'status': 'completed',
                                      'conclusion': 'failure' if workflow == failed else 'success',
                                      'html_url': f'https://github.com/owner/repo/actions/runs/{index}',
                                      'display_title': ('iOS CI ' if workflow == 'ios.yml' else 'Agent tests CI ') + 'req1 ' + 'a' * 40}]

    def dispatches(self, workflow=None):
        return [call for call in self.gh.calls if isinstance(call[1], str) and '/actions/workflows/' in call[1]
                and '/dispatches' in call[1] and (not workflow or f'/{workflow}/' in call[1])]

    def wakes(self):
        return [call for call in self.gh.calls if call[1] == '/repos/owner/repo/dispatches'
                and call[2]['event_type'] == 'agent-issue']

    def test_ready_dispatch_is_main_defined_exact_sha_and_idempotent(self):
        record = self.controller.start(8, 'req1')
        self.assertEqual(record['phase'], 'waiting')
        self.assertEqual(len(self.dispatches()), 2)
        for _, _, body in self.dispatches():
            self.assertEqual(body['ref'], 'main')
            self.assertEqual(body['inputs']['source_ref'], 'a' * 40)
        self.controller.start(8, 'req1')
        self.assertEqual(len(self.dispatches()), 2)
        self.assertEqual(self.store.get_json('gates/issue-4.json')['attempts'], 1)

    def test_head_change_drafts_and_old_success_never_wakes_worker(self):
        record = self.controller.start(8)
        self.results()
        self.gh.pr['head']['sha'] = 'b' * 40
        self.controller.poll(record)
        self.assertTrue(self.gh.pr['draft'])
        self.assertEqual(self.store.get_json('gates/pr-8.json')['phase'], 'invalidated')
        self.assertEqual(self.wakes(), [])

    def test_green_gate_wakes_once_and_linux_route_completes_original_scope(self):
        record = self.controller.start(8)
        self.results()
        self.controller.poll(record)
        self.controller.poll(self.store.get_json('gates/pr-8.json'))
        self.assertEqual(len(self.wakes()), 1)
        self.assertEqual(self.wakes()[0][2]['client_payload'], {'issue': '4', 'automatic_retry': 'true', 'gate_result': 'req1'})
        self.assertFalse(gate.consume_result(4, 'req1', self.gh, self.store))
        state = self.store.get_json('sessions/4/state.json')
        self.assertEqual(state['validatedHead'], 'a' * 40)
        self.assertEqual(state['lastCommentId'], 20)
        self.assertTrue(state['issueBodyProcessed'])
        self.assertTrue(self.store.get_json('sessions/4/workspace.json')['closed'])
        self.assertFalse(gate.consume_result(4, 'req1', self.gh, self.store))

    def test_red_gate_returns_to_draft_and_repairs_frozen_request(self):
        record = self.controller.start(8)
        self.results(failed='ios.yml')
        self.controller.poll(record)
        self.assertTrue(self.gh.pr['draft'])
        self.assertTrue(gate.consume_result(4, 'req1', self.gh, self.store))
        state = self.store.get_json('sessions/4/state.json')
        self.assertEqual(state['repair']['head'], 'a' * 40)
        self.assertEqual(state['repair']['includedComments'], [20])
        self.assertEqual(self.store.get_json('sessions/4/repair-request.json')['issue']['body'], 'the original request')
        self.assertNotIn('issueBodyProcessed', state)

    def test_latest_attempt_and_exact_request_head_are_required(self):
        record = self.controller.start(8)
        self.results()
        wrong = dict(self.gh.runs['ios.yml'][0], id=99, display_title='iOS CI req1 ' + 'b' * 40)
        self.gh.runs['ios.yml'].append(wrong)
        self.gh.runs['agent-tests.yml'][0].update(run_attempt=2, conclusion='failure')
        result = self.controller.poll(record)
        self.assertFalse(result['success'])
        self.assertEqual(result['results']['ios.yml']['id'], 2)
        self.assertEqual(result['results']['agent-tests.yml']['attempt'], 2)

    def test_missing_local_record_and_issue_attempt_limit_block_without_dispatch(self):
        self.store.put_json('gates/issue-4.json', {'attempts': 3})
        with self.assertRaisesRegex(RuntimeError, 'limit'):
            self.controller.start(8)
        self.assertEqual(self.dispatches(), [])
        self.gh.pr['draft'] = False
        del self.store.artifacts.items[1]['files']['local-verification.json']
        with self.assertRaisesRegex(RuntimeError, 'Incomplete'):
            self.controller.start(8)
        self.assertTrue(self.gh.pr['draft'])

    def test_stale_gate_wake_cannot_complete_or_repair_new_head(self):
        self.controller.start(8)
        self.results()
        self.controller.poll(self.store.get_json('gates/pr-8.json'))
        self.gh.pr['head']['sha'] = 'b' * 40
        self.assertFalse(gate.consume_result(4, 'req1', self.gh, self.store))
        self.assertIsNone(self.store.get_json('sessions/4/state.json'))

    def test_committed_config_needs_no_repository_variable(self):
        with mock.patch.dict(os.environ, {'AGENT_GATE_BACKEND': '', 'AGENT_GATE_MAX_ATTEMPTS': ''}):
            self.assertEqual(gate.backend(), 'xcode-cloud')
            self.assertEqual(gate.max_attempts(), 3)

    def test_cloud_refusal_falls_back_to_github_but_a_lost_response_does_not(self):
        workflow = {'id': 'wf', 'relationships': {'repository': {'data': {'id': 'repo'}}}}
        with mock.patch.dict(os.environ, {'AGENT_GATE_BACKEND': 'xcode-cloud'}), \
                mock.patch.object(gate, 'cloud_workflow', return_value=workflow), \
                mock.patch.object(gate, 'cloud_client'), \
                mock.patch.object(gate, 'start_cloud_build', side_effect=gate.CloudStartRejected(
                    'App Store Connect POST /v1/ciBuildRuns: HTTP 409 compute hours exhausted')):
            record = self.controller.start(8)
        self.assertEqual(record['backend'], 'github')
        self.assertIn('HTTP 409', record['cloudStartError'])
        self.assertEqual(len(self.dispatches('ios.yml')), 1)
        self.store.put_json('gates/pr-8.json', {})
        self.gh.pr['draft'] = False
        with mock.patch.dict(os.environ, {'AGENT_GATE_BACKEND': 'xcode-cloud'}), \
                mock.patch.object(gate, 'cloud_workflow', return_value=workflow), \
                mock.patch.object(gate, 'cloud_client'), \
                mock.patch.object(gate, 'start_cloud_build', side_effect=OSError('connection reset')), \
                self.assertRaises(OSError):
            self.controller.start(8, 'req1')
        self.assertEqual(len(self.dispatches('ios.yml')), 1)
        self.assertTrue(self.gh.pr['draft'])

    def test_only_an_http_4xx_counts_as_a_refused_start(self):
        client = mock.Mock()
        client.request.side_effect = RuntimeError('App Store Connect POST /v1/ciBuildRuns: HTTP 409 {"errors": []}')
        with self.assertRaises(gate.CloudStartRejected):
            gate.post_build(client, 'wf', 'ref')
        client.request.side_effect = RuntimeError('App Store Connect POST /v1/ciBuildRuns: HTTP 503 unavailable')
        with self.assertRaises(RuntimeError) as raised:
            gate.post_build(client, 'wf', 'ref')
        self.assertNotIsInstance(raised.exception, gate.CloudStartRejected)

    def test_gate_outcome_requires_the_controller_status_not_only_the_store_record(self):
        record = self.controller.start(8)
        self.results()
        self.controller.poll(record)
        # A forged store record cannot complete the Issue without the controller's status...
        forged = dict(self.store.get_json('gates/pr-8.json'), success=False)
        self.store.put_json('gates/pr-8.json', forged)
        self.assertFalse(gate.consume_result(4, 'req1', self.gh, self.store))
        self.assertIsNone(self.store.get_json('sessions/4/state.json'))
        # ...and a status written by anyone else does not count.
        self.gh.statuses.post('a' * 40, {'state': 'failure', 'context': gate.CONTEXT}, login='someone')
        self.assertFalse(gate.consume_result(4, 'req1', self.gh, self.store))

    def test_attempts_are_counted_from_statuses_when_the_store_counter_is_reset(self):
        for attempt in range(3):
            self.gh.statuses.post('a' * 40, {'state': 'pending', 'context': gate.CONTEXT,
                                             'description': f'{gate.ATTEMPT_PREFIX}{attempt + 1}/3: starting github'})
        with self.assertRaisesRegex(RuntimeError, 'limit'):
            self.controller.start(8)
        self.assertEqual(self.dispatches(), [])

    def test_watch_polls_until_the_gate_completes_and_respects_the_deadline(self):
        record = self.controller.start(8)
        now = [0.0]
        calls = []
        def sleep(seconds):
            now[0] += seconds
            calls.append(seconds)
            if len(calls) == 2:
                self.results()
        gate.watch(self.controller, 30, interval=60, clock=lambda: now[0], sleep=sleep)
        self.assertEqual(self.store.get_json('gates/pr-8.json')['phase'], 'complete')
        self.assertEqual(len(calls), 2)
        self.assertEqual(len(self.wakes()), 1)
        # With nothing running the watch returns at once.
        gate.watch(self.controller, 30, interval=60, clock=lambda: now[0], sleep=sleep)
        self.assertEqual(len(calls), 2)
