import io
import json
from pathlib import Path
import sys
import tempfile
import unittest
from contextlib import redirect_stdout, redirect_stderr

sys.path.insert(0, str(Path(__file__).resolve().parent))
import ui_test_plan  # noqa: E402

SOURCE = '''import XCTest

final class AlphaUITests: XCTestCase {
    private struct Helper { func testNotATest() {} }
    enum Mode { case a }
    func testOne() throws {}
    @MainActor
    func testTwo() {}
    func helper() {}
}

extension AlphaUITests {
    func testThree() {}
}

@MainActor final class BetaUITests: XCTestCase {
    func testFour() {}
}

class BaseUITestCase: XCTestCase {}

class GammaUITests: BaseUITestCase {
    override func testFive() {}
}

func testFreeFunction() {}
'''


class DiscoverTests(unittest.TestCase):
    def discover(self, source):
        with tempfile.TemporaryDirectory() as directory:
            Path(directory, 'A.swift').write_text(source)
            return ui_test_plan.discover(Path(directory))

    def test_finds_test_methods_including_attributes_extensions_and_subclasses(self):
        self.assertEqual(self.discover(SOURCE), [
            'AlphaUITests/testOne', 'AlphaUITests/testThree', 'AlphaUITests/testTwo',
            'BetaUITests/testFour', 'GammaUITests/testFive'])

    def test_unattributed_test_function_fails_instead_of_being_skipped(self):
        for extra in ('struct Support {\n    func testIgnored() {}\n}\n',
                      'extension XCUIApplication {\n    func testAlsoIgnored() {}\n}\n',
                      'class NotATest: NSObject {\n    func testNope() {}\n}\n'):
            with self.subTest(extra=extra), self.assertRaises(SystemExit):
                self.discover(SOURCE + extra)

    def test_repository_plan_covers_every_discovered_test(self):
        plan = json.loads(ui_test_plan.PLAN.read_text())
        tests = ui_test_plan.discover()
        self.assertTrue(tests)
        everything = sorted(test for _, part in ui_test_plan.shard(tests, plan['shards'], plan['durations']) for test in part)
        self.assertEqual(everything, tests)

    def test_repository_discovery_matches_every_test_function(self):
        lines = sum(1 for source in ui_test_plan.TESTS.glob('*.swift')
                    for line in source.read_text().splitlines() if ui_test_plan.ANY_TEST_FUNC.match(line))
        self.assertEqual(len(ui_test_plan.discover()), lines)


class ShardTests(unittest.TestCase):
    def test_every_test_lands_in_exactly_one_shard(self):
        tests = [f'C/test{i}' for i in range(10)]
        parts = ui_test_plan.shard(tests, 3, {})
        flat = [test for _, part in parts for test in part]
        self.assertEqual(sorted(flat), sorted(tests))
        self.assertEqual(len(flat), len(set(flat)))

    def test_balances_by_duration(self):
        durations = {'C/a': 600, 'C/b': 300, 'C/c': 300, 'C/d': 100}
        loads = sorted(load for load, _ in ui_test_plan.shard(list(durations), 2, durations))
        self.assertEqual(loads, [600, 700])

    def test_more_shards_than_tests_leaves_empty_shards(self):
        parts = ui_test_plan.shard(['C/a'], 3, {})
        self.assertEqual(sum(1 for _, part in parts if part), 1)


class SelectTests(unittest.TestCase):
    tests = ['A/test1', 'A/test2', 'B/test1', 'C/test1']

    def test_full_tier_and_plan_without_pr_list_run_everything(self):
        self.assertEqual(ui_test_plan.select(self.tests, {'pr': ['A']}, 'full', []), self.tests)
        self.assertEqual(ui_test_plan.select(self.tests, {}, 'pr', ['x.swift']), self.tests)

    def test_pr_tier_runs_core_classes_and_classes_for_changed_paths(self):
        plan = {'pr': ['A'], 'paths': {'strius/Features/Chat/*': ['C'], 'strius/Camera/*': ['B']}}
        selected = ui_test_plan.select(self.tests, plan, 'pr', ['strius/Features/Chat/ChatView.swift'])
        self.assertEqual(selected, ['A/test1', 'A/test2', 'C/test1'])

    def test_unknown_class_in_plan_fails_loudly(self):
        with self.assertRaises(SystemExit):
            ui_test_plan.select(self.tests, {'pr': ['Missing']}, 'pr', [])


class MainTests(unittest.TestCase):
    def test_prints_only_testing_arguments_for_the_shard(self):
        with tempfile.TemporaryDirectory() as directory:
            plan = Path(directory, 'plan.json')
            plan.write_text(json.dumps({'shards': 1, 'durations': {}}))
            out = io.StringIO()
            with redirect_stdout(out), redirect_stderr(io.StringIO()):
                ui_test_plan.main(['--shard', '0', '--plan', str(plan)])
            lines = out.getvalue().split()
            self.assertEqual(len(lines), len(ui_test_plan.discover()))
            self.assertTrue(all(line.startswith('-only-testing:striusUITests/') for line in lines))

    def test_matrix_lists_only_non_empty_shards_and_covers_everything(self):
        with tempfile.TemporaryDirectory() as directory:
            plan = Path(directory, 'plan.json')
            plan.write_text(json.dumps({'shards': 3, 'pr': ['WorkbookHomeUITests']}))
            out = io.StringIO()
            with redirect_stdout(out), redirect_stderr(io.StringIO()):
                ui_test_plan.main(['--matrix', '--tier', 'pr', '--plan', str(plan)])
            matrix = json.loads(out.getvalue())
            expected = [test for test in ui_test_plan.discover() if test.startswith('WorkbookHomeUITests/')]
            self.assertEqual(len(matrix), min(3, len(expected)))
            listed = sorted(arg.split('striusUITests/', 1)[1] for item in matrix for arg in item['tests'].split())
            self.assertEqual(listed, expected)
            self.assertTrue(all(item['count'] > 0 for item in matrix))

    def test_rejects_out_of_range_shard(self):
        with tempfile.TemporaryDirectory() as directory:
            plan = Path(directory, 'plan.json')
            plan.write_text(json.dumps({'shards': 2}))
            with self.assertRaises(SystemExit):
                ui_test_plan.main(['--shard', '2', '--plan', str(plan)])


if __name__ == '__main__':
    unittest.main()
