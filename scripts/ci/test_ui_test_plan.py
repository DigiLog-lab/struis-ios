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

    def test_any_modifier_or_attribute_before_a_test_is_found(self):
        source = '''import XCTest

@MainActor
final class DeltaUITests: XCTestCase {
    nonisolated func testA() {}
    @available(iOS 18, *) func testB() {}
    public func testC() async throws {}
    @MainActor override func testD() throws {}
    private func testHidden() {}
    // func testOld() {}
    func testWithArgument(_ value: Int) {}
}
'''
        self.assertEqual(self.discover(source), [
            'DeltaUITests/testA', 'DeltaUITests/testB', 'DeltaUITests/testC', 'DeltaUITests/testD'])

    def test_nested_types_strings_and_block_comments_do_not_confuse_discovery(self):
        source = '''import XCTest

final class EpsilonUITests: XCTestCase {
    final class Delegate: NSObject {
        func helper() {}
    }
    let script = """
    func testInsideString() {}
    """
    /*
    func testCommentedOut() {}
    */
    func testReal() {}
}
'''
        self.assertEqual(self.discover(source), ['EpsilonUITests/testReal'])

    def test_stray_triple_quotes_and_comments_do_not_hide_tests(self):
        source = '''import XCTest

@MainActor
final class EtaUITests: XCTestCase {
    /// splits on """ markers
    func testA() {}
    /* func testOld() {} */
    let x = 1 /* start
    func testInComment() {}
    end */
    static func testStatic() {}
    func testB() {}
}

@MainActor extension EtaUITests {
    func testC() {}
}
'''
        self.assertEqual(self.discover(source), ['EtaUITests/testA', 'EtaUITests/testB', 'EtaUITests/testC'])

    def test_file_ending_inside_a_string_or_comment_fails(self):
        for tail in ('let s = """\nnever closed\n', '/*\nnever closed\n'):
            with self.subTest(tail=tail), self.assertRaises(SystemExit):
                self.discover('final class ThetaUITests: XCTestCase {\n    func testA() {}\n}\n' + tail)

    def test_inherited_test_methods_run_in_each_subclass(self):
        source = '''import XCTest

class SharedUITests: XCTestCase {
    func testShared() {}
}

final class SubUITests: SharedUITests {
    func testOwn() {}
}
'''
        self.assertEqual(self.discover(source), [
            'SharedUITests/testShared', 'SubUITests/testOwn', 'SubUITests/testShared'])

    def test_conditional_duplicates_are_listed_once(self):
        source = '''import XCTest

final class ZetaUITests: XCTestCase {
#if DEBUG
    func testA() {}
#else
    func testA() {}
#endif
}
'''
        self.assertEqual(self.discover(source), ['ZetaUITests/testA'])

    def test_tests_in_subfolders_are_found(self):
        with tempfile.TemporaryDirectory() as directory:
            Path(directory, 'Chat').mkdir()
            Path(directory, 'Chat', 'IotaUITests.swift').write_text(
                'import XCTest\n\nfinal class IotaUITests: XCTestCase {\n    func testA() {}\n}\n')
            self.assertEqual(ui_test_plan.discover(Path(directory)), ['IotaUITests/testA'])

    def test_repository_plan_covers_every_discovered_test(self):
        plan = json.loads(ui_test_plan.PLAN.read_text())
        tests = ui_test_plan.discover()
        self.assertTrue(tests)
        count = ui_test_plan.shard_count(plan, 'full')
        everything = sorted(test for _, part in ui_test_plan.shard(tests, count, plan['durations']) for test in part)
        self.assertEqual(everything, tests)

    def test_repository_discovery_matches_every_test_function(self):
        names = {(source.stem, line.split('func', 1)[1].split('(')[0].strip())
                 for source in ui_test_plan.TESTS.rglob('*.swift')
                 for line in source.read_text().splitlines()
                 if 'func test' in line and not line.strip().startswith('//') and '(_' not in line}
        self.assertEqual(len(ui_test_plan.discover()), len(names))


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

    def test_a_path_mapped_to_everything_runs_every_test(self):
        plan = {'pr': ['A'], 'paths': {'strius.xcodeproj/*': ['*']}}
        self.assertEqual(ui_test_plan.select(self.tests, plan, 'pr', ['strius.xcodeproj/project.pbxproj']), self.tests)

    def test_a_changed_test_file_adds_its_class_and_shared_support_runs_everything(self):
        plan = {'pr': ['A']}
        self.assertEqual(ui_test_plan.select(self.tests, plan, 'pr', ['striusUITests/C.swift']), ['A/test1', 'A/test2', 'C/test1'])
        self.assertEqual(ui_test_plan.select(self.tests, plan, 'pr', ['striusUITests/UITestSupport.swift']), self.tests)

    def test_shard_count_per_tier(self):
        self.assertEqual(ui_test_plan.shard_count({'shards': 3}, 'pr'), 3)
        self.assertEqual(ui_test_plan.shard_count({'shards': {'pr': 2, 'full': 3}}, 'pr'), 2)
        self.assertEqual(ui_test_plan.shard_count({'shards': {'pr': 2, 'full': 3}}, 'full'), 3)
        self.assertEqual(ui_test_plan.shard_count({}, 'full'), 1)

    def test_repository_plan_names_only_known_classes(self):
        plan = json.loads(ui_test_plan.PLAN.read_text())
        known = {test.split('/')[0] for test in ui_test_plan.discover()}
        named = set(plan['pr']) | {c for classes in plan['paths'].values() for c in classes if c != '*'}
        self.assertEqual(named - known, set())

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
