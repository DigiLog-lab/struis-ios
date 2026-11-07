#!/usr/bin/env python3
"""Split a PR's selected UI tests across two runners when they would take long (ios.yml `verify` and
`verify-shard`). `verify` also runs every unit test (about 5.5 minutes) before its UI tests, so it starts
that much behind: the split balances the finish times, not the test counts.

    ui_shards.py SELECTION.json PLAN.json   # prints {"ui": "...", "ui2": "...", "minutes": [a, b]}
`ui` and `ui2` are xcodebuild arguments (-only-testing:striusUITests/<test> ...); `ui2` is empty when one
runner is enough (estimated UI test time up to THRESHOLD_MINUTES, or a single test).
"""
from __future__ import annotations

import json
import sys

DEFAULT_SECONDS: float = 60.0           # as scripts/ci/ui_test_plan.py, for a test without a measured duration
UNIT_MINUTES: float = 5.5               # every unit test, on `verify` before its UI tests (2026-11-07)
THRESHOLD_MINUTES: float = 12.0         # one runner up to this much UI test time


def split(tests: list[str], durations: dict[str, float]) -> tuple[list[str], list[str]]:
    seconds = {test: float(durations.get(test, DEFAULT_SECONDS)) for test in tests}
    if len(tests) < 2 or sum(seconds.values()) / 60 <= THRESHOLD_MINUTES:
        return sorted(tests), []
    loads: list[float] = [UNIT_MINUTES * 60, 0.0]
    shards: list[list[str]] = [[], []]
    for test in sorted(tests, key=lambda name: (-seconds[name], name)):
        target = 0 if loads[0] <= loads[1] else 1
        shards[target].append(test)
        loads[target] += seconds[test]
    if not shards[1] or not shards[0]:
        return sorted(tests), []
    return sorted(shards[0]), sorted(shards[1])


def arguments(tests: list[str]) -> str:
    return " ".join(f"-only-testing:striusUITests/{test}" for test in tests)


def main(argv: list[str]) -> int:
    if len(argv) != 2:
        print(__doc__, file=sys.stderr)
        return 2
    with open(argv[0]) as handle:
        tests: list[str] = list(json.load(handle)["uiTests"])
    with open(argv[1]) as handle:
        durations: dict[str, float] = dict(json.load(handle).get("durations", {}))
    first, second = split(tests, durations)
    minutes = [round(sum(float(durations.get(t, DEFAULT_SECONDS)) for t in part) / 60, 1) for part in (first, second)]
    print(json.dumps({"ui": arguments(first), "ui2": arguments(second), "minutes": minutes}))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
