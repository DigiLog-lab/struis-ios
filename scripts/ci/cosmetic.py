"""Whether a change may take the light path of the merge queue (Issue #81): build the Release archive only.

A PR carries the label `見た目だけ` when its Issue declared the change to be about the look only, and the
owner merges it after reading its screenshots and code. The label alone is not enough: the change must
also stay inside the files that only draw the screen. Anything else in the diff (processing, data,
tests, CI, the project file) or a screen whose look and behaviour are hard to tell apart (the
conversation's scrolling and freezing, onboarding, billing) sends the PR through the full verification.

Reads the changed paths (one per line) on stdin. Exit 0: light path. Exit 1: full verification, with the
first path that decided it on stderr.
"""
from fnmatch import fnmatchcase
import sys

LABEL = '見た目だけ'

# The screen-drawing files. Matched on the whole path.
ALLOWED = (
    'strius/Design/*.swift',
    'strius/Assets.xcassets/*',
    'strius/Features/*View.swift',
    'strius/Features/*Views.swift',
    'strius/Features/*Parts.swift',
    'strius/Features/*Components.swift',
    'docs/*',
    'README.md',
)

# Screens that always get the full verification, even for a look-only change (Issue #81).
FULL = (
    'strius/Features/Chat/*',
    'strius/Features/Onboarding/*',
    'strius/Features/Settings/UsageViews.swift',
)


def blocking_path(paths):
    """The first path that needs the full verification, or None when every path may take the light path."""
    paths = [path.strip() for path in paths if path.strip()]
    if not paths:
        return '(差分なし)'
    for path in paths:
        if any(fnmatchcase(path, pattern) for pattern in FULL):
            return path
        if not any(fnmatchcase(path, pattern) for pattern in ALLOWED):
            return path
    return None


def main():
    blocking = blocking_path(sys.stdin.read().splitlines())
    if blocking:
        print(f'通常の検証に回します: {blocking}', file=sys.stderr)
        sys.exit(1)


if __name__ == '__main__':
    main()
