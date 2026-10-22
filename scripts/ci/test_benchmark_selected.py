import copy
import unittest

from benchmark_selected import PROBE, validate_exports


class ResultCompletenessTests(unittest.TestCase):
    def setUp(self):
        self.units = {'Rules/testPass()': 'Passed', 'External/testNeedsEnvironment()': 'Skipped'}
        self.selected = ['Buttons/testReady']
        self.nodes = {'testNodes': [self.case('striusTests', k, v) for k, v in self.units.items()]
                      + [self.case('striusUITests', k + '()', 'Passed') for k in self.selected + [PROBE]]}
        self.summary = {'totalTestCount': 4, 'passedTests': 3, 'skippedTests': 1,
                        'failedTests': 0, 'result': 'Passed'}

    def case(self, target, key, result):
        return {'nodeType': 'Test Case', 'nodeIdentifier': key, 'result': result,
                'nodeIdentifierURL': 'test://com.apple.xcode/strius/' + target + '/' + key}

    def check(self, nodes=None, summary=None):
        return validate_exports(summary or self.summary, nodes or self.nodes, self.units, self.selected)

    def test_accepts_complete_results_with_only_explicit_skips(self):
        self.assertEqual(self.check()['selectedUI'], 1)

    def test_rejects_missing_selected_ui_even_when_summary_claims_green(self):
        nodes = copy.deepcopy(self.nodes)
        nodes['testNodes'].pop(2)
        with self.assertRaisesRegex(ValueError, 'missing'):
            self.check(nodes=nodes)

    def test_rejects_new_skip_of_previously_passing_unit(self):
        nodes = copy.deepcopy(self.nodes)
        nodes['testNodes'][0]['result'] = 'Skipped'
        with self.assertRaisesRegex(ValueError, 'Unexpected pass/skip/failure'):
            self.check(nodes=nodes)

    def test_rejects_failure_despite_successful_command(self):
        nodes = copy.deepcopy(self.nodes)
        nodes['testNodes'][2]['result'] = 'Failed'
        with self.assertRaises(ValueError):
            self.check(nodes=nodes)

    def test_rejects_duplicate_case(self):
        nodes = copy.deepcopy(self.nodes)
        nodes['testNodes'].append(nodes['testNodes'][0])
        with self.assertRaisesRegex(ValueError, 'Duplicate'):
            self.check(nodes=nodes)

    def test_rejects_unrequested_ui_instead_of_accepting_full_suite(self):
        nodes = copy.deepcopy(self.nodes)
        nodes['testNodes'].append(self.case('striusUITests', 'Other/testExtra()', 'Passed'))
        with self.assertRaisesRegex(ValueError, 'unexpected'):
            self.check(nodes=nodes)

    def test_rejects_summary_count_disagreement(self):
        summary = dict(self.summary, totalTestCount=0)
        with self.assertRaisesRegex(ValueError, 'Summary mismatch'):
            self.check(summary=summary)


if __name__ == '__main__':
    unittest.main()
