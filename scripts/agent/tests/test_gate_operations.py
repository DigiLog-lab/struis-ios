import copy
import io
import os
from pathlib import Path
import sys
import unittest
from unittest import mock
import zipfile

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
        self.assertEqual([entry['method'] for entry in operations], ['PATCH', 'POST', 'POST'])
        self.assertEqual(client.request.call_count, 1)  # preview does not mutate
        pr = operations[0]['body']['data']['attributes']
        single = operations[1]['body']['data']['attributes']
        release = operations[2]['body']['data']['attributes']
        # The one-machine gate: a single Simulator BUILD action, no TEST hand-off, manual starts only.
        self.assertEqual(single['name'], 'PR Gate Single Machine')
        self.assertEqual([(a['actionType'], a['scheme'], a['destination'], a['isRequiredToPass']) for a in single['actions']],
                         [('BUILD', 'StruisPRGate', 'ANY_IOS_SIMULATOR', True)])
        self.assertIsNone(single['branchStartCondition'])
        self.assertFalse(single['clean'])
        only = configure_cloud.configure(client, 'working', only=('single',))
        self.assertEqual([entry['body']['data']['attributes']['name'] for entry in only], ['PR Gate Single Machine'])
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
        self.controller.poll(self.store.get_json('sessions/gates/pr-8.json'))
        for identifier in list(self.store.artifacts.items):
            self.store.artifacts.delete(identifier)
        self.controller.reconcile()
        self.assertFalse(self.gh.pr['draft'])
        self.assertTrue(self.store.get_json('sessions/gates/pr-8.json')['success'])

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


def log_bundle(lines, name='strius Build 1 Logs for StruisPRGate build/ci_pre_xcodebuild.log'):
    """An Xcode Cloud LOG_BUNDLE zip whose script log carries what cloud_gate_tests.py prints."""
    buffer = io.BytesIO()
    with zipfile.ZipFile(buffer, 'w') as archive:
        archive.writestr(name, ''.join(f'2026-10-21T07:00:00.000000000Z\t{line}\n' for line in lines))
        archive.writestr('strius Build 1 Logs for StruisPRGate build/xcodebuild-build.log', 'STRUIS_GATE_TEST\tPassed\tOther/notCounted()\n')
    return buffer.getvalue()


class SingleMachineGateTests(unittest.TestCase):
    """The one-machine PR Gate: one BUILD action ran the tests and printed every result in its log."""
    setUp = fixtures.GateTests.setUp
    results = fixtures.GateTests.results
    PASSED = ['STRUIS_GATE_TEST\tPassed\tClass/testWorks()', 'STRUIS_GATE_RESULT ok=true tests=1 exits=0,0']

    def poll(self, bundle, status='SUCCEEDED', bundles=1):
        record = self.controller.start(8)
        record.update(backend='xcode-cloud', cloudRun='cloud1', workflow='workflow1', url='https://cloud.example/run',
                      dispatched=['agent-tests.yml'])
        self.results()
        client = mock.Mock()
        client.request.return_value = {'data': {'id': 'cloud1', 'attributes': {
            'sourceCommit': {'commitSha': 'a' * 40}, 'executionProgress': 'COMPLETE', 'completionStatus': status},
            'relationships': {'workflow': {'data': {'id': 'workflow1'}}}}}
        artifacts = [{'id': 'log1', 'attributes': {'fileType': 'LOG_BUNDLE', 'downloadUrl': 'https://cloud.example/log1.zip'}}] * bundles
        pages = [[{'id': 'build1', 'attributes': {'actionType': 'BUILD', 'completionStatus': status}}], artifacts]
        if status != 'SUCCEEDED':
            pages.append([])
        client.paginate.side_effect = pages
        downloads = []
        self.controller.cloud_download = lambda url: downloads.append(url) or bundle
        with mock.patch.object(gate, 'cloud_client', return_value=client), \
                mock.patch.object(gate, 'gate_mode', return_value='build-machine'):
            result = self.controller.poll(record)
        self.assertEqual(downloads, ['https://cloud.example/log1.zip'] if bundles == 1 else [])
        return result

    def test_every_required_test_passed_on_the_build_machine_is_green(self):
        result = self.poll(log_bundle(self.PASSED))
        self.assertTrue(result['success'])
        self.assertEqual(result['results']['xcode-cloud']['mode'], 'build-machine')
        self.assertFalse(self.gh.pr['draft'])

    def test_a_failed_missing_or_unreported_test_is_red(self):
        cases = {
            'failed': ['STRUIS_GATE_TEST\tFailed\tClass/testWorks()', 'STRUIS_GATE_RESULT ok=false tests=1 exits=0,1'],
            'missing': ['STRUIS_GATE_TEST\tPassed\tClass/testOther()', 'STRUIS_GATE_RESULT ok=true tests=1 exits=0'],
            'no result line': self.PASSED[:1],
            'not ok': [self.PASSED[0], 'STRUIS_GATE_RESULT ok=false tests=1 exits=0,0'],
            'no tests': ['STRUIS_GATE_RESULT ok=true tests=0 exits=0'],
            # A test's own output, copied (indented) or embedded in a longer line, never adds a result.
            'printed by a test': ['  UI_DIAGNOSTICS STRUIS_GATE_TEST\tPassed\tClass/testWorks()', 'x STRUIS_GATE_TEST\tPassed\tClass/testWorks()',
                                  'STRUIS_GATE_RESULT ok=true tests=1 exits=0'],
        }
        for name, lines in cases.items():
            with self.subTest(name):
                self.setUp()
                result = self.poll(log_bundle(lines))
                self.assertFalse(result['success'])
                self.assertTrue(self.gh.pr['draft'])

    def test_an_unreadable_or_absent_log_is_red_without_stopping_the_controller(self):
        for name, kwargs in {'no script log': {'bundle': log_bundle(self.PASSED, name='logs/ci_post_clone.log')},
                             'not a zip': {'bundle': b'not a zip'},
                             'no bundle': {'bundle': b'', 'bundles': 0}}.items():
            with self.subTest(name):
                self.setUp()
                result = self.poll(**kwargs)
                self.assertEqual(result['phase'], 'complete')
                self.assertFalse(result['success'])
                self.assertTrue(result['results']['xcode-cloud']['machineErrors'])

    def test_a_failed_build_action_is_red_even_when_its_log_says_ok(self):
        result = self.poll(log_bundle(self.PASSED), status='FAILED')
        self.assertFalse(result['success'])

    def test_workflow_shape_is_checked_for_the_selected_mode(self):
        def workflow(actions):
            client = mock.Mock()
            client.request.return_value = {'data': {'id': 'wf', 'attributes': {
                'isEnabled': True, 'clean': False, 'containerFilePath': 'strius.xcodeproj', 'actions': actions}}}
            return client
        build = {'actionType': 'BUILD', 'scheme': 'StruisPRGate', 'destination': 'ANY_IOS_SIMULATOR', 'isRequiredToPass': True}
        test = {'actionType': 'TEST', 'scheme': 'StruisPRGate', 'isRequiredToPass': True}
        with mock.patch.object(gate, 'gate_mode', return_value='build-machine'):
            self.assertEqual(gate.cloud_workflow(workflow([build]))['id'], 'wf')
            for actions in ([test], [build, test], [dict(build, destination='ANY_IOS_DEVICE')], [dict(build, isRequiredToPass=False)],
                            [build, build]):
                with self.assertRaises(RuntimeError):
                    gate.cloud_workflow(workflow(actions))
        with mock.patch.object(gate, 'gate_mode', return_value='test-action'):
            self.assertEqual(gate.cloud_workflow(workflow([test]))['id'], 'wf')
            with self.assertRaises(RuntimeError):
                gate.cloud_workflow(workflow([build]))

    def test_mode_comes_from_the_committed_config(self):
        self.assertEqual(gate.gate_mode(), 'test-action')
        with mock.patch.object(gate, 'gate_config', return_value={'xcodeCloudPrGateMode': 'other'}), self.assertRaises(RuntimeError):
            gate.gate_mode()


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
        self.assertEqual(self.store.get_json('sessions/gates/pr-8.json')['phase'], 'blocked')
        # The worker repairs and makes a new Ready request R2 (Draft cleared, dispatch queued).
        self.store.put_json('sessions/4/gate-request.json', dict(self.request, request='req2'))
        self.gh.pr['draft'] = False

    def test_reconcile_starts_the_workers_fresh_request_and_the_queued_dispatch_keeps_it(self):
        self.block_previous_gate()
        self.controller.reconcile()  # the minute loop of another control run sees the Ready PR first
        record = self.store.get_json('sessions/gates/pr-8.json')
        self.assertEqual((record['request'], record['phase']), ('req2', 'waiting'))
        self.assertEqual(self.store.get_json('sessions/4/gate-request.json')['request'], 'req2')
        self.controller.start(8, 'req2')  # the queued agent-gate dispatch of the worker
        record = self.store.get_json('sessions/gates/pr-8.json')
        self.assertEqual((record['request'], record['phase']), ('req2', 'waiting'))
        self.assertFalse(self.gh.pr['draft'])
        self.assertEqual([body['inputs']['ci_request'] for _, _, body in self.dispatches('agent-tests.yml')], ['req2'])

    def test_a_superseded_dispatch_does_not_stop_the_newer_gate(self):
        self.block_previous_gate()
        self.controller.start(8, 'req2')
        self.controller.start(8, 'req1')  # a late duplicate of the old request
        record = self.store.get_json('sessions/gates/pr-8.json')
        self.assertEqual((record['request'], record['phase']), ('req2', 'waiting'))
        self.assertFalse(self.gh.pr['draft'])

    def test_a_failed_start_of_another_request_leaves_the_running_gate(self):
        self.controller.start(8, 'req1')
        with mock.patch.object(gate, 'request_data', side_effect=RuntimeError('evidence unreadable')), \
                self.assertRaises(RuntimeError):
            self.controller.start(8)
        record = self.store.get_json('sessions/gates/pr-8.json')
        self.assertEqual((record['request'], record['phase']), ('req1', 'waiting'))
        self.assertFalse(self.gh.pr['draft'])

    def test_a_transient_poll_error_never_blocks_a_running_gate(self):
        self.controller.start(8, 'req1')
        with mock.patch.object(self.controller, 'workflow_result', side_effect=OSError('connection reset')), \
                self.assertRaises(OSError):
            self.controller.start(8, 'req1')
        self.assertEqual(self.store.get_json('sessions/gates/pr-8.json')['phase'], 'waiting')
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
            self.controller.poll(self.store.get_json('sessions/gates/pr-8.json'))
        self.assertEqual(self.wakes(), [])
        self.controller.reconcile()
        self.assertEqual(gate.gate_status(self.gh, 'a' * 40), 'success')
        self.assertEqual(len(self.wakes()), 1)
        self.assertFalse(gate.consume_result(4, 'req1', self.gh, self.store))  # completes, does not repair
        self.assertEqual(self.store.get_json('sessions/4/state.json')['validatedGate'], 'req1')

    def test_a_record_written_by_another_job_is_refused_and_replaced(self):
        self.controller.start(8, 'req1')
        forged = dict(self.store.get_json('sessions/gates/pr-8.json'), cloudRun='a-build-that-passed-on-retry',
                      backend='xcode-cloud', workflow='workflow1')
        forged.pop('signature')
        self.store.put_json('sessions/gates/pr-8.json', forged)
        with mock.patch.object(gate, 'cloud_client') as client:
            with self.assertRaisesRegex(RuntimeError, 'not signed'):
                self.controller.start(8, 'req1')
            client.assert_not_called()
        record = self.store.get_json('sessions/gates/pr-8.json')
        self.assertEqual(record['phase'], 'blocked')
        self.assertTrue(self.gh.pr['draft'])
        self.assertEqual(gate.gate_status(self.gh, 'a' * 40), 'error')
        # A copied signature does not cover changed fields either.
        signed = self.store.get_json('sessions/gates/pr-8.json')
        self.store.put_json('sessions/gates/pr-8.json', dict(signed, phase='complete', success=True))
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


class GateSecondReviewTests(unittest.TestCase):
    setUp = fixtures.GateTests.setUp
    results = fixtures.GateTests.results
    dispatches = fixtures.GateTests.dispatches
    wakes = fixtures.GateTests.wakes

    def complete(self):
        record = self.controller.start(8, 'req1')
        self.results()
        return self.controller.poll(record)

    def age_wake(self, minutes):
        import datetime
        record = self.controller.load(8)
        woken = datetime.datetime.now(datetime.timezone.utc) - datetime.timedelta(minutes=minutes)
        record['wokenAt'] = woken.isoformat().replace('+00:00', 'Z')
        self.controller.save(record)

    def test_an_issue_whose_route_run_failed_is_woken_again_but_not_forever(self):
        self.complete()
        self.assertEqual(len(self.wakes()), 1)
        self.controller.reconcile()
        self.assertEqual(len(self.wakes()), 1)  # too early to tell a failure from a slow route
        for expected in (2, 3, 3):
            self.age_wake(30)
            self.controller.reconcile()
            self.assertEqual(len(self.wakes()), expected)

    def test_a_processed_result_is_never_woken_again(self):
        self.complete()
        self.assertFalse(gate.consume_result(4, 'req1', self.gh, self.store))
        self.age_wake(30)
        self.controller.reconcile()
        self.assertEqual(len(self.wakes()), 1)

    def test_a_build_without_a_source_commit_yet_does_not_block_the_start(self):
        record = dict(self.request, head='a' * 40, branch='work')
        client = mock.Mock()
        client.paginate.return_value = [{'id': 'ref1', 'attributes': {'canonicalName': 'refs/heads/work'}}]
        client.request.return_value = {'data': {'id': 'build1', 'attributes': {'sourceCommit': None}}}
        workflow = {'id': 'workflow1', 'relationships': {'repository': {'data': {'id': 'repo1'}}}}
        with mock.patch.object(gate, 'cloud_client', return_value=client):
            gate.start_cloud_build(record, workflow, lambda saved: None)
        self.assertEqual(record['cloudRun'], 'build1')

    def test_a_pending_cloud_build_without_a_source_commit_keeps_waiting(self):
        record = self.controller.start(8, 'req1')
        record.update(backend='xcode-cloud', cloudRun='cloud1', workflow='workflow1', url='https://cloud.example/run')
        self.results()
        client = mock.Mock()
        client.request.return_value = {'data': {'id': 'cloud1', 'attributes': {'sourceCommit': None, 'executionProgress': 'PENDING'},
                                                'relationships': {'workflow': {'data': {'id': 'workflow1'}}}}}
        with mock.patch.object(gate, 'cloud_client', return_value=client):
            self.assertEqual(self.controller.poll(record)['phase'], 'waiting')

    def test_malformed_records_are_refused_without_stopping_other_prs(self):
        self.controller.start(8, 'req1')
        self.store.put_json('sessions/gates/pr-998.json', ['x'])
        self.store.put_json('sessions/gates/pr-999.json', {'pr': 999, 'phase': 'waiting', 'signature': 'é'})
        for number in (998, 999):
            with self.assertRaises(gate.TamperedRecord):
                self.controller.load(number)
        self.assertEqual([record['pr'] for record in self.controller.waiting()], [8])
        self.results()
        self.controller.reconcile()
        self.assertTrue(self.controller.load(8)['success'])

    def test_a_store_error_while_reading_the_running_gate_does_not_block_it(self):
        self.controller.start(8, 'req1')
        original = self.controller.load
        calls = []
        def flaky(number):
            calls.append(number)
            if len(calls) == 2:
                raise OSError('store unavailable')
            return original(number)
        with mock.patch.object(self.controller, 'load', side_effect=flaky), self.assertRaises(OSError):
            self.controller.start(8)
        record = self.controller.load(8)
        self.assertEqual((record['request'], record['phase']), ('req1', 'waiting'))
        self.assertFalse(self.gh.pr['draft'])

    def test_a_fork_pr_never_starts_or_blocks_a_gate(self):
        self.gh.pr['head']['repo']['full_name'] = 'outsider/repo'
        self.controller.reconcile()
        self.assertIsNone(self.controller.start(8))
        self.assertEqual(self.store.get_json('sessions/gates/pr-8.json'), None)
        self.assertFalse(self.gh.pr['draft'])
        self.assertEqual([call for call in self.gh.calls if call[0] == 'comment'], [])

    def test_gate_workflow_dispatches_are_sent_once(self):
        with mock.patch.object(self.gh, 'request_once', wraps=self.gh.request_once) as once:
            self.controller.start(8, 'req1')
        self.assertEqual(sorted(call.args[1].split('/workflows/')[1].split('/')[0] for call in once.call_args_list),
                         ['agent-tests.yml', 'ios.yml'])

    def test_a_fresh_ready_on_a_new_head_is_started_not_redrafted(self):
        self.controller.start(8, 'req1')
        # The agent pushes a repair and makes a new Ready request; its dispatch is still queued.
        self.gh.pr['head']['sha'] = 'b' * 40
        checkpoint = dict(self.request['checkpoint'], head='b' * 40)
        self.store.put_json('sessions/4/gate-request.json', dict(self.request, request='req2', head='b' * 40, checkpoint=checkpoint))
        with mock.patch.object(gate.delivery, 'request_evidence', side_effect=lambda store, request: fixtures_evidence(self)), \
                mock.patch.object(gate.delivery, 'verified', return_value=True):
            self.controller.reconcile()
        record = self.controller.load(8)
        self.assertEqual((record['request'], record['head'], record['phase']), ('req2', 'b' * 40, 'waiting'))
        self.assertFalse(self.gh.pr['draft'])


def fixtures_evidence(test):
    files = test.store.artifacts.items[test.request['checkpoint']['artifact']['id']]['files']
    return {name: files[name] for name in ('local-verification.json', 'request-snapshot.json', 'work-items.json')}


class GitHubClientTests(unittest.TestCase):
    def test_a_call_sent_once_is_not_repeated_after_a_server_error(self):
        import io
        import urllib.error
        import agentlib
        client = agentlib.GitHub(token='t', repository='owner/repo')
        calls = []
        def urlopen(request, timeout):
            calls.append(request.get_method())
            raise urllib.error.HTTPError(request.full_url, 502, 'bad gateway', {}, io.BytesIO(b''))
        with mock.patch.object(agentlib.urllib.request, 'urlopen', side_effect=urlopen), \
                mock.patch.object(agentlib.time, 'sleep'), self.assertRaisesRegex(RuntimeError, 'HTTP 502'):
            client.request_once('POST', '/repos/owner/repo/actions/workflows/ios.yml/dispatches', {})
        self.assertEqual(calls, ['POST'])
        calls.clear()
        with mock.patch.object(agentlib.urllib.request, 'urlopen', side_effect=urlopen), \
                mock.patch.object(agentlib.time, 'sleep'), self.assertRaises(RuntimeError):
            client.get('/repos/owner/repo')
        self.assertEqual(len(calls), 4)  # reads are retried
