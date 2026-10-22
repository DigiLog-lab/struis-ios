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

    def test_methods_inside_nested_helper_types_are_not_tests(self):
        with tempfile.TemporaryDirectory() as directory:
            Path(directory, 'OuterUITests.swift').write_text(
                'import XCTest\n\nfinal class OuterUITests: XCTestCase {\n'
                '    struct Helper {\n        func testConnection() {}\n        enum Deeper {\n            static func testStatic() {}\n        }\n    }\n'
                '    private enum Fixture { case a }\n'
                '    func testReal() {}\n'
                '    struct Empty {}\n'
                '    func testAlsoReal() {}\n'
                '}\n')
            self.assertEqual(ui_test_plan.discover(Path(directory)), ['OuterUITests/testAlsoReal', 'OuterUITests/testReal'])

    def test_local_functions_inside_methods_and_closures_are_not_tests(self):
        source = '''import XCTest

final class LocalUITests: XCTestCase {
    func testReal() {
        func testConnection() {}
        let fixture = "{\\"a\\": {\\"b\\": 1}"
        let run = {
            func testInClosure() {}
        }
        run()
    }
    lazy var helper: () -> Void = {
        func testInProperty() {}
    }
    func testAlsoReal() { func testInline() {} }
    func helper() { func testSameLine() {} }
    @MainActor func testWithAttribute() {}
}

extension LocalUITests {
    func testInExtension() {
        func testNested() {}
    }
}
'''
        self.assertEqual(self.discover(source), [
            'LocalUITests/testAlsoReal', 'LocalUITests/testInExtension', 'LocalUITests/testReal', 'LocalUITests/testWithAttribute'])

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


def toy_plan(**extra):
    plan = {
        'schema': 2,
        'contracts': {
            'chat': {'property': 'chat', 'tests': ['A/test1', 'A/test2'], 'paths': ['strius/Features/Chat/ChatView.swift']},
            'camera': {'property': 'camera', 'tests': ['B/test1'], 'paths': ['strius/Features/Chat/ChatCamera.swift']},
        },
        'everything': ['strius/Design/**'],
        'folders': {'strius/Features/Chat/Prototype.swift': [], 'strius/Features/Chat/**': ['chat']},
        'guarded': ['strius/**', 'striusUITests/**', 'strius.xcodeproj/**'],
        'manual': {'C/test1': 'real device'},
        'excluded': {},
    }
    plan.update(extra)
    return plan


ADD_FILE_DIFF = (
    'diff --git a/strius.xcodeproj/project.pbxproj b/strius.xcodeproj/project.pbxproj\n'
    '--- a/strius.xcodeproj/project.pbxproj\n+++ b/strius.xcodeproj/project.pbxproj\n'
    '@@ -230,0 +231 @@\n'
    '+\t\tF7E9128C22CCD0084818A056 /* NewThing.swift in Sources */ = {isa = PBXBuildFile; fileRef = F8E9128C22CCD0084818A056 /* NewThing.swift */; };\n'
    '@@ -501,0 +503 @@\n'
    '+\t\tF8E9128C22CCD0084818A056 /* NewThing.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = NewThing.swift; sourceTree = "<group>"; };\n'
    '@@ -917,0 +920 @@\n+\t\t\t\tF8E9128C22CCD0084818A056 /* NewThing.swift */,\n'
    '@@ -1437,0 +1441 @@\n+\t\t\t\tF7E9128C22CCD0084818A056 /* NewThing.swift in Sources */,\n')
SETTINGS_DIFF = ('--- a/strius.xcodeproj/project.pbxproj\n+++ b/strius.xcodeproj/project.pbxproj\n@@ -1676 +1676 @@\n'
                 '-\t\t\t\tPRODUCT_BUNDLE_IDENTIFIER = com.digiloglab.strius.runtime;\n'
                 '+\t\t\t\tPRODUCT_BUNDLE_IDENTIFIER = "$(STRUIS_BUNDLE_ID_BASE).runtime";\n')


class SelectTests(unittest.TestCase):
    tests = ['A/test1', 'A/test2', 'B/test1', 'C/test1']

    def select(self, changed, plan=None, diff=None):
        return ui_test_plan.select(self.tests, plan or toy_plan(), 'pr', changed, diff)

    def test_full_tier_runs_every_discovered_test(self):
        self.assertEqual(ui_test_plan.select(self.tests, toy_plan(), 'full', []), self.tests)

    def test_a_changed_file_runs_only_its_contracts(self):
        self.assertEqual(self.select(['strius/Features/Chat/ChatCamera.swift']), ['B/test1'])
        self.assertEqual(self.select(['strius/Features/Chat/ChatView.swift', 'strius/Features/Chat/ChatCamera.swift']),
                         ['A/test1', 'A/test2', 'B/test1'])

    def test_a_change_no_contract_covers_runs_no_ui_test(self):
        self.assertEqual(self.select(['docs/testing.md', 'striusTests/RulesTests.swift', 'scripts/agent/gate.py']), [])
        self.assertEqual(self.select([]), [])

    def test_unknown_diff_runs_every_contract_but_never_manual_tests(self):
        self.assertEqual(self.select(None), ['A/test1', 'A/test2', 'B/test1'])

    def test_everything_runs_every_contract_test(self):
        self.assertEqual(self.select(['strius/Design/Theme.swift']), ['A/test1', 'A/test2', 'B/test1'])

    def test_folder_default_covers_a_file_no_contract_names_first_match_wins(self):
        self.assertEqual(self.select(['strius/Features/Chat/NewBubble.swift']), ['A/test1', 'A/test2'])
        self.assertEqual(self.select(['strius/Features/Chat/Prototype.swift']), [])

    def test_unmapped_app_source_stops_the_plan(self):
        with self.assertRaises(ui_test_plan.PlanError) as raised:
            self.select(['strius/Engine/NewRules.swift'])
        self.assertIn('strius/Engine/NewRules.swift', str(raised.exception))

    def test_project_file_adding_a_file_selects_nothing_settings_select_everything(self):
        self.assertEqual(self.select(['strius.xcodeproj/project.pbxproj'], diff=ADD_FILE_DIFF), [])
        self.assertEqual(self.select(['strius.xcodeproj/project.pbxproj', 'strius/Features/Chat/ChatCamera.swift'],
                                     diff=ADD_FILE_DIFF), ['B/test1'])
        everything = ['A/test1', 'A/test2', 'B/test1']
        self.assertEqual(self.select(['strius.xcodeproj/project.pbxproj'], diff=SETTINGS_DIFF), everything)
        self.assertEqual(self.select(['strius.xcodeproj/project.pbxproj'], diff=None), everything)
        self.assertEqual(self.select(['strius.xcodeproj/project.pbxproj'], diff=ADD_FILE_DIFF + SETTINGS_DIFF), everything)

    def test_validation_rejects_unclassified_unknown_and_double_classified_tests(self):
        with self.assertRaisesRegex(ui_test_plan.PlanError, 'in no contract'):
            ui_test_plan.select(self.tests + ['D/test1'], toy_plan(), 'pr', [])
        with self.assertRaisesRegex(ui_test_plan.PlanError, 'do not exist'):
            self.select([], toy_plan(manual={'C/test1': 'x', 'Z/test9': 'x'}))
        with self.assertRaisesRegex(ui_test_plan.PlanError, 'classified twice'):
            self.select([], toy_plan(manual={'C/test1': 'x', 'B/test1': 'x'}))
        with self.assertRaisesRegex(ui_test_plan.PlanError, 'unknown contracts'):
            self.select([], toy_plan(folders={'strius/**': ['nope']}))
        with self.assertRaisesRegex(ui_test_plan.PlanError, 'schema 2'):
            self.select([], {'pr': ['A']})


class RepositoryPlanTests(unittest.TestCase):
    plan = json.loads(ui_test_plan.PLAN.read_text())
    tests = ui_test_plan.discover()

    def select(self, *changed, diff=None):
        return ui_test_plan.select(self.tests, self.plan, 'pr', list(changed), diff)

    def contract(self, name):
        return sorted(self.plan['contracts'][name]['tests'])

    def test_every_discovered_test_is_classified(self):
        ui_test_plan.validate(self.plan, self.tests)

    def test_every_app_source_file_is_covered(self):
        sources = [str(path.relative_to(ui_test_plan.ROOT)) for root in ('strius', 'NativeRuntime')
                   for path in (ui_test_plan.ROOT / root).rglob('*') if path.is_file()]
        for path in sources:
            ui_test_plan.contracts_for(path, self.plan)  # raises PlanError for an uncovered file

    def test_typical_changes_select_their_contracts(self):
        self.assertEqual(self.select('strius/Features/Workbook/WorkbookSubunitHeader.swift'), self.contract('subunit-header'))
        self.assertEqual(self.select('strius/Features/ImmersionLab/ScenePlayerView.swift'), self.contract('immersion'))
        self.assertEqual(self.select('strius/Engine/WorkbookRules.swift'), self.contract('workbook-grading'))
        self.assertEqual(self.select('strius/State/ChatTurnCoordinator.swift'), self.contract('reply-tail'))
        self.assertEqual(self.select('strius/State/MainThreadWatchdog.swift'), [])
        self.assertEqual(self.select('docs/testing.md', 'striusTests/Ledger/ReplyTailQueueTests.swift'), [])

    def test_shared_files_select_every_contract(self):
        every = sorted({test for contract in self.plan['contracts'].values() for test in contract['tests']})
        for path in ('strius/Runtime/MockTurnRunner.swift', 'strius/Design/Theme.swift', 'Info.plist',
                     'striusUITests/UITestSupport.swift', '.github/workflows/ios.yml',
                     'strius.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved'):
            self.assertEqual(self.select(path), every, path)

    def test_a_changed_ui_test_file_runs_its_own_contract_tests_only(self):
        self.assertEqual(self.select('striusUITests/WorkbookSubunitHeaderUITests.swift'), self.contract('subunit-header'))
        self.assertEqual(self.select('striusUITests/ChatTypingExperienceUITests.swift'), [])

    def test_manual_and_excluded_tests_have_reasons(self):
        for name, reason in {**self.plan['manual'], **self.plan['excluded']}.items():
            self.assertTrue(reason.strip(), name)


class MainTests(unittest.TestCase):
    def run_main(self, *args):
        out = io.StringIO()
        with redirect_stdout(out), redirect_stderr(io.StringIO()):
            ui_test_plan.main(list(args))
        return out.getvalue()

    def test_list_prints_the_selection_and_reasons(self):
        with tempfile.TemporaryDirectory() as directory:
            changed = Path(directory, 'changed.txt')
            changed.write_text('strius/Features/Workbook/WorkbookSubunitHeader.swift\ndocs/testing.md\n')
            result = json.loads(self.run_main('--list', '--changed-files', str(changed)))
            self.assertEqual(result['reasons'], {'subunit-header': ['strius/Features/Workbook/WorkbookSubunitHeader.swift']})
            self.assertEqual(len(result['uiTests']), 2)
            changed.write_text('scripts/agent/agentctl.py\n')
            self.assertEqual(json.loads(self.run_main('--list', '--changed-files', str(changed)))['uiTests'], [])
            self.assertTrue(json.loads(self.run_main('--list', '--no-diff'))['uiTests'])

    def test_prints_only_testing_arguments_for_the_full_shard(self):
        with tempfile.TemporaryDirectory() as directory:
            plan = json.loads(ui_test_plan.PLAN.read_text())
            plan['shards'] = {'full': 1}
            path = Path(directory, 'plan.json')
            path.write_text(json.dumps(plan))
            lines = self.run_main('--shard', '0', '--plan', str(path)).split()
            self.assertEqual(len(lines), len(ui_test_plan.discover()))
            self.assertTrue(all(line.startswith('-only-testing:striusUITests/') for line in lines))

    def test_matrix_covers_every_test_and_rejects_out_of_range_shard(self):
        matrix = json.loads(self.run_main('--matrix'))
        listed = sorted(arg.split('striusUITests/', 1)[1] for item in matrix for arg in item['tests'].split())
        self.assertEqual(listed, ui_test_plan.discover())
        with self.assertRaises(SystemExit):
            self.run_main('--shard', '99')


if __name__ == '__main__':
    unittest.main()
