"""The parts of ui_failures.py that read xcresulttool's JSON, on what it printed for a real failed UI test
(Dev Box, Xcode 27.1, 2026-11-07: a test that launched the app, waited 4 s and called XCTFail).

    python3 -m unittest discover -s scripts/ci -p 'test_*.py' -v
"""
from __future__ import annotations

import json
import pathlib
import sys
import unittest

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
import ui_failures  # noqa: E402

FIXTURES: pathlib.Path = pathlib.Path(__file__).resolve().parent / "fixtures"


def fixture(name: str) -> object:
    return json.loads((FIXTURES / name).read_text())


class XcresultReadingTests(unittest.TestCase):
    def test_only_the_failed_test_is_listed(self) -> None:
        self.assertEqual(ui_failures.failed_tests(fixture("xcresult-tests.json")),
                         ["ZzPreflightUITests/testBFailsAfterLaunch()"])

    def test_the_failure_is_found_in_the_recording(self) -> None:
        found = ui_failures.recording_and_failure(fixture("xcresult-activities.json"))
        assert found is not None
        name, started, failed_at = found
        self.assertTrue(name.endswith(".mp4"))
        # XCTFail came 16.7 s after the recording started (the app's launch and the 4 s wait).
        self.assertAlmostEqual(failed_at - started, 16.725, places=2)

    def test_the_exported_recording_is_matched_by_its_name(self) -> None:
        found = ui_failures.recording_and_failure(fixture("xcresult-activities.json"))
        assert found is not None
        exported = ui_failures.exported_recording(fixture("xcresult-attachments-manifest.json"), found[0])
        self.assertEqual(exported, "A0E9442E-DC2B-46E6-9974-1E6AD792A4AA.mp4")

    def test_file_names_are_plain(self) -> None:
        self.assertEqual(ui_failures.file_name("ZzPreflightUITests/testBFailsAfterLaunch()"),
                         "ZzPreflightUITests-testBFailsAfterLaunch")

    def test_a_test_without_a_recording_gives_nothing(self) -> None:
        self.assertIsNone(ui_failures.recording_and_failure({"testRuns": [{"activities": []}]}))


if __name__ == "__main__":
    unittest.main()
