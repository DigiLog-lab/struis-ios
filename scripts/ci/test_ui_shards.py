"""ui_shards.py: when a PR's UI tests go to a second runner, and how they are split.

    python3 -m unittest discover -s scripts/ci -p 'test_*.py' -v
"""
from __future__ import annotations

import json
import pathlib
import sys
import unittest

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
import ui_shards  # noqa: E402

PLAN: dict[str, float] = json.loads(
    (pathlib.Path(__file__).resolve().parent / "ui-test-plan.json").read_text()).get("durations", {})


class ShardTests(unittest.TestCase):
    def test_a_short_selection_stays_on_one_runner(self) -> None:
        first, second = ui_shards.split(["A/a", "B/b"], {"A/a": 120, "B/b": 200})
        self.assertEqual((first, second), (["A/a", "B/b"], []))

    def test_a_single_long_test_stays_on_one_runner(self) -> None:
        self.assertEqual(ui_shards.split(["A/a"], {"A/a": 3600}), (["A/a"], []))

    def test_a_long_selection_is_split_and_nothing_is_lost(self) -> None:
        tests = [f"T/t{n}" for n in range(10)]
        durations = {test: 120.0 for test in tests}        # 20 minutes
        first, second = ui_shards.split(tests, durations)
        self.assertTrue(first and second)
        self.assertEqual(sorted(first + second), sorted(tests))
        self.assertFalse(set(first) & set(second))

    def test_the_first_runner_gets_less_for_its_unit_tests(self) -> None:
        tests = [f"T/t{n}" for n in range(20)]
        first, second = ui_shards.split(tests, {test: 60.0 for test in tests})
        finish_first = ui_shards.UNIT_MINUTES * 60 + 60 * len(first)
        finish_second = 60 * len(second)
        self.assertLess(len(first), len(second))
        self.assertLessEqual(abs(finish_first - finish_second), 60)

    def test_every_ui_test_of_the_real_plan_splits_across_two(self) -> None:
        tests = sorted(PLAN)
        first, second = ui_shards.split(tests, PLAN)
        self.assertEqual(sorted(first + second), tests)
        self.assertTrue(second)

    def test_arguments_are_xcodebuild_filters(self) -> None:
        self.assertEqual(ui_shards.arguments(["A/a", "B/b"]),
                         "-only-testing:striusUITests/A/a -only-testing:striusUITests/B/b")


if __name__ == "__main__":
    unittest.main()
