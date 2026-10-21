import copy
import unittest
import receipt_experiment as r


class ReceiptSafetyTests(unittest.TestCase):
    def setUp(self):
        self.tree = {'truncated': False, 'tree': [
            {'path': 'strius/Engine/WorkbookRules.swift', 'mode': '100644', 'type': 'blob', 'sha': 'a' * 40},
            {'path': 'unknown/new-build-input.dat', 'mode': '100644', 'type': 'blob', 'sha': 'b' * 40},
            {'path': 'docs/ci-experiments/results.md', 'mode': '100644', 'type': 'blob', 'sha': 'c' * 40}]}
        self.policy = {'uiTests': ['A/testA', 'B/testB'], 'allowedUISkips': ['B/testB'],
                       'unitTotal': 3, 'unitSkipped': 1}
        self.unit = {'result': 'Passed', 'failedTests': 0, 'totalTestCount': 3, 'passedTests': 2, 'skippedTests': 1}
        self.ui = {'result': 'Passed', 'failedTests': 0, 'totalTestCount': 2, 'passedTests': 1, 'skippedTests': 1}
        self.nodes = {'testNodes': [
            {'nodeType': 'Test Case', 'nodeIdentifier': 'A/testA()', 'result': 'Passed'},
            {'nodeType': 'Test Case', 'nodeIdentifier': 'B/testB()', 'result': 'Skipped'}]}

    def test_report_only_change_can_reuse(self):
        changed = copy.deepcopy(self.tree)
        changed['tree'][2]['sha'] = 'd' * 40
        self.assertEqual(r.fingerprint(self.tree, {}), r.fingerprint(changed, {}))

    def test_code_and_unknown_inputs_invalidate(self):
        for index in (0, 1):
            changed = copy.deepcopy(self.tree)
            changed['tree'][index]['sha'] = 'e' * 40
            self.assertNotEqual(r.fingerprint(self.tree, {}), r.fingerprint(changed, {}))

    def test_environment_change_invalidates(self):
        self.assertNotEqual(r.fingerprint(self.tree, {'workers': 1}), r.fingerprint(self.tree, {'workers': 2}))

    def test_truncated_inventory_is_rejected(self):
        with self.assertRaises(ValueError):
            r.fingerprint({'truncated': True, 'tree': self.tree['tree']}, {})

    def test_missing_method_cannot_be_green(self):
        with self.assertRaises(ValueError):
            r.validate_results(self.unit, self.ui, {'testNodes': self.nodes['testNodes'][:1]}, self.policy)

    def test_unexpected_skip_cannot_be_green(self):
        self.nodes['testNodes'][0]['result'] = 'Skipped'
        with self.assertRaises(ValueError):
            r.validate_results(self.unit, self.ui, self.nodes, self.policy)

    def test_failed_unit_cannot_be_green(self):
        self.unit['failedTests'] = 1
        with self.assertRaises(ValueError):
            r.validate_results(self.unit, self.ui, self.nodes, self.policy)

    def test_valid_complete_inventory(self):
        r.validate_results(self.unit, self.ui, self.nodes, self.policy)

    def test_failed_origin_job_is_rejected(self):
        with self.assertRaises(ValueError):
            r.validate_origin({'status': 'completed', 'conclusion': 'failure'},
                              {'workflow_run': {}}, b'', 'a' * 40, 0)

