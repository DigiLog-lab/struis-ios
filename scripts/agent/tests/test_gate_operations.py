import copy
import os
from pathlib import Path
import sys
import unittest
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import cleanup
import configure_cloud
import gate
import test_gate as fixtures


class CloudAndCleanupTests(unittest.TestCase):
    def test_cloud_configuration_preserves_destinations_and_separates_release(self):
        source = {'id': 'working', 'attributes': {'name': 'Default', 'actions': [{'actionType': 'TEST', 'scheme': 'old',
                   'testConfiguration': {'kind': 'SPECIFIC_TEST_PLANS', 'testPlanName': 'old',
                                         'testDestinations': [{'deviceTypeName': 'iPhone 17'}]}}]},
                  'relationships': {name: {'data': {'id': name, 'type': name}} for name in
                                    ('product', 'repository', 'macOsVersion', 'xcodeVersion')}}
        client = mock.Mock()
        client.request.return_value = {'data': source}
        client.paginate.return_value = [source]
        operations = configure_cloud.configure(client, 'working')
        self.assertEqual([entry['method'] for entry in operations], ['PATCH', 'POST'])
        self.assertEqual(client.request.call_count, 1)  # preview does not mutate
        pr = operations[0]['body']['data']['attributes']
        release = operations[1]['body']['data']['attributes']
        self.assertIsNone(pr['branchStartCondition'])
        self.assertFalse(pr['clean'])
        self.assertEqual(pr['actions'][0]['scheme'], 'StruisPRGate')
        self.assertEqual(pr['actions'][0]['testConfiguration']['testDestinations'], [{'deviceTypeName': 'iPhone 17'}])
        self.assertEqual(release['actions'][-1]['buildDistributionAudience'], 'INTERNAL_ONLY')
        self.assertEqual(release['actions'][0]['scheme'], 'StruisRelease')

    def test_closing_an_issue_tombstones_and_deletes_all_its_checkpoints_only(self):
        store = fixtures.MemoryStore()
        mine = store.artifacts.upload('agent-ckpt-4-save-1', {'manifest.json': b'{}'}, 14)
        other = store.artifacts.upload('agent-ckpt-44-save-1', {'manifest.json': b'{}'}, 14)
        store.put_json('sessions/4/workspace.json', {'schema': 3, 'saveId': 'save-1', 'artifact': mine})
        gh = mock.Mock(repository='owner/repo')
        gh.get.return_value = {'actions_caches': []}
        cleanup.cleanup(4, None, gh, store)
        self.assertTrue(store.get_json('sessions/4/workspace.json')['closed'])
        self.assertEqual(set(store.artifacts.items), {other['id']})

    def test_cache_cleanup_cannot_delete_bootstrap_or_another_branch(self):
        gh = mock.Mock(repository='owner/repo')
        prefix = cleanup.cache_prefix('agent/issue-4')
        gh.get.side_effect = [{'actions_caches': [
            {'id': 1, 'key': prefix + 'xcode-27'}, {'id': 2, 'key': 'native-runtime-v1-expensive'},
            {'id': 3, 'key': cleanup.cache_prefix('agent/issue-44') + 'xcode-27'}]}, {'actions_caches': []}]
        self.assertEqual(cleanup.delete_branch_cache(gh, 'agent/issue-4'), 1)
        gh.request.assert_called_once_with('DELETE', '/repos/owner/repo/actions/caches/1')

    def test_fork_pr_cannot_use_a_marker_to_delete_another_issues_checkpoint(self):
        pr = {'body': '<!-- struis-agent:issue=4 -->', 'head': {'ref': 'agent/issue-4', 'repo': {'full_name': 'outsider/repo'}}}
        self.assertFalse(cleanup.owns_pr(pr, 4, 'agent/issue-4', 'owner/repo'))
        pr['head']['repo']['full_name'] = 'owner/repo'
        self.assertTrue(cleanup.owns_pr(pr, 4, 'agent/issue-4', 'owner/repo'))
        self.assertFalse(cleanup.owns_pr(pr, 4, 'different-branch', 'owner/repo'))


class GateBoundaryTests(unittest.TestCase):
    # Reuse the real state-machine fixture without duplicating the base cases.
    setUp = fixtures.GateTests.setUp
    results = fixtures.GateTests.results
    dispatches = fixtures.GateTests.dispatches
    wakes = fixtures.GateTests.wakes
    def test_cloud_source_commit_mismatch_never_becomes_green(self):
        record = self.controller.start(8)
        record.update(backend='xcode-cloud', cloudRun='cloud1', workflow='workflow1', url='https://cloud.example/run')
        self.results()
        client = mock.Mock()
        client.request.return_value = {'data': {'id': 'cloud1', 'attributes': {
            'sourceCommit': {'commitSha': 'b' * 40}, 'executionProgress': 'COMPLETE', 'completionStatus': 'SUCCEEDED'},
            'relationships': {'workflow': {'data': {'id': 'workflow1'}}}}}
        with mock.patch.object(gate, 'cloud_client', return_value=client):
            result = self.controller.poll(record)
        self.assertEqual(result['phase'], 'invalidated')
        self.assertTrue(self.gh.pr['draft'])
        self.assertEqual(self.wakes(), [])

    def test_cloud_requires_real_test_results_and_carries_failure_details(self):
        record = self.controller.start(8)
        record.update(backend='xcode-cloud', cloudRun='cloud1', workflow='workflow1', url='https://cloud.example/run',
                      dispatched=['agent-tests.yml'])
        self.results()
        client = mock.Mock()
        client.request.return_value = {'data': {'id': 'cloud1', 'attributes': {
            'sourceCommit': {'commitSha': 'a' * 40}, 'executionProgress': 'COMPLETE', 'completionStatus': 'SUCCEEDED'},
            'relationships': {'workflow': {'data': {'id': 'workflow1'}}}}}
        client.paginate.side_effect = [[{'id': 'tests1', 'attributes': {'actionType': 'TEST', 'completionStatus': 'SUCCEEDED'}}], []]
        with mock.patch.object(gate, 'cloud_client', return_value=client):
            result = self.controller.poll(record)
        self.assertFalse(result['success'])  # even an overall SUCCEEDED cannot hide zero tests
        self.assertTrue(self.gh.pr['draft'])

    def test_completed_proof_can_be_deleted_without_drafting_successful_pr(self):
        self.controller.start(8)
        self.results()
        self.controller.poll(self.store.get_json('gates/pr-8.json'))
        for identifier in list(self.store.artifacts.items):
            self.store.artifacts.delete(identifier)
        self.controller.reconcile()
        self.assertFalse(self.gh.pr['draft'])
        self.assertTrue(self.store.get_json('gates/pr-8.json')['success'])

    def test_human_ready_uses_same_checkpoint_conditions_without_agent_dispatch(self):
        del self.store.data['sessions/4/gate-request.json']
        record = self.controller.start(8)
        self.assertEqual(record['phase'], 'waiting')
        self.assertEqual(record['scope']['includedComments'], [20])

    def test_failed_last_allowed_gate_waits_for_instructions_without_macos(self):
        record = self.controller.start(8)
        self.results(failed='ios.yml')
        self.controller.poll(record)
        with mock.patch.dict(os.environ, {'AGENT_GATE_MAX_ATTEMPTS': '1'}):
            self.assertFalse(gate.consume_result(4, 'req1', self.gh, self.store))
            self.assertFalse(gate.consume_result(4, 'req1', self.gh, self.store))
        self.assertEqual(self.store.get_json('sessions/4/state.json')['workerStatus'], 'waiting-instructions')

    def test_new_ready_request_supersedes_old_gate_without_redrafting_new_head(self):
        self.controller.start(8)
        changed = copy.deepcopy(self.request)
        changed['request'] = 'req2'
        self.store.put_json('sessions/4/gate-request.json', changed)
        record = self.controller.start(8, 'req2')
        self.assertEqual(record['request'], 'req2')
        self.assertEqual(record['phase'], 'waiting')
        self.assertFalse(self.gh.pr['draft'])
