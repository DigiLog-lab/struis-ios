"""The merge queue against a fake GitHub.

    python3 -m unittest discover -s scripts/ci -p 'test_*.py' -v
"""
from __future__ import annotations

import copy
import datetime
import io
import pathlib
import sys
import unittest
import urllib.error
from typing import Any

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
import app_free  # noqa: E402
import merge_queue as mq  # noqa: E402

NOW: datetime.datetime = datetime.datetime(2026, 11, 7, 12, 0, tzinfo=datetime.timezone.utc)
MAIN: str = "m" * 40


def stamp(minutes_ago: int) -> str:
    return (NOW - datetime.timedelta(minutes=minutes_ago)).isoformat().replace("+00:00", "Z")


class FakeGitHub:
    repository: str = "o/r"

    def __init__(self) -> None:
        self.main: str = MAIN
        self.prs: dict[int, dict[str, Any]] = {}
        self.statuses: dict[str, dict[str, Any]] = {}
        self.behind: dict[str, int] = {}
        self.files: dict[int, list[str]] = {}
        self.enabled: dict[int, int] = {}       # minutes ago auto-merge was enabled
        self.pushed: dict[str, int] = {}        # minutes ago a head was committed
        self.blocked_by: dict[int, list[dict[str, Any]]] = {}
        self.runs: dict[tuple[str, str], list[dict[str, Any]]] = {}
        self.conflicts: set[int] = set()
        self.renames: dict[int, list[tuple[str, str]]] = {}
        self.reject_dispatch: set[str] = set()
        self.sent: list[tuple[str, str, dict[str, Any] | None]] = []

    def add(self, number: int, sha: str, *, auto_merge: bool = True, enabled: int = 30, pushed: int = 60,
            behind: int = 0, status: tuple[str, str, int] | None = None, files: list[str] | None = None,
            body: str = "", draft: bool = False) -> None:
        self.prs[number] = {"number": number, "draft": draft, "body": body,
                            "auto_merge": {"enabled_by": {"login": "owner"}} if auto_merge else None,
                            "head": {"sha": sha, "ref": f"branch-{number}", "repo": {"full_name": "o/r"}}}
        self.enabled[number] = enabled
        self.pushed[sha] = pushed
        self.behind[sha] = behind
        self.files[number] = files if files is not None else ["strius/View.swift"]
        if status:
            state, description, minutes = status
            self.statuses[sha] = {"context": mq.CONTEXT, "state": state, "description": description,
                                  "updated_at": stamp(minutes)}

    def get(self, path: str) -> Any:
        path = path.removeprefix("/repos/o/r")
        if path == "/branches/main":
            return {"commit": {"sha": self.main}}
        if path.startswith("/commits/") and path.endswith("/status"):
            sha = path.split("/")[2]
            return {"statuses": [self.statuses[sha]] if sha in self.statuses else []}
        if path.startswith("/commits/"):
            return {"commit": {"committer": {"date": stamp(self.pushed.get(path.split("/")[2], 0))}}}
        if path.startswith("/compare/"):
            return {"behind_by": self.behind[path.split("...")[1]]}
        if path.startswith("/issues/") and path.endswith("/dependencies/blocked_by"):
            return self.blocked_by.get(int(path.split("/")[2]), [])
        if path.startswith("/pulls/"):
            return copy.deepcopy(self.prs[int(path.split("/")[2])])
        if path.startswith("/actions/workflows/"):
            workflow = path.split("/")[3]
            sha = path.split("head_sha=")[1]
            return {"workflow_runs": self.runs.get((workflow, sha), [])}
        raise AssertionError(f"unexpected GET {path}")

    def paginate(self, path: str) -> list[Any]:
        path = path.removeprefix("/repos/o/r")
        if path.startswith("/pulls?"):
            return copy.deepcopy(list(self.prs.values()))
        if path.endswith("/files"):
            number = int(path.split("/")[2])
            return ([{"filename": name} for name in self.files[number]] +
                    [{"filename": new, "previous_filename": old} for old, new in self.renames.get(number, [])])
        if path.endswith("/comments"):
            number = int(path.split("/")[2])
            return [{"body": body} for n, body in self.comments() if n == number]
        if path.endswith("/timeline"):
            number = int(path.split("/")[2])
            return [{"event": "auto_merge_enabled", "created_at": stamp(self.enabled[number])}]
        raise AssertionError(f"unexpected paginate {path}")

    def send(self, method: str, path: str, body: dict[str, Any] | None = None) -> Any:
        path = path.removeprefix("/repos/o/r")
        self.sent.append((method, path, body))
        if method == "POST" and path.startswith("/statuses/"):
            assert body is not None
            self.statuses[path.split("/")[2]] = dict(body, updated_at=stamp(0))
        if method == "POST" and path.startswith("/actions/workflows/") and path.split("/")[3] in self.reject_dispatch:
            raise urllib.error.HTTPError(path, 422, "no workflow_dispatch", {}, io.BytesIO(b""))  # type: ignore[arg-type]
        if method == "PUT" and path.endswith("/update-branch"):
            number = int(path.split("/")[2])
            if number in self.conflicts:
                raise urllib.error.HTTPError(path, 422, "merge conflict", {}, io.BytesIO(b""))  # type: ignore[arg-type]
            new = "u" * 40
            self.prs[number]["head"]["sha"] = new
            self.behind[new] = 0
            self.pushed[new] = 0
        return None

    # what was sent
    def dispatched(self) -> list[dict[str, Any]]:
        return [body for method, path, body in self.sent if path == "/dispatches" and body]

    def workflow_dispatched(self) -> list[tuple[str, dict[str, Any]]]:
        return [(path.split("/")[3], body) for method, path, body in self.sent
                if path.startswith("/actions/workflows/") and body]

    def comments(self) -> list[tuple[int, str]]:
        return [(int(path.split("/")[2]), str(body["body"])) for method, path, body in self.sent
                if path.endswith("/comments") and body]


def run(gh: FakeGitHub) -> list[str]:
    return mq.Queue(gh, lambda: NOW, wait=0).run()


class QueueTests(unittest.TestCase):
    def test_the_first_pr_up_to_date_is_verified(self) -> None:
        gh = FakeGitHub()
        gh.add(1, "a" * 40)
        run(gh)
        self.assertEqual(gh.dispatched(), [{"event_type": "verify", "client_payload": {"pr": 1, "sha": "a" * 40}}])
        self.assertEqual(gh.statuses["a" * 40]["description"], mq.VERIFYING)

    def test_only_one_pr_is_verified_at_a_time_in_order_of_enable_or_push(self) -> None:
        gh = FakeGitHub()
        gh.add(1, "a" * 40, enabled=10, pushed=60)   # key: 10 min ago
        gh.add(2, "b" * 40, enabled=20, pushed=90)   # key: 20 min ago (first)
        run(gh)
        self.assertEqual([d["client_payload"]["pr"] for d in gh.dispatched()], [2])

    def test_a_pr_behind_main_takes_main_and_its_new_head_is_verified(self) -> None:
        gh = FakeGitHub()
        gh.add(1, "a" * 40, behind=3)
        run(gh)
        self.assertIn(("PUT", "/pulls/1/update-branch", {"expected_head_sha": "a" * 40}), gh.sent)
        self.assertEqual(gh.dispatched()[0]["client_payload"]["sha"], "u" * 40)

    def test_a_conflict_drops_the_pr_and_the_next_one_goes(self) -> None:
        gh = FakeGitHub()
        gh.add(1, "a" * 40, behind=1, enabled=50)
        gh.add(2, "b" * 40, enabled=10)
        gh.conflicts.add(1)
        run(gh)
        self.assertEqual(gh.statuses["a" * 40]["state"], "failure")
        self.assertEqual([number for number, _ in gh.comments()], [1])
        self.assertEqual([d["client_payload"]["pr"] for d in gh.dispatched()], [2])

    def test_a_pr_being_verified_holds_the_queue(self) -> None:
        gh = FakeGitHub()
        gh.add(1, "a" * 40, status=("pending", "ios.yml: 検証中", 5), enabled=50)
        gh.add(2, "b" * 40, enabled=10)
        run(gh)
        self.assertEqual(gh.dispatched(), [])

    def test_a_green_pr_waits_for_auto_merge_then_is_dropped_after_ten_minutes(self) -> None:
        gh = FakeGitHub()
        gh.add(1, "a" * 40, status=("success", "ios.yml: ok", 3))
        run(gh)
        self.assertEqual(gh.sent, [])
        gh = FakeGitHub()
        gh.add(1, "a" * 40, status=("success", "ios.yml: ok", 11), enabled=50)
        gh.add(2, "b" * 40, enabled=10)
        run(gh)
        self.assertEqual(gh.statuses["a" * 40]["state"], "failure")
        self.assertEqual([d["client_payload"]["pr"] for d in gh.dispatched()], [2])

    def test_a_verification_that_never_ends_is_dropped(self) -> None:
        gh = FakeGitHub()
        gh.add(1, "a" * 40, status=("pending", mq.VERIFYING, 121))
        run(gh)
        self.assertEqual(gh.statuses["a" * 40]["state"], "failure")

    def test_red_prs_wait_outside_the_queue(self) -> None:
        gh = FakeGitHub()
        gh.add(1, "a" * 40, status=("failure", "ios.yml: 単体テスト", 5), enabled=50)
        gh.add(2, "b" * 40, enabled=10)
        run(gh)
        self.assertEqual([d["client_payload"]["pr"] for d in gh.dispatched()], [2])

    def test_a_red_verification_is_said_on_the_pr_once(self) -> None:
        gh = FakeGitHub()
        gh.add(1, "a" * 40, status=("failure", "ios.yml: 単体テスト", 5))
        gh.statuses["a" * 40]["target_url"] = "https://run"
        run(gh)
        run(gh)
        self.assertEqual(len(gh.comments()), 1)
        self.assertIn("単体テスト", gh.comments()[0][1])

    def test_prs_without_auto_merge_or_in_draft_are_not_queued(self) -> None:
        gh = FakeGitHub()
        gh.add(1, "a" * 40, auto_merge=False)
        gh.add(2, "b" * 40, draft=True)
        run(gh)
        self.assertEqual(gh.dispatched(), [])

    def test_a_pr_whose_issue_is_blocked_by_an_open_issue_is_skipped(self) -> None:
        gh = FakeGitHub()
        gh.add(1, "a" * 40, body="Closes #10", enabled=50)
        gh.add(2, "b" * 40, enabled=10)
        gh.blocked_by[10] = [{"number": 9, "state": "open"}]
        run(gh)
        self.assertEqual([d["client_payload"]["pr"] for d in gh.dispatched()], [2])
        gh2 = FakeGitHub()
        gh2.add(1, "a" * 40, body="Fixes #10")
        gh2.blocked_by[10] = [{"number": 9, "state": "closed"}]
        run(gh2)
        self.assertEqual([d["client_payload"]["pr"] for d in gh2.dispatched()], [1])

    def test_greens_on_an_older_main_are_set_back_to_pending(self) -> None:
        gh = FakeGitHub()
        gh.add(1, "a" * 40, auto_merge=False, behind=2, status=("success", "ios.yml: ok", 30))
        run(gh)
        self.assertEqual(gh.statuses["a" * 40]["state"], "pending")
        self.assertEqual(gh.statuses["a" * 40]["description"], mq.STALE)

    def test_a_stale_head_in_the_queue_is_updated_and_verified(self) -> None:
        gh = FakeGitHub()
        gh.add(1, "a" * 40, behind=1, status=("success", "ios.yml: ok", 30))
        run(gh)
        self.assertEqual(gh.dispatched()[0]["client_payload"]["sha"], "u" * 40)


class OccupantTests(unittest.TestCase):
    def test_the_pr_being_verified_after_its_update_stays_first(self) -> None:
        gh = FakeGitHub()
        gh.add(1, "a" * 40, behind=1, enabled=50)
        gh.add(2, "b" * 40, enabled=10)
        run(gh)      # #1 takes main (a new commit, committed now) and is verified
        run(gh)      # #1 is now the latest by commit time; it must still hold the queue
        self.assertEqual([d["client_payload"]["pr"] for d in gh.dispatched()], [1])


    def test_a_pr_whose_auto_merge_is_disabled_mid_verification_is_called_off_first(self) -> None:
        gh = FakeGitHub()
        gh.add(1, "a" * 40, enabled=50)
        gh.add(2, "b" * 40, enabled=10)
        run(gh)                                   # #1 is being verified
        gh.prs[1]["auto_merge"] = None            # the owner disables auto-merge
        run(gh)                                   # #2 goes, but only after #1's verification is void
        self.assertEqual(gh.statuses["a" * 40]["state"], "failure")
        self.assertTrue(gh.statuses["a" * 40]["description"].startswith(mq.PREFIX))
        self.assertEqual([d["client_payload"]["pr"] for d in gh.dispatched()], [1, 2])

    def test_a_conflict_on_an_agent_pr_is_said_on_its_issue_too(self) -> None:
        gh = FakeGitHub()
        gh.add(1, "a" * 40, behind=1, body="x <!-- struis-agent:issue=40 -->")
        gh.conflicts.add(1)
        run(gh)
        self.assertEqual(sorted(number for number, _ in gh.comments()), [1, 40])


class SelfTestTests(unittest.TestCase):
    def test_a_renamed_workflow_is_self_tested_by_where_it_came_from(self) -> None:
        gh = FakeGitHub()
        gh.add(1, "a" * 40, files=[])
        gh.renames[1] = [(".github/workflows/ios.yml", "docs/old-ios.yml")]
        run(gh)
        self.assertEqual([workflow for workflow, _ in gh.workflow_dispatched()], ["ios.yml"])

    def test_a_self_test_that_cannot_be_started_drops_the_pr_and_the_next_goes(self) -> None:
        gh = FakeGitHub()
        gh.add(1, "a" * 40, files=[".github/workflows/ios.yml"], enabled=50)
        gh.add(2, "b" * 40, enabled=10)
        gh.reject_dispatch.add("ios.yml")
        run(gh)
        self.assertEqual(gh.statuses["a" * 40]["state"], "failure")
        self.assertEqual([d["client_payload"]["pr"] for d in gh.dispatched()], [2])

    def test_a_workflow_change_runs_the_prs_own_definition_first(self) -> None:
        gh = FakeGitHub()
        gh.add(1, "a" * 40, files=[".github/workflows/ios.yml"])
        run(gh)
        self.assertEqual(gh.workflow_dispatched(), [("ios.yml", {"ref": "branch-1", "inputs": {"ui_tier": "pr"}})])
        self.assertEqual(gh.dispatched(), [])
        self.assertEqual(gh.statuses["a" * 40]["description"], mq.SELF_TEST)

    def test_after_the_self_test_is_green_mains_verification_runs(self) -> None:
        gh = FakeGitHub()
        gh.add(1, "a" * 40, files=[".github/workflows/ios.yml"], status=("pending", mq.SELF_TEST, 20))
        gh.runs[("ios.yml", "a" * 40)] = [{"status": "completed", "conclusion": "success", "created_at": stamp(20)}]
        run(gh)
        self.assertEqual(gh.workflow_dispatched(), [])
        self.assertEqual([d["client_payload"]["pr"] for d in gh.dispatched()], [1])

    def test_a_running_self_test_holds_and_a_red_one_drops(self) -> None:
        gh = FakeGitHub()
        gh.add(1, "a" * 40, files=[".github/workflows/ios.yml"], status=("pending", mq.SELF_TEST, 5))
        gh.runs[("ios.yml", "a" * 40)] = [{"status": "in_progress", "created_at": stamp(5)}]
        run(gh)
        self.assertEqual((gh.dispatched(), gh.workflow_dispatched()), ([], []))
        gh.runs[("ios.yml", "a" * 40)] = [{"status": "completed", "conclusion": "failure", "created_at": stamp(5),
                                          "html_url": "https://x"}]
        run(gh)
        self.assertEqual(gh.statuses["a" * 40]["state"], "failure")

    def test_a_queue_or_script_change_runs_the_prs_linux_tests(self) -> None:
        gh = FakeGitHub()
        gh.add(1, "a" * 40, files=["scripts/ci/merge_queue.py"])
        run(gh)
        self.assertEqual([workflow for workflow, _ in gh.workflow_dispatched()], ["agent-tests.yml"])

    def test_an_app_change_needs_no_self_test(self) -> None:
        gh = FakeGitHub()
        gh.add(1, "a" * 40, files=["strius/View.swift", "docs/x.md"])
        run(gh)
        self.assertEqual(gh.workflow_dispatched(), [])
        self.assertEqual(len(gh.dispatched()), 1)


class SharedWordingTests(unittest.TestCase):
    def test_the_report_recognises_what_the_queue_writes(self) -> None:
        # scripts/agent/verify_report.py does not overwrite the queue's red or its "main moved" pending.
        sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1] / "agent"))
        import verify_report  # noqa: E402
        self.assertEqual(verify_report.QUEUE_PREFIX, mq.PREFIX)
        self.assertEqual(verify_report.QUEUE_STALE, mq.STALE)
        self.assertEqual(verify_report.CONTEXT, mq.CONTEXT)


class AppFreeTests(unittest.TestCase):
    def test_scripts_docs_and_workflows_leave_the_app_alone(self) -> None:
        self.assertTrue(app_free.app_free(["docs/a.md", "scripts/ci/x.py", ".github/workflows/ios.yml", "README.md"]))

    def test_anything_xcode_reads_does_not(self) -> None:
        for path in ("strius/View.swift", "striusTests/T.swift", "NativeRuntime/x", "strius.xcodeproj/project.pbxproj",
                     "scripts/package_compound_dash_preparation.py", "Info.plist", "Config/a.xcconfig"):
            self.assertFalse(app_free.app_free(["docs/a.md", path]), path)

    def test_an_empty_change_is_not_app_free(self) -> None:
        self.assertFalse(app_free.app_free([]))


if __name__ == "__main__":
    unittest.main()
