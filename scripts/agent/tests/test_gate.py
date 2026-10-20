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
from gate_fakes import MemoryStore
from test_delivery import test_tree


class FakeGitHub:
    repository = 'owner/repo'

    def __init__(self):
        self.calls = []
        self.runs = {}
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
        if '/actions/runs/' in path:
            identifier = int(path.rsplit('/', 1)[1])
            return copy.deepcopy(next(run for runs in self.runs.values() for run in runs if run['id'] == identifier))
        raise AssertionError(path)

    def request(self, method, path, body=None):
        self.calls.append((method, path, copy.deepcopy(body)))
        if path == '/graphql':
            value = 'convertPullRequestToDraft' in body['query']
            self.pr['draft'] = value
            field = 'convertPullRequestToDraft' if value else 'markPullRequestReadyForReview'
            return {'data': {field: {'pullRequest': {'isDraft': value}}}}, ''
        return {}, ''

    def comment(self, number, body):
        self.calls.append(('comment', number, body))

    def paginate(self, path):
        return [copy.deepcopy(self.pr)]


class GateTests(unittest.TestCase):
    def setUp(self):
        patch = mock.patch.dict(os.environ, {'AGENT_GATE_MAX_ATTEMPTS': '3', 'AGENT_GATE_BACKEND': 'github',
                                             'XCODE_CLOUD_REMAINING_MINUTES': '', 'AGENT_GATE_ESTIMATED_MINUTES': ''})
        patch.start()
        self.addCleanup(patch.stop)
        self.gh, self.store = FakeGitHub(), MemoryStore()
        self.controller = gate.Controller(self.gh, self.store)
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
        for name, value in components.items():
            self.store.put_json(prefix + '/' + name, value)
        checkpoint = {'schema': 2, 'saveId': 'save-1', 'prefix': prefix, 'head': 'a' * 40,
                      'components': {name: checkpoints.digest(self.store.data[prefix + '/' + name]) for name in components}}
        self.request = {'request': 'req1', 'issue': 4, 'pr': 8, 'head': 'a' * 40, 'branch': 'work', 'checkpoint': checkpoint,
                        'scope': {'includedComments': [20], 'includedIssueBody': True}}
        self.store.put_json('sessions/4/gate-request.json', self.request)
        self.store.put_json('sessions/4/workspace.json', checkpoint)

    def results(self, failed=None):
        for index, workflow in enumerate(['agent-tests.yml', 'ios.yml'], 1):
            self.gh.runs[workflow] = [{'id': index, 'run_attempt': 1, 'head_branch': 'main',
                                      'path': f'.github/workflows/{workflow}', 'status': 'completed',
                                      'conclusion': 'failure' if workflow == failed else 'success',
                                      'html_url': f'https://github.com/owner/repo/actions/runs/{index}',
                                      'display_title': ('iOS CI ' if workflow == 'ios.yml' else 'Agent tests CI ') + 'req1 ' + 'a' * 40}]

    def dispatches(self, workflow=None):
        return [call for call in self.gh.calls if isinstance(call[1], str) and '/dispatches' in call[1]
                and (not workflow or f'/{workflow}/' in call[1])]

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
        self.assertEqual(self.dispatches('agent.yml'), [])

    def test_green_gate_wakes_once_and_linux_route_completes_original_scope(self):
        record = self.controller.start(8)
        self.results()
        self.controller.poll(record)
        self.controller.poll(self.store.get_json('gates/pr-8.json'))
        self.assertEqual(len(self.dispatches('agent.yml')), 1)
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
        del self.store.data['sessions/4/checkpoints/save-1/local-verification.json']
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

    def test_quota_fallback_uses_configured_values_without_invented_threshold(self):
        with mock.patch.dict(os.environ, {'AGENT_GATE_BACKEND': 'xcode-cloud', 'XCODE_CLOUD_REMAINING_MINUTES': '10', 'AGENT_GATE_ESTIMATED_MINUTES': '15'}):
            self.assertEqual(gate.backend(), 'github')
        with mock.patch.dict(os.environ, {'AGENT_GATE_BACKEND': 'xcode-cloud', 'XCODE_CLOUD_REMAINING_MINUTES': '16', 'AGENT_GATE_ESTIMATED_MINUTES': '15'}):
            self.assertEqual(gate.backend(), 'xcode-cloud')
