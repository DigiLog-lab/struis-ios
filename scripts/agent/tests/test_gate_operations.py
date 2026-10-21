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


class GateRaceTests(unittest.TestCase):
    """Races between a queued Ready dispatch, the minute loop and failed writes."""
    setUp = fixtures.GateTests.setUp
    results = fixtures.GateTests.results
    dispatches = fixtures.GateTests.dispatches
    wakes = fixtures.GateTests.wakes

    def block_previous_gate(self):
        with mock.patch.object(gate, 'max_attempts', side_effect=RuntimeError('configuration error')), \
                self.assertRaises(RuntimeError):
            self.controller.start(8, 'req1')
        self.assertEqual(self.store.get_json('gates/pr-8.json')['phase'], 'blocked')
        # The worker repairs and makes a new Ready request R2 (Draft cleared, dispatch queued).
        self.store.put_json('sessions/4/gate-request.json', dict(self.request, request='req2'))
        self.gh.pr['draft'] = False

    def test_reconcile_starts_the_workers_fresh_request_and_the_queued_dispatch_keeps_it(self):
        self.block_previous_gate()
        self.controller.reconcile()  # the minute loop of another control run sees the Ready PR first
        record = self.store.get_json('gates/pr-8.json')
        self.assertEqual((record['request'], record['phase']), ('req2', 'waiting'))
        self.assertEqual(self.store.get_json('sessions/4/gate-request.json')['request'], 'req2')
        self.controller.start(8, 'req2')  # the queued agent-gate dispatch of the worker
        record = self.store.get_json('gates/pr-8.json')
        self.assertEqual((record['request'], record['phase']), ('req2', 'waiting'))
        self.assertFalse(self.gh.pr['draft'])
        self.assertEqual([body['inputs']['ci_request'] for _, _, body in self.dispatches('agent-tests.yml')], ['req2'])

    def test_a_superseded_dispatch_does_not_stop_the_newer_gate(self):
        self.block_previous_gate()
        self.controller.start(8, 'req2')
        self.controller.start(8, 'req1')  # a late duplicate of the old request
        record = self.store.get_json('gates/pr-8.json')
        self.assertEqual((record['request'], record['phase']), ('req2', 'waiting'))
        self.assertFalse(self.gh.pr['draft'])

    def test_a_failed_start_of_another_request_leaves_the_running_gate(self):
        self.controller.start(8, 'req1')
        with mock.patch.object(gate, 'request_data', side_effect=RuntimeError('evidence unreadable')), \
                self.assertRaises(RuntimeError):
            self.controller.start(8)
        record = self.store.get_json('gates/pr-8.json')
        self.assertEqual((record['request'], record['phase']), ('req1', 'waiting'))
        self.assertFalse(self.gh.pr['draft'])

    def test_a_transient_poll_error_never_blocks_a_running_gate(self):
        self.controller.start(8, 'req1')
        with mock.patch.object(self.controller, 'workflow_result', side_effect=OSError('connection reset')), \
                self.assertRaises(OSError):
            self.controller.start(8, 'req1')
        self.assertEqual(self.store.get_json('gates/pr-8.json')['phase'], 'waiting')
        self.assertFalse(self.gh.pr['draft'])
        self.results()
        self.assertTrue(self.controller.start(8, 'req1')['success'])

    def test_a_failed_outcome_status_is_written_again_before_the_issue_is_woken(self):
        self.controller.start(8, 'req1')
        self.results()
        original = self.gh.request
        def flaky(method, path, body=None):
            if '/statuses/' in path and body['state'] == 'success':
                raise OSError('status write lost')
            return original(method, path, body)
        with mock.patch.object(self.gh, 'request', side_effect=flaky), self.assertRaises(OSError):
            self.controller.poll(self.store.get_json('gates/pr-8.json'))
        self.assertEqual(self.wakes(), [])
        self.controller.reconcile()
        self.assertEqual(gate.gate_status(self.gh, 'a' * 40), 'success')
        self.assertEqual(len(self.wakes()), 1)
        self.assertFalse(gate.consume_result(4, 'req1', self.gh, self.store))  # completes, does not repair
        self.assertEqual(self.store.get_json('sessions/4/state.json')['validatedGate'], 'req1')

    def test_a_record_written_by_another_job_is_refused_and_replaced(self):
        self.controller.start(8, 'req1')
        forged = dict(self.store.get_json('gates/pr-8.json'), cloudRun='a-build-that-passed-on-retry',
                      backend='xcode-cloud', workflow='workflow1')
        forged.pop('signature')
        self.store.put_json('gates/pr-8.json', forged)
        with mock.patch.object(gate, 'cloud_client') as client:
            with self.assertRaisesRegex(RuntimeError, 'not signed'):
                self.controller.start(8, 'req1')
            client.assert_not_called()
        record = self.store.get_json('gates/pr-8.json')
        self.assertEqual(record['phase'], 'blocked')
        self.assertTrue(self.gh.pr['draft'])
        self.assertEqual(gate.gate_status(self.gh, 'a' * 40), 'error')
        # A copied signature does not cover changed fields either.
        signed = self.store.get_json('gates/pr-8.json')
        self.store.put_json('gates/pr-8.json', dict(signed, phase='complete', success=True))
        with self.assertRaises(gate.TamperedRecord):
            self.controller.load(8)

    def test_the_controller_refuses_to_run_without_its_signing_key(self):
        with mock.patch.dict(os.environ, {'APP_STORE_CONNECT_KEY_PATH': ''}), \
                self.assertRaisesRegex(RuntimeError, 'sign'):
            gate.Controller(self.gh, self.store)

    def test_a_pr_cannot_exempt_its_own_tests_from_the_gate(self):
        import base64
        import json
        original = self.gh.get
        requested = []
        def get(path):
            if '/contents/scripts/ci/xcode-cloud-exclusions.json' in path:
                requested.append(path)
                methods = [] if path.endswith('?ref=main') else [{'test': 'Class/testWorks', 'reason': 'added by the PR'}]
                return {'content': base64.b64encode(json.dumps({'version': 1, 'methods': methods}).encode()).decode()}
            return original(path)
        with mock.patch.object(self.gh, 'get', side_effect=get):
            record = self.controller.start(8, 'req1')
        self.assertTrue(requested and all(path.endswith('?ref=main') for path in requested))
        self.assertIn('Class/testWorks', record['expectedTests'])


class GitHubFallbackTests(unittest.TestCase):
    """The GitHub fallback is green only with every required test run and passed, like Xcode Cloud."""
    setUp = fixtures.GateTests.setUp
    results = fixtures.GateTests.results
    wakes = fixtures.GateTests.wakes

    def outcome(self, **results):
        record = self.controller.start(8, 'req1')
        self.results(**results)
        return self.controller.poll(record)

    def test_all_required_tests_listed_and_passed_is_green(self):
        record = self.outcome()
        self.assertTrue(record['success'])
        self.assertEqual(record['results']['ios.yml']['missingTests'], [])

    def test_a_required_test_that_did_not_run_is_red(self):
        record = self.controller.start(8, 'req1')
        self.results(ui_tests=(('Other/testElse()', 'Passed'),))
        # Only the UI list arrives: the required Class/testWorks never ran.
        self.gh.gate_lists = [item for item in self.gh.gate_lists if not item['name'].endswith('-unit')]
        record = self.controller.poll(record)
        self.assertFalse(record['success'])
        self.assertEqual(record['results']['ios.yml']['missingTests'], ['Class/testWorks'])

    def test_a_failed_or_expected_failure_test_is_red_even_if_the_run_succeeded(self):
        for result in ('Failed', 'Expected Failure'):
            with self.subTest(result=result):
                self.setUp()
                record = self.outcome(ui_tests=(('Class/testWorks()', result),))
                self.assertFalse(record['success'])
                self.assertEqual(record['results']['ios.yml']['failedTests'], ['Class/testWorks()'])

    def test_no_lists_is_red(self):
        record = self.controller.start(8, 'req1')
        self.results()
        self.gh.gate_lists = []
        self.assertFalse(self.controller.poll(record)['success'])

    def test_a_list_from_another_run_is_refused(self):
        record = self.controller.start(8, 'req1')
        self.results()
        self.gh.gate_lists[0]['name'] = 'ios-gate-tests-2-1-unit'
        self.gh.gate_lists[0]['workflow_run'] = {'id': 2}
        original = self.gh.get
        def get(path):
            listing = original(path)
            if '/artifacts?' in path:
                listing['artifacts'][0] = dict(listing['artifacts'][0], workflow_run={'id': 99})
            return listing
        with mock.patch.object(self.gh, 'get', side_effect=get), self.assertRaisesRegex(RuntimeError, 'another run'):
            self.controller.poll(record)
