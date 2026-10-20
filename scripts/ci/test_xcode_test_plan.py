import copy
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest import mock
import xml.etree.ElementTree as ET

sys.path.insert(0, str(Path(__file__).resolve().parent))
import ui_test_plan
import xcode_test_plan


class XcodePlanTests(unittest.TestCase):
    def setUp(self):
        self.tests = ui_test_plan.discover()
        self.selection = json.loads(ui_test_plan.PLAN.read_text())
        self.manifest = json.loads(xcode_test_plan.EXCLUSIONS.read_text())

    def test_gate_uses_the_local_selection_minus_only_the_reviewed_methods(self):
        for changed in ([], ['strius/Features/Chat/ChatView.swift'], ['strius/Design/Theme.swift']):
            with self.subTest(changed=changed):
                plan, report = xcode_test_plan.generate('pr', changed)
                local = set(ui_test_plan.select(self.tests, self.selection, 'pr', changed))
                excluded = {entry['test'] for entry in self.manifest['methods']}
                self.assertEqual(set(report['uiTests']), local - excluded)
                self.assertEqual(plan['testTargets'][1]['selectedTests'], [test + '()' for test in sorted(local - excluded)])
                # Excluding one camera method never removes its non-camera siblings.
                self.assertIn('WorkbookE2EFixesUITests/testIntroductionStartsWithoutTypingAndExampleIsPinned', report['uiTests'])
                self.assertIn('DeviceChatUITests/testQuestionTurnWithMockModel', report['uiTests'])

    def test_release_keeps_every_discovered_test_including_camera_methods(self):
        plan, report = xcode_test_plan.generate('full', [])
        self.assertEqual(report['uiTests'], self.tests)
        self.assertEqual(report['excludedUI'], [])
        # No unit-test filter can accidentally omit newly added unit tests.
        self.assertEqual(set(plan['testTargets'][0]), {'target'})

    def test_unavailable_diff_expands_the_gate_instead_of_using_only_e2e(self):
        _, report = xcode_test_plan.generate('pr', None)
        excluded = {entry['test'] for entry in self.manifest['methods']}
        self.assertEqual(set(report['uiTests']), set(self.tests) - excluded)
        self.assertTrue(report['allEligibleUI'])

    def test_stale_incomplete_and_duplicate_exclusions_fail(self):
        invalid = copy.deepcopy(self.manifest['methods'][0])
        for entry in (dict(invalid, test='DeletedTests/testOld'), dict(invalid, reason=''), dict(invalid, source='')):
            with self.subTest(entry=entry), self.assertRaises(ValueError):
                xcode_test_plan.generate('pr', [], manifest={'version': 1, 'methods': [entry]})
        with self.assertRaises(ValueError):
            xcode_test_plan.generate('pr', [], manifest={'version': 1, 'methods': [invalid, invalid]})

    def test_a_fully_excluded_selection_does_not_become_an_unfiltered_test_run(self):
        name = self.manifest['methods'][0]['test']
        with self.assertRaises(ValueError):
            xcode_test_plan.generate('pr', [], discovered=[name], selection={'pr': [name.split('/')[0]]},
                                     manifest={'version': 1, 'methods': [self.manifest['methods'][0]]})

    def test_bad_base_or_failed_fetch_expands_coverage(self):
        for failure in [subprocess.CalledProcessError(1, 'git'), subprocess.TimeoutExpired('git', 120)]:
            with self.subTest(failure=failure), mock.patch.object(subprocess, 'check_output', side_effect=failure):
                self.assertIsNone(xcode_test_plan.changed_files('main'))

    def test_frozen_plans_and_shared_schemes_are_consistent(self):
        root = xcode_test_plan.ROOT
        for tier, name, scheme in [('pr', 'PRGate', 'StruisPRGate'), ('full', 'Release', 'StruisRelease')]:
            with self.subTest(tier=tier):
                expected, _ = xcode_test_plan.generate(tier, None)
                self.assertEqual(json.loads((root / f'TestPlans/{name}.xctestplan').read_text()), expected)
                action = ET.parse(root / f'strius.xcodeproj/xcshareddata/xcschemes/{scheme}.xcscheme').getroot().find('TestAction')
                self.assertEqual(action.attrib['preferredScreenCaptureFormat'], 'screenshots')
                self.assertEqual(action.attrib['codeCoverageEnabled'], 'NO')
                self.assertEqual(action.find('TestPlans/TestPlanReference').attrib['reference'], f'container:TestPlans/{name}.xctestplan')
        original = ET.parse(root / 'strius.xcodeproj/xcshareddata/xcschemes/strius.xcscheme').getroot().find('TestAction')
        self.assertIsNotNone(original.find('Testables'))
        self.assertIsNone(original.find('TestPlans'))


class CloudShellTests(unittest.TestCase):
    """Exercise the real shell hook with fake host tools; do not simulate Xcode."""
    def test_stage_reports_failure_and_preserves_its_exit_code(self):
        helper = xcode_test_plan.ROOT / 'ci_scripts/timing.sh'
        result = subprocess.run(['sh', '-c', '. "$1"; run_stage example sh -c "exit 17"', 'sh', str(helper)],
                                capture_output=True, text=True)
        self.assertEqual(result.returncode, 17)
        self.assertIn('STRUIS_STAGE_START name=example', result.stdout)
        self.assertIn('exit_code=17', result.stdout)

    def test_gate_release_and_legacy_platforms_use_the_intended_sdks(self):
        root = xcode_test_plan.ROOT
        for scheme, workflow, expected in [('StruisPRGate', 'Renamed workflow', 'simulator'),
                                          ('StruisRelease', 'Release', 'both'), ('strius', 'Default', 'device')]:
            with self.subTest(scheme=scheme), tempfile.TemporaryDirectory() as directory:
                temporary = Path(directory)
                checkout = temporary / 'repo'
                (checkout / 'ci_scripts').mkdir(parents=True)
                for name in ['ci_post_clone.sh', 'timing.sh']:
                    (checkout / 'ci_scripts' / name).write_text((root / 'ci_scripts' / name).read_text())
                native = checkout / 'NativeRuntime/Vendor/NativeCodex.xcframework'
                native.mkdir(parents=True)
                (native / 'Info.plist').write_text('test')
                tools = temporary / 'bin'
                tools.mkdir()
                fake = ('#!/bin/sh\n'
                        'case "$(basename "$0")" in\n'
                        'brew) echo "$TEST_BIN_PARENT" ;;\n'
                        'python3.14) printf "%s\\n" "$*" >> "$TEST_CALLS"; '
                        'printf "%s\\n" "$CARGO_TARGET_DIR" >> "$TEST_CARGO" ;;\n'
                        'xcrun) case "$*" in *what-version*) echo 70;; esac ;;\n'
                        'esac\n')
                for name in ['brew', 'rustup', 'python3.14', 'xcrun', 'xcodebuild', 'sysctl']:
                    path = tools / name
                    path.write_text(fake)
                    path.chmod(0o755)
                env = dict(os.environ, PATH=str(tools) + os.pathsep + os.environ['PATH'],
                           CI_XCODE_CLOUD='TRUE', CI_PRIMARY_REPOSITORY_PATH=str(checkout),
                           CI_DERIVED_DATA_PATH=str(temporary / 'Derived Data'), CI_WORKFLOW=workflow,
                           CI_XCODE_SCHEME=scheme, CI_BUILD_NUMBER='71',
                           TEST_BIN_PARENT=str(temporary), TEST_CALLS=str(temporary / 'calls'), TEST_CARGO=str(temporary / 'cargo'))
                for key in ['STRUIS_NATIVE_PLATFORM', 'STRUIS_COMPOUND_DASH_PREPARATION', 'STRUIS_THREADED_PYTHON_ASSETS_DIR']:
                    env.pop(key, None)
                result = subprocess.run(['sh', str(checkout / 'ci_scripts/ci_post_clone.sh')], cwd=checkout, env=env,
                                        capture_output=True, text=True)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertIn(f'NativeRuntime/Scripts/bootstrap.py --platform {expected}', (temporary / 'calls').read_text())
                self.assertEqual(set((temporary / 'cargo').read_text().splitlines()), {str(temporary / 'Derived Data/StruisNative/cargo')})
                self.assertIn('STRUIS_POST_CLONE elapsed_seconds=', result.stdout)
                self.assertIn('exit_code=0', result.stdout)


if __name__ == '__main__':
    unittest.main()
