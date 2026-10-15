#!/usr/bin/env python3
"""Choose which UI test methods one CI shard runs.

Reads scripts/ci/ui-test-plan.json:
  shards     number of runners the UI tests are split across
  durations  measured seconds per "Class/method" (unknown methods count as DEFAULT_SECONDS)
  pr         optional list of test classes always run for pull requests
  paths      optional {glob: [classes]}; a class is added for a pull request when a changed file matches
Without "pr", pull requests run every UI test (nothing is narrowed until the plan says so).

With --shard N, prints one `-only-testing:striusUITests/Class/method` argument per line.
With --matrix, prints a GitHub Actions matrix: [{"shard", "tests", "count", "minutes"}] for
non-empty shards only. An empty shard must never reach xcodebuild, because xcodebuild
without -only-testing runs every test.
"""
import argparse
import fnmatch
import json
from pathlib import Path
import re
import sys

ROOT = Path(__file__).resolve().parents[2]
TESTS = ROOT / 'striusUITests'
PLAN = Path(__file__).resolve().parent / 'ui-test-plan.json'
DEFAULT_SECONDS = 60
CLASS = re.compile(r'^\s*(?:@\w+\s+)*(?:(?:final|open|public|internal)\s+)*class\s+(\w+)\s*:\s*(\w+)')
EXTENSION = re.compile(r'^\s*extension\s+(\w+)\b')
# Only an unindented declaration ends a test class; nested helper types stay inside it.
OTHER_TYPE = re.compile(r'^(?:@\w+\s+)*(?:(?:final|private|fileprivate|public|internal)\s+)*(?:class|struct|enum|actor|extension)\s+(\w+)')
METHOD = re.compile(r'^\s*(?:@\w+\s+)*(?:override\s+)?func\s+(test\w*)\s*\(\s*\)')
# Any indented `func test…()` line; used to prove discovery missed nothing.
ANY_TEST_FUNC = re.compile(r'^\s+(?:@\w+\s+)*(?:override\s+)?func\s+test\w*\s*\(\s*\)')
TOP_LEVEL_CLOSE = re.compile(r'^}')


def discover(directory=TESTS):
    """Return sorted 'Class/method' names of XCTestCase test methods.

    Every UI test now runs from an explicit -only-testing list, so a test this misses would
    silently never run. It therefore fails when any indented `func test…()` line is not
    attributed to a test class.
    """
    sources = sorted(directory.glob('*.swift'))
    parents = {}
    for source in sources:
        for line in source.read_text().splitlines():
            match = CLASS.match(line)
            if match:
                parents[match[1]] = match[2]
    classes = {'XCTestCase'}
    while True:  # subclasses of test classes are test classes too
        more = {name for name, parent in parents.items() if parent in classes} - classes
        if not more:
            break
        classes |= more
    classes.discard('XCTestCase')
    found = set()
    seen = 0
    for source in sources:
        current = None
        for line in source.read_text().splitlines():
            if ANY_TEST_FUNC.match(line):
                seen += 1
            match = CLASS.match(line) or EXTENSION.match(line)
            if match:
                current = match[1] if match[1] in classes else None
                continue
            if OTHER_TYPE.match(line) or TOP_LEVEL_CLOSE.match(line):
                current = None
                continue
            match = METHOD.match(line)
            if match and current:
                found.add(f'{current}/{match[1]}')
    if seen != len(found):
        raise SystemExit(f'UI test discovery found {len(found)} test methods but {seen} `func test…()` lines '
                         f'in {directory}. Update scripts/ci/ui_test_plan.py so no test is silently skipped.')
    return sorted(found)


def select(tests, plan, tier, changed):
    if tier != 'pr' or plan.get('pr') is None:
        return list(tests)
    known = {test.split('/')[0] for test in tests}
    wanted = set(plan['pr'])
    for pattern, classes in (plan.get('paths') or {}).items():
        if any(fnmatch.fnmatch(path, pattern) for path in changed):
            wanted.update(classes)
    unknown = wanted - known
    if unknown:
        raise SystemExit(f'ui-test-plan.json names unknown UI test classes: {", ".join(sorted(unknown))}')
    return [test for test in tests if test.split('/')[0] in wanted]


def shard(tests, count, durations):
    """Longest-processing-time first: give each test to the least loaded shard."""
    loads = [[0.0, index, []] for index in range(count)]
    for test in sorted(tests, key=lambda name: (-durations.get(name, DEFAULT_SECONDS), name)):
        target = min(loads, key=lambda load: (load[0], load[1]))
        target[0] += durations.get(test, DEFAULT_SECONDS)
        target[2].append(test)
    return [(load[0], sorted(load[2])) for load in loads]


def main(argv=None):
    parser = argparse.ArgumentParser()
    mode = parser.add_mutually_exclusive_group(required=True)
    mode.add_argument('--shard', type=int, help='0-based shard index')
    mode.add_argument('--matrix', action='store_true', help='print the non-empty shards as JSON')
    parser.add_argument('--tier', choices=['pr', 'full'], default='full')
    parser.add_argument('--changed-files', type=Path, help='newline-separated changed paths (pr tier)')
    parser.add_argument('--plan', type=Path, default=PLAN)
    args = parser.parse_args(argv)
    plan = json.loads(args.plan.read_text())
    count = int(plan.get('shards', 1))
    if args.shard is not None and not 0 <= args.shard < count:
        raise SystemExit(f'--shard must be within 0..{count - 1}')
    changed = [line for line in args.changed_files.read_text().splitlines() if line] if args.changed_files else []
    tests = select(discover(), plan, args.tier, changed)
    durations = plan.get('durations', {})
    shards = shard(tests, count, durations)
    if args.matrix:
        matrix = [{'shard': index, 'tests': ' '.join(f'-only-testing:striusUITests/{test}' for test in part),
                   'count': len(part), 'minutes': round(seconds / 60, 1)}
                  for index, (seconds, part) in enumerate(shards) if part]
        print(f'UI tests: {len(tests)} selected ({args.tier}) across {len(matrix)} runner(s): '
              + ', '.join(f"{item['count']} tests ~{item['minutes']} min" for item in matrix), file=sys.stderr)
        print(json.dumps(matrix))
        return
    seconds, mine = shards[args.shard]
    print(f'UI tests: {len(tests)} selected ({args.tier}); shard {args.shard + 1}/{count}: '
          f'{len(mine)} tests, about {seconds / 60:.1f} min', file=sys.stderr)
    for test in mine:
        print(f'-only-testing:striusUITests/{test}')


if __name__ == '__main__':
    main()
