#!/usr/bin/env python3
"""The merge queue (docs/development-method.md, "7. マージキュー"): the only gate before main.

Runs on Linux in merge-queue.yml, with main's definition, every time something may have changed: a PR's
auto-merge was enabled or disabled, a PR was pushed or closed, main moved, or a verification finished.
It keeps no state of its own (no file, no label): each run reads GitHub and takes the next step.

- The queue is every open PR into main from this repository with GitHub's auto-merge enabled (the owner
  pressing "Enable auto-merge" is the permission to merge). A PR whose head is red, or whose Issue is
  Blocked by an open Issue, waits outside it. Order: the later of "auto-merge enabled" and "last push",
  earliest first, so a red PR fixed by a push goes to the end.
- The first PR is brought up to date with main (GitHub's Update branch) and verified on it: ios.yml's
  `verify` (main's definition) writes `Struis / verify`. A PR that changes a verification workflow is first
  verified with its own definition (workflow_dispatch on its branch), so a change that breaks the
  verification cannot reach main and leave every later PR, its own fix included, red.
- When `Struis / verify` is green, GitHub's auto-merge merges it in the owner's name; main moves and the
  next run takes the next PR. Every green on a head that no longer contains main is set back to pending:
  the ruleset does not require "up to date", so an old green could otherwise be merged.

    python3 scripts/ci/merge_queue.py          # GITHUB_TOKEN, GITHUB_REPOSITORY
"""
from __future__ import annotations

import dataclasses
import datetime
import json
import os
import re
import sys
import time
import urllib.error
import urllib.request
from typing import Any, Callable, Protocol

# scripts/agent/verify_report.py reads PREFIX and STALE: a late result does not overwrite them.
CONTEXT: str = "Struis / verify"
PREFIX: str = "マージキュー: "
STALE: str = PREFIX + "main が進んだので、キューで検証し直します"
SELF_TEST: str = PREFIX + "PR の定義で検証中"
VERIFYING: str = PREFIX + "最新の main の上で検証中"
# A verification that takes longer than this is treated as lost (a runner that never came, a cancelled run).
VERIFY_LIMIT: datetime.timedelta = datetime.timedelta(hours=2)
# Green, auto-merge on, and still not merged after this: something else blocks the merge.
MERGE_LIMIT: datetime.timedelta = datetime.timedelta(minutes=10)
COMMENT_MARKER: str = "<!-- struis-merge-queue -->"

# Changes to these are verified with the PR's own definition of the workflow before main's.
SELF_TESTS: dict[str, tuple[str, ...]] = {
    "ios.yml": (
        ".github/workflows/ios.yml", ".github/workflows/agent.yml", ".github/workflows/agent-native-cache.yml",
        "scripts/agent/verify_report.py", "scripts/ci/ui_test_plan.py", "scripts/ci/ui-test-plan.json",
        "scripts/ci/cosmetic.py", "scripts/ci/app_free.py",
    ),
    "agent-tests.yml": (
        ".github/workflows/merge-queue.yml", ".github/workflows/agent-tests.yml", ".github/actionlint.yaml",
        "scripts/", "cloudflare/",
    ),
}
AGENT_ISSUE: re.Pattern[str] = re.compile(r"<!-- struis-agent:issue=([1-9]\d*) -->")
CLOSING: re.Pattern[str] = re.compile(r"\b(?:close[sd]?|fix(?:e[sd])?|resolve[sd]?)\s+#([1-9]\d*)", re.IGNORECASE)


class GitHubLike(Protocol):
    repository: str

    def get(self, path: str) -> Any: ...
    def paginate(self, path: str) -> list[Any]: ...
    def send(self, method: str, path: str, body: dict[str, Any] | None = None) -> Any: ...


class GitHub:
    def __init__(self, token: str, repository: str) -> None:
        self.token: str = token
        self.repository: str = repository

    def _request(self, method: str, url: str, body: dict[str, Any] | None) -> tuple[Any, dict[str, str]]:
        data: bytes | None = json.dumps(body).encode() if body is not None else None
        request = urllib.request.Request(url, data=data, method=method, headers={
            "Authorization": f"Bearer {self.token}", "Accept": "application/vnd.github+json",
            "X-GitHub-Api-Version": "2022-11-28", "User-Agent": "struis-merge-queue",
        })
        with urllib.request.urlopen(request, timeout=30) as response:
            text: str = response.read().decode()
            return (json.loads(text) if text else None), dict(response.headers)

    def get(self, path: str) -> Any:
        return self._request("GET", "https://api.github.com" + path, None)[0]

    def paginate(self, path: str) -> list[Any]:
        items: list[Any] = []
        url: str | None = "https://api.github.com" + path + ("&" if "?" in path else "?") + "per_page=100"
        while url:
            page, headers = self._request("GET", url, None)
            items.extend(page)
            match = re.search(r'<([^>]+)>;\s*rel="next"', headers.get("Link", ""))
            url = match[1] if match else None
        return items

    def send(self, method: str, path: str, body: dict[str, Any] | None = None) -> Any:
        return self._request(method, "https://api.github.com" + path, body)[0]


def parse_time(text: str) -> datetime.datetime:
    return datetime.datetime.fromisoformat(text.replace("Z", "+00:00"))


@dataclasses.dataclass
class Entry:
    pr: dict[str, Any]
    status: dict[str, Any] | None
    key: datetime.datetime

    @property
    def number(self) -> int:
        return int(self.pr["number"])

    @property
    def sha(self) -> str:
        return str(self.pr["head"]["sha"])


class Queue:
    def __init__(self, gh: GitHubLike, now: Callable[[], datetime.datetime], wait: float = 2.0) -> None:
        self.gh: GitHubLike = gh
        self.now: Callable[[], datetime.datetime] = now
        self.wait: float = wait
        self.log: list[str] = []
        self.repo: str = f"/repos/{gh.repository}"

    # --- reading -------------------------------------------------------------------------------------
    def status(self, sha: str) -> dict[str, Any] | None:
        for status in self.gh.get(f"{self.repo}/commits/{sha}/status").get("statuses", []):
            if status.get("context") == CONTEXT:
                return dict(status)
        return None

    def contains(self, main_sha: str, sha: str) -> bool:
        return int(self.gh.get(f"{self.repo}/compare/{main_sha}...{sha}")["behind_by"]) == 0

    def changed_files(self, number: int) -> list[str]:
        """Every path the PR touches: for a rename, where it came from as well as where it went."""
        names: list[str] = []
        for item in self.gh.paginate(f"{self.repo}/pulls/{number}/files"):
            names.append(str(item["filename"]))
            if item.get("previous_filename"):
                names.append(str(item["previous_filename"]))
        return names

    def blocked(self, pr: dict[str, Any]) -> list[int]:
        """Open Issues that block this PR or the Issues it closes."""
        numbers: set[int] = {int(pr["number"]), *(int(n) for n in CLOSING.findall(pr.get("body") or ""))}
        open_blockers: list[int] = []
        for number in sorted(numbers):
            try:
                blockers: list[Any] = self.gh.get(f"{self.repo}/issues/{number}/dependencies/blocked_by")
            except urllib.error.HTTPError as error:
                if error.code == 404:
                    continue
                raise
            open_blockers += [int(b["number"]) for b in blockers if b.get("state") == "open"]
        return sorted(set(open_blockers))

    def order_key(self, pr: dict[str, Any]) -> datetime.datetime:
        enabled: list[datetime.datetime] = [
            parse_time(event["created_at"])
            for event in self.gh.paginate(f"{self.repo}/issues/{pr['number']}/timeline")
            if event.get("event") == "auto_merge_enabled" and event.get("created_at")
        ]
        pushed: datetime.datetime = parse_time(
            self.gh.get(f"{self.repo}/commits/{pr['head']['sha']}")["commit"]["committer"]["date"])
        return max([pushed, *enabled])

    def self_test_runs(self, workflow: str, sha: str) -> list[dict[str, Any]]:
        runs: dict[str, Any] = self.gh.get(
            f"{self.repo}/actions/workflows/{workflow}/runs?event=workflow_dispatch&head_sha={sha}")
        return list(runs.get("workflow_runs", []))

    # --- writing -------------------------------------------------------------------------------------
    def set_status(self, sha: str, state: str, description: str, url: str | None = None) -> None:
        body: dict[str, Any] = {"state": state, "context": CONTEXT, "description": description[:140]}
        if url:
            body["target_url"] = url
        self.gh.send("POST", f"{self.repo}/statuses/{sha}", body)

    def comment(self, number: int, text: str) -> None:
        self.gh.send("POST", f"{self.repo}/issues/{number}/comments", {"body": f"{COMMENT_MARKER}\n{text}"})

    def drop(self, entry: Entry, reason: str) -> None:
        """Out of the queue until the next push: red on its head, and the reason on the PR (and on the agent's
        Issue for an agent PR: the queue cannot write the agent's state, so the reason is left where it reads)."""
        self.set_status(entry.sha, "failure", PREFIX + reason)
        text: str = (f"マージキューから外しました: {reason}\n\n"
                     "直して push すると、キューの最後に並び直します(自動マージは有効のままです)。")
        self.comment(entry.number, text)
        agent_issue = AGENT_ISSUE.search(entry.pr.get("body") or "")
        if agent_issue:
            self.comment(int(agent_issue[1]), f"PR #{entry.number} を{text}")
        self.log.append(f"#{entry.number}: dropped ({reason})")

    def call_off(self, pr: dict[str, Any], reason: str) -> None:
        """A PR that leaves the queue while it is being verified: its verification's result is made void (red
        with the queue's reason, which verify_report.py does not overwrite) before the next PR is verified, so
        enabling auto-merge again cannot merge it beside the next verification on an older main."""
        status = self.status(pr["head"]["sha"])
        if status and status.get("state") == "pending" and status.get("description") != STALE:
            self.set_status(pr["head"]["sha"], "failure", PREFIX + reason)
            self.log.append(f"#{pr['number']}: verification called off ({reason})")

    def tell_red(self, pr: dict[str, Any], status: dict[str, Any]) -> None:
        """A red verification (ios.yml) is said on the PR once per head. The queue's own reds say it already."""
        if str(status.get("description") or "").startswith(PREFIX):
            return
        sha: str = str(pr["head"]["sha"])
        tag: str = f"<!-- struis-merge-queue-red={sha} -->"
        if any(tag in str(c.get("body") or "") for c in self.gh.paginate(f"{self.repo}/issues/{pr['number']}/comments")):
            return
        link: str = f"\n\n{status['target_url']}" if status.get("target_url") else ""
        self.comment(int(pr["number"]), f"{tag}\nマージキューの検証が赤でした(`{sha[:12]}`): {status.get('description')}{link}\n\n"
                                        "直して push すると、キューの最後に並び直します(自動マージは有効のままです)。")

    # --- the steps -----------------------------------------------------------------------------------
    def invalidate_old_greens(self, prs: list[dict[str, Any]], main_sha: str) -> None:
        for pr in prs:
            status = self.status(pr["head"]["sha"])
            if status and status.get("state") == "success" and not self.contains(main_sha, pr["head"]["sha"]):
                self.set_status(pr["head"]["sha"], "pending", STALE)
                self.log.append(f"#{pr['number']}: green on an older main, set back to pending")

    def entries(self, prs: list[dict[str, Any]]) -> list[Entry]:
        entries: list[Entry] = []
        for pr in prs:
            if not pr.get("auto_merge") or pr.get("draft"):
                self.call_off(pr, "自動マージが外されたか Draft に戻されたので、キューの検証を取りやめました。")
                continue
            status = self.status(pr["head"]["sha"])
            if status and status.get("state") in ("failure", "error"):
                self.tell_red(pr, status)
                self.log.append(f"#{pr['number']}: red, waits for a push")
                continue
            blockers = self.blocked(pr)
            if blockers:
                self.call_off(pr, "閉じていない Issue にブロックされたので、キューの検証を取りやめました。")
                self.log.append(f"#{pr['number']}: blocked by " + ", ".join(f"#{n}" for n in blockers))
                continue
            entries.append(Entry(pr=pr, status=status, key=self.order_key(pr)))
        # The PR the queue is already working on stays first: the Update branch it was given has a new commit
        # time, and sorting it behind the others would start a second verification beside it.
        return sorted(entries, key=lambda entry: (not self.occupies(entry), entry.key, entry.number))

    @staticmethod
    def occupies(entry: Entry) -> bool:
        """Being verified (pending, not set back by a main that moved) or green and waiting for the merge."""
        if not entry.status:
            return False
        state: str = str(entry.status.get("state"))
        return state == "success" or (state == "pending" and entry.status.get("description") != STALE)

    def update(self, entry: Entry) -> str | None:
        """GitHub's Update branch; the new head, or None after dropping the PR."""
        old: str = entry.sha
        try:
            self.gh.send("PUT", f"{self.repo}/pulls/{entry.number}/update-branch", {"expected_head_sha": old})
        except urllib.error.HTTPError as error:
            if error.code == 422:
                self.drop(entry, "最新の main を取り込めません(衝突)。main を取り込んで解消してください。")
                return None
            raise
        for _ in range(30):
            head: str = str(self.gh.get(f"{self.repo}/pulls/{entry.number}")["head"]["sha"])
            if head != old:
                return head
            time.sleep(self.wait)
        raise RuntimeError(f"PR #{entry.number}: the head did not move after Update branch")

    def advance(self, entry: Entry, main_sha: str) -> bool:
        """One step for the first PR. True when it occupies the queue (nothing else to do this run)."""
        status: dict[str, Any] | None = entry.status
        state: str | None = status.get("state") if status else None
        updated_at: datetime.datetime | None = parse_time(status["updated_at"]) if status else None
        up_to_date: bool = self.contains(main_sha, entry.sha)
        if state == "success" and up_to_date:
            assert updated_at is not None
            if self.now() - updated_at > MERGE_LIMIT:
                self.drop(entry, "緑になってから10分たってもマージされませんでした。PR のマージの妨げを確かめてください。")
                return False
            self.log.append(f"#{entry.number}: green, GitHub's auto-merge merges it")
            return True
        description: str = str(status.get("description") or "") if status else ""
        if state == "pending" and up_to_date and description != STALE:
            assert updated_at is not None
            if self.now() - updated_at > VERIFY_LIMIT:
                self.drop(entry, "検証が2時間たっても終わりませんでした。")
                return False
            if description == SELF_TEST:
                return self.self_test(entry)
            self.log.append(f"#{entry.number}: being verified ({description})")
            return True
        sha: str = entry.sha
        if not up_to_date:
            new_head = self.update(entry)
            if new_head is None:
                return False
            self.log.append(f"#{entry.number}: took main, {sha[:12]} -> {new_head[:12]}")
            sha = new_head
            entry.pr["head"]["sha"] = sha
        return self.self_test(entry) if self.self_tests(entry) else self.verify(entry)

    def self_tests(self, entry: Entry) -> list[str]:
        files: list[str] = self.changed_files(entry.number)
        return [workflow for workflow, paths in SELF_TESTS.items()
                if any(name == path or (path.endswith("/") and name.startswith(path)) for name in files for path in paths)]

    def self_test(self, entry: Entry) -> bool:
        """The PR's own definition of each workflow it changes, on its branch; then main's verification."""
        for workflow in self.self_tests(entry):
            runs = self.self_test_runs(workflow, entry.sha)
            if not runs:
                try:
                    self.gh.send("POST", f"{self.repo}/actions/workflows/{workflow}/dispatches",
                                 {"ref": entry.pr["head"]["ref"], "inputs": {"ui_tier": "pr"} if workflow == "ios.yml" else {}})
                except urllib.error.HTTPError as error:
                    if error.code in (404, 422):
                        # The PR's definition cannot be started that way (no workflow_dispatch, other inputs).
                        self.drop(entry, f"PR の定義の {workflow} を workflow_dispatch で起動できませんでした"
                                         f"(HTTP {error.code})。workflow_dispatch と入力 ui_tier を残してください。")
                        return False
                    raise
                self.set_status(entry.sha, "pending", SELF_TEST)
                self.log.append(f"#{entry.number}: {workflow} started with the PR's definition")
                return True
            latest = max(runs, key=lambda run: str(run.get("created_at", "")))
            if latest.get("status") != "completed":
                self.log.append(f"#{entry.number}: {workflow} with the PR's definition is running")
                return True
            if latest.get("conclusion") != "success":
                self.drop(entry, f"PR の定義の {workflow} が {latest.get('conclusion')} でした: {latest.get('html_url')}")
                return False
        return self.verify(entry)

    def verify(self, entry: Entry) -> bool:
        self.gh.send("POST", f"{self.repo}/dispatches",
                     {"event_type": "verify", "client_payload": {"pr": entry.number, "sha": entry.sha}})
        self.set_status(entry.sha, "pending", VERIFYING)
        self.log.append(f"#{entry.number}: verification of {entry.sha[:12]} on the latest main started")
        return True

    def run(self) -> list[str]:
        main_sha: str = str(self.gh.get(f"{self.repo}/branches/main")["commit"]["sha"])
        prs: list[dict[str, Any]] = [
            pr for pr in self.gh.paginate(f"{self.repo}/pulls?state=open&base=main")
            if (pr["head"].get("repo") or {}).get("full_name") == self.gh.repository
        ]
        self.invalidate_old_greens(prs, main_sha)
        for entry in self.entries(prs):
            if self.advance(entry, main_sha):
                break
        else:
            self.log.append("queue: nothing to verify")
        return self.log


def main() -> int:
    gh = GitHub(os.environ["GITHUB_TOKEN"], os.environ["GITHUB_REPOSITORY"])
    log: list[str] = Queue(gh, lambda: datetime.datetime.now(datetime.timezone.utc)).run()
    print("\n".join(log))
    summary: str | None = os.environ.get("GITHUB_STEP_SUMMARY")
    if summary:
        with open(summary, "a") as handle:
            handle.write("### マージキュー\n\n" + "\n".join(f"- {line}" for line in log) + "\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
