"""Real git/checkpoint lifecycle across Ready, pruning and control-plane failures."""
import copy
import json
import os
from pathlib import Path
import sys
import unittest
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import checkpoints
import agentctl
import delivery
import gate
from gate_fakes import MemoryStore
import test_checkpoint_v2 as checkpoint_fixtures
from test_delivery import test_tree
from test_gate import FakeGitHub


class ReadyGitHub(FakeGitHub):
    def get(self, path):
        if '/pulls?' in path:
            return [copy.deepcopy(self.pr)]
        return super().get(path)


class ReadyHandoffTests(unittest.TestCase):
    git = checkpoint_fixtures.ImmutableCheckpointTests.git

    def setUp(self):
        checkpoint_fixtures.ImmutableCheckpointTests.setUp(self)
        self.store, self.gh = MemoryStore(), ReadyGitHub()
        self.gh.pr['head']['sha'] = self.base
        self.gh.pr['draft'] = True
        self.run.update(includedComments=[20], includedIssueBody=True)
        snapshot = {'issue': {'body': 'the original request'}, 'comments': []}
        items = {'items': [{'id': 'issue-1', 'complete': True, 'note': 'done'}]}
        local = {'schema': 1, 'head': self.base, 'success': True,
                 'startedAt': '2026-10-20T00:00:00Z', 'finishedAt': '2026-10-20T00:10:00Z',
                 'selection': {'uiTests': ['Class/testWorks']},
                 'scopeSha256': delivery.scope_digest(snapshot), 'itemsSha256': delivery.item_digest(items),
                 'checks': [{'name': name, 'exitCode': 0, 'seconds': 1, 'testResults': test_tree()}
                            for name in ('build-for-testing', 'tests')]}
        for name, value in [('run.json', self.run), ('request-snapshot.json', snapshot),
                            ('work-items.json', items), ('local-verification.json', local)]:
            delivery.write(name, value)
        self.store.put_json('sessions/4/state.json', {'issue': 4, 'workerStatus': 'running'})
        for patch in (mock.patch.dict(os.environ, {'AGENT_GATE_MAX_ATTEMPTS': '3', 'AGENT_GATE_BACKEND': 'github',
                                                  'XCODE_CLOUD_REMAINING_MINUTES': '', 'AGENT_GATE_ESTIMATED_MINUTES': ''}),
                      mock.patch.object(delivery, 'GitHub', return_value=self.gh),
                      mock.patch.object(delivery, 'Store', return_value=self.store)):
            patch.start()
            self.addCleanup(patch.stop)
        self.controller = gate.Controller(self.gh, self.store, key=b"test-key", artifacts=self.store.artifacts)

    def complete_gate(self, request, success):
        tree = {'testNodes': [{'nodeType': 'Test Case', 'nodeIdentifier': 'Class/testWorks()', 'result': 'Passed'}]}
        listed = self.store.artifacts.upload('ios-gate-tests-2-1-unit', {'unit.json': json.dumps(tree).encode()}, 1)
        self.gh.gate_lists = [{'id': listed['id'], 'name': listed['name'], 'workflow_run': {'id': 2}}]
        for index, workflow in enumerate(('agent-tests.yml', 'ios.yml'), 1):
            self.gh.runs[workflow] = [{'id': index, 'head_branch': 'main', 'status': 'completed',
                                      'path': f'.github/workflows/{workflow}',
                                      'conclusion': 'success' if success else 'failure', 'html_url': 'https://example.test/run',
                                      'display_title': ('iOS CI ' if workflow == 'ios.yml' else 'Agent tests CI ')
                                                       + request['request'] + ' ' + self.base}]
        return self.controller.poll(self.store.get_json('gates/pr-8.json'))

    def test_ready_in_claude_session_is_recorded_and_performed_by_validate(self):
        # claude-code-action removes the OIDC request variables from Claude's session (Issue #44).
        self.run.update(headBefore='0' * 40, validationRequired=True)
        with mock.patch.dict(os.environ, {'ACTIONS_ID_TOKEN_REQUEST_URL': '', 'ACTIONS_ID_TOKEN_REQUEST_TOKEN': ''}):
            self.assertFalse(delivery.oidc_available())
            recorded = delivery.request_ready()
        self.assertEqual((recorded['head'], recorded['pr']), (self.base, 8))
        self.assertTrue(self.gh.pr['draft'], 'the request alone must not leave Draft')
        self.assertIsNone(self.store.get_json('sessions/4/gate-request.json'))
        with self.assertRaisesRegex(RuntimeError, 'enter Ready'):
            delivery.verify_outcome(self.run)
        # The step after the session (agentctl validate) has OIDC and performs the real Ready.
        request = delivery.perform_requested_ready(self.run)
        self.assertEqual(request['head'], self.base)
        self.assertFalse(self.gh.pr['draft'])
        self.assertEqual(self.store.get_json('sessions/4/gate-request.json')['request'], request['request'])
        delivery.verify_outcome(self.run)
        # Running validate again does not start a second Ready.
        self.assertIsNone(delivery.perform_requested_ready(self.run))

    def test_a_ready_request_for_an_older_head_is_ignored(self):
        delivery.write(delivery.READY_REQUEST, {'head': 'f' * 40, 'pr': 8, 'at': 'x'})
        self.assertIsNone(delivery.perform_requested_ready(self.run))
        self.assertTrue(self.gh.pr['draft'])

    def test_ready_proof_and_repair_survive_pruning_before_start_and_result(self):
        request = delivery.ready()
        original = request['checkpoint']['artifact']['id']
        # Periodic save followed by finalize, then the Linux job after the worker:
        # only these two may be retained.
        checkpoints.save(self.store, 4, self.run, periodic=True)
        checkpoints.save(self.store, 4, self.run)
        checkpoints.prune(self.store, 4)
        self.assertNotIn(original, self.store.artifacts.items)
        self.assertEqual(len(self.store.artifacts.list('agent-ckpt-4-')), 2)
        self.assertEqual(self.controller.start(8, request['request'])['phase'], 'waiting')
        self.complete_gate(request, False)
        # Even a later mutable session request cannot replace the accepted scope.
        changed = copy.deepcopy(request)
        changed['scope']['includedComments'] = [999]
        self.store.put_json('sessions/4/gate-request.json', changed)
        self.assertTrue(gate.consume_result(4, request['request'], self.gh, self.store))
        self.assertEqual(self.store.get_json('sessions/4/repair-request.json')['issue']['body'], 'the original request')
        self.assertEqual(self.store.get_json('sessions/4/state.json')['repair']['includedComments'], [20])

    def test_lost_explicit_dispatch_is_recovered_on_linux_without_redrafting_or_duplicate_build(self):
        original = self.gh.request
        def request(method, path, body=None):
            if path.endswith('/dispatches') and (body or {}).get('event_type') == 'agent-gate':
                raise OSError('connection lost after submission')
            return original(method, path, body)
        with mock.patch.object(self.gh, 'request', side_effect=request):
            pending = delivery.ready()
        self.assertFalse(self.gh.pr['draft'])
        self.assertTrue(delivery.waiting(self.run))
        self.assertEqual(self.store.get_json('sessions/4/state.json')['workerStatus'], 'waiting-gate')
        self.controller.reconcile()
        self.controller.reconcile()
        record = self.store.get_json('gates/pr-8.json')
        self.assertEqual(record['request'], pending['request'])
        self.assertEqual(record['attempts'], 1)
        self.assertEqual(len([call for call in self.gh.calls if '/ios.yml/dispatches' in str(call[1])]), 1)

    def test_denied_ready_mutation_never_persists_waiting_for_a_gate_that_cannot_start(self):
        original = self.gh.request
        def request(method, path, body=None):
            if path == '/graphql':
                raise OSError('mutation denied')
            return original(method, path, body)
        with mock.patch.object(self.gh, 'request', side_effect=request), self.assertRaises(OSError):
            delivery.ready()
        state = self.store.get_json('sessions/4/state.json')
        self.assertNotEqual(state['workerStatus'], 'waiting-gate')
        self.assertFalse(delivery.waiting(self.run))
        self.assertFalse(delivery.recover_handoff(self.store, self.gh, 4, state))

    def test_runner_lost_after_ready_is_reconciled_without_a_macos_restart(self):
        original = self.gh.get
        def get(path):
            if path.endswith('/pulls/8') and not self.gh.pr['draft']:
                raise SystemExit('runner lost immediately after Ready')
            return original(path)
        with mock.patch.object(self.gh, 'get', side_effect=get), self.assertRaises(SystemExit):
            delivery.ready()
        with mock.patch.dict(os.environ, {'AGENT_VALIDATION_MODE': 'gate', 'RECOVER_TITLE': 'Issue agent #4'}), \
                mock.patch.object(agentctl, 'GitHub', return_value=self.gh), \
                mock.patch.object(agentctl, 'Store', return_value=self.store), \
                mock.patch.object(agentctl, 'restart_interrupted') as restart:
            agentctl.cmd_recover(None)
        restart.assert_not_called()
        self.assertEqual(self.store.get_json('sessions/4/state.json')['workerStatus'], 'waiting-gate')

    def test_result_before_waiting_state_is_saved_remains_completed(self):
        original = self.store.update_json
        calls = 0
        def update(key, change, default=None):
            nonlocal calls
            if key == 'sessions/4/state.json':
                calls += 1
                if calls == 2:
                    request = self.store.get_json('sessions/4/gate-request.json')
                    self.controller.start(8, request['request'])
                    self.complete_gate(request, True)
                    gate.consume_result(4, request['request'], self.gh, self.store)
            return original(key, change, default)
        with mock.patch.object(self.store, 'update_json', side_effect=update):
            request = delivery.ready()
        state = self.store.get_json('sessions/4/state.json')
        self.assertEqual(state['workerStatus'], 'idle')
        self.assertEqual(state['processedGate'], request['request'])
        self.assertEqual(state['validatedHead'], self.base)

    def test_tampered_copied_proof_is_rejected_even_after_checkpoint_pruning(self):
        request = delivery.ready()
        request['evidence']['request-snapshot.json'] = json.dumps({'issue': {'body': 'changed'}, 'comments': []})
        self.store.put_json('sessions/4/gate-request.json', request)
        with self.assertRaisesRegex(RuntimeError, 'evidence'):
            self.controller.start(8, request['request'])
        self.assertTrue(self.gh.pr['draft'])
