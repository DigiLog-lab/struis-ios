#!/usr/bin/env python3
"""Does a change leave the app alone? Changed paths on stdin, one per line; exit 0 when none can change
what Xcode builds or tests, 1 otherwise. ios.yml then verifies the PR on Linux only (tier `none`): its
scripts and workflows were tested by agent-tests.yml, and the merge queue runs a changed verification
workflow with the PR's own definition first (scripts/ci/merge_queue.py).

    git diff --name-only origin/main...HEAD | python3 scripts/ci/app_free.py
"""
from __future__ import annotations

from fnmatch import fnmatchcase
import sys

# Paths Xcode never reads. scripts/package_compound_dash_preparation.py is not here: a build phase runs it.
APP_FREE: tuple[str, ...] = (
    "docs/*",
    "scripts/agent/*",
    "scripts/ci/*",
    "scripts/devbox/*",
    ".github/*",
    "cloudflare/*",
    "README.md",
    "CLAUDE.md",
    ".gitignore",
)


def app_free(paths: list[str]) -> bool:
    return bool(paths) and all(any(fnmatchcase(path, pattern) for pattern in APP_FREE) for path in paths)


def main() -> int:
    paths: list[str] = [line.strip() for line in sys.stdin if line.strip()]
    return 0 if app_free(paths) else 1


if __name__ == "__main__":
    sys.exit(main())
