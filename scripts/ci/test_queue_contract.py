"""What the merge queue relies on in ios.yml and agent.yml, checked on the files of the PR being tested.

The queue verifies a PR that changes ios.yml with the PR's own definition first (workflow_dispatch), but that
run cannot show the parts only the queue's path uses: a PR that drops them would pass and leave every later
verification, its own repair included, unable to start or to report. The merge queue runs these tests with
the PR's definition too (agent-tests.yml, scripts/ci/merge_queue.py SELF_TESTS).

    python3 -m unittest discover -s scripts/ci -p 'test_*.py' -v
"""
from __future__ import annotations

import pathlib
import re
import unittest

ROOT: pathlib.Path = pathlib.Path(__file__).resolve().parents[2]
IOS: str = (ROOT / ".github/workflows/ios.yml").read_text()
AGENT: str = (ROOT / ".github/workflows/agent.yml").read_text()


def job(text: str, name: str) -> str:
    """The text of one top-level job (two-space indented key) of a workflow."""
    match = re.search(rf"^  {re.escape(name)}:\n(.*?)(?=^  [A-Za-z0-9_-]+:\n|\Z)", text, re.S | re.M)
    if not match:
        raise AssertionError(f"job `{name}` is missing")
    return match[1]


class IosWorkflowContractTests(unittest.TestCase):
    def test_the_queue_can_start_a_verification(self) -> None:
        # scripts/ci/merge_queue.py: POST /dispatches {"event_type": "verify", "client_payload": {pr, sha}}
        self.assertRegex(IOS, r"(?m)^  repository_dispatch:\n    types: \[verify\]")

    def test_the_queue_can_start_the_prs_own_definition(self) -> None:
        # merge_queue.py self_test: workflow_dispatch with {"ui_tier": "pr"}
        self.assertRegex(IOS, r"(?m)^  workflow_dispatch:\n    inputs:\n      ui_tier:")
        self.assertRegex(IOS, r"options: \[[^\]]*\bpr\b")

    def test_the_run_name_carries_the_pr_and_the_commit(self) -> None:
        # scripts/agent/verify_report.py parses "Verify PR #<n> <40-hex sha>" from the run's title.
        self.assertIn("format('Verify PR #{0} {1}", IOS)
        self.assertIn("github.event.client_payload.pr, github.event.client_payload.sha", IOS)

    def test_pending_and_report_run_for_the_queues_verification(self) -> None:
        pending: str = job(IOS, "pending")
        self.assertIn("if: github.event_name == 'repository_dispatch'", pending)
        self.assertIn("context='Struis / verify'", pending)
        report: str = job(IOS, "report")
        self.assertIn("if: always() && github.event_name == 'repository_dispatch'", report)
        self.assertIn("uses: ./.github/workflows/agent.yml", report)
        self.assertIn("verify_conclusion:", report)
        self.assertIn("statuses: write", report)


class AgentWorkflowContractTests(unittest.TestCase):
    def test_the_report_writes_the_status(self) -> None:
        self.assertRegex(AGENT, r"(?m)^  workflow_call:\n    inputs:")
        self.assertIn("verify_conclusion:", AGENT)
        self.assertIn("python3 scripts/agent/verify_report.py", AGENT)


if __name__ == "__main__":
    unittest.main()
