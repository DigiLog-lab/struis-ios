#!/usr/bin/env python3
"""Choose which UI test methods one CI shard runs.

Reads scripts/ci/ui-test-plan.json:
  shards     number of runners the UI tests are split across, or {"pr": n, "full": m} per tier
  durations  measured seconds per "Class/method" (unknown methods count as DEFAULT_SECONDS)
  pr         optional list of test classes always run for pull requests
  paths      optional {glob: [classes]}; a class is added for a pull request when a changed file
             matches. The list ["*"] means every class (a change that can affect any test).
Without "pr", pull requests run every UI test (nothing is narrowed until the plan says so).
A changed striusUITests/<Class>.swift always adds that class; a changed striusUITests file that is
not a test class (UITestSupport.swift) runs every class.

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
# Type declarations only count at the top level (no indentation); nested helper types stay inside.
CLASS = re.compile(r'^(?:@[\w.]+(?:\([^)]*\))?\s+)*(?:(?:final|open|public|internal)\s+)*class\s+(\w+)\s*:\s*(\w+)')
EXTENSION = re.compile(r'^(?:@[\w.]+(?:\([^)]*\))?\s+)*(?:(?:public|internal|private|fileprivate)\s+)?extension\s+(\w+)\b')
OTHER_TYPE = re.compile(r'^(?:@[\w.]+(?:\([^)]*\))?\s+)*(?:(?:final|private|fileprivate|public|internal|open)\s+)*(?:class|struct|enum|actor|extension|protocol)\s+(\w+)')
TOP_LEVEL_CLOSE = re.compile(r'^}')
# Any indented test-shaped function, whatever attributes or modifiers precede it. Private ones are
# invisible to XCTest. Discovery and the completeness check use the same pattern, so a test is
# either attributed to a test class or reported, never silently skipped.
TEST_FUNC = re.compile(r'^(?!\s*//)\s+(?:.*?\s)??func\s+(test\w*)\s*\(\s*\)')
# A type declared inside a test class (a helper struct, an enum of fixtures). Its methods are not
# XCTest methods even when they are named test…, so they are skipped until its closing brace,
# which sits at the declaration's own indentation.
NESTED_TYPE = re.compile(r'^(\s+)(?:@[\w.]+(?:\([^)]*\))?\s+)*(?:(?:final|private|fileprivate|public|internal)\s+)*(?:class|struct|enum|actor|protocol)\s+\w+')
PRIVATE = re.compile(r'\b(?:private|fileprivate)\b')


def strip_comments(line):
    """Drop one-line /* */ comments and a trailing // comment (approximate; strings are rare here)."""
    line = re.sub(r'/\*.*?\*/', '', line)
    return line.split('//', 1)[0]


def code_lines(text, name='source'):
    """Code lines outside block comments and multi-line string literals.

    A file that ends while still inside a comment or string means the parse went wrong; that is
    reported instead of silently skipping the rest of the file.
    """
    in_comment = in_string = False
    for line in text.splitlines():
        if in_comment:
            if '*/' in line:
                in_comment = False
                rest = strip_comments(line.split('*/', 1)[1])
                if rest.strip():
                    yield rest
            continue
        if in_string:
            if line.count('"""') % 2 == 1:
                in_string = False
            continue
        code = strip_comments(line)
        if '/*' in code:
            in_comment = True
            code = code.split('/*', 1)[0]
        yield code
        if code.count('"""') % 2 == 1:
            in_string = True
    if in_comment or in_string:
        raise SystemExit(f'UI test discovery: {name} ends inside a {"comment" if in_comment else "multi-line string"}; '
                         'the parse is unreliable, so no test list was produced.')


STRING = re.compile(r'(#*)"(?:\\.|[^"\\])*"\1')


def brace_change(line):
    """Net `{` minus `}` on a code line, ignoring braces inside one-line string literals (JSON fixtures)."""
    code = STRING.sub('""', line)
    return code.count('{') - code.count('}')


def test_name(line):
    match = TEST_FUNC.match(line)
    prefix = line.split('func', 1)[0]
    # XCTest runs instance methods only; private ones are invisible to it.
    if not match or PRIVATE.search(prefix) or re.search(r'\b(?:static|class)\s*$', prefix):
        return None
    return match[1]


def discover(directory=TESTS):
    """Return sorted 'Class/method' names of XCTestCase test methods.

    Every UI test runs from an explicit -only-testing list, so a test this misses would never
    run. It therefore fails when any test-shaped function is not attributed to a test class.
    Test methods of a test base class also run in each subclass, so they are listed for both.
    """
    # Xcode compiles every Swift file under the synchronized test folder, subfolders included.
    sources = [(path, list(code_lines(path.read_text(), str(path.relative_to(directory)))))
               for path in sorted(directory.rglob('*.swift'))]
    parents = {}
    for _, lines in sources:
        for line in lines:
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
    methods = {name: set() for name in classes}
    unattributed = []
    for path, lines in sources:
        current = None
        nested = []  # indentation of each nested type declaration still open
        depth = 0  # brace depth inside the current test class or extension; its members sit at depth 1
        for line in lines:
            match = CLASS.match(line) or EXTENSION.match(line)
            if match:
                current = match[1] if match[1] in classes else None
                nested = []
                depth = brace_change(line)
                continue
            if OTHER_TYPE.match(line) or TOP_LEVEL_CLOSE.match(line):
                current = None
                nested = []
                depth = 0
                continue
            level = depth  # the depth this line starts at
            depth += brace_change(line)
            if nested and line.startswith(nested[-1] + '}'):
                nested.pop()
                continue
            inner = NESTED_TYPE.match(line)
            if inner and current:
                if not line.rstrip().endswith('}'):  # a one-line `struct X {}` opens nothing
                    nested.append(inner[1])
                continue
            if nested:
                continue
            name = test_name(line)
            if name:
                if current:
                    # Deeper than the class body: a local function inside a method or closure, not an XCTest method.
                    if level == 1:
                        methods[current].add(name)
                else:
                    unattributed.append(f'{path.relative_to(directory)}: {line.strip()}')
    if unattributed:
        raise SystemExit('UI test discovery could not tell which test class these belong to, so they would '
                         'never run. Fix the declaration or scripts/ci/ui_test_plan.py:\n  ' + '\n  '.join(unattributed))
    found = set()
    for name in classes:
        inherited, ancestor = set(methods[name]), parents.get(name)
        while ancestor in methods:
            inherited |= methods[ancestor]
            ancestor = parents.get(ancestor)
        found.update(f'{name}/{method}' for method in inherited)
    return sorted(found)


def select(tests, plan, tier, changed):
    if tier != 'pr' or plan.get('pr') is None:
        return list(tests)
    known = {test.split('/')[0] for test in tests}
    wanted = set(plan['pr'])
    for pattern, classes in (plan.get('paths') or {}).items():
        if any(fnmatch.fnmatch(path, pattern) for path in changed):
            if '*' in classes:
                return list(tests)
            wanted.update(classes)
    for path in changed:
        if path.startswith('striusUITests/') and path.endswith('.swift'):
            name = Path(path).stem
            if name in known:
                wanted.add(name)
            else:  # shared support code: any test may be affected
                return list(tests)
    unknown = wanted - known
    if unknown:
        raise SystemExit(f'ui-test-plan.json names unknown UI test classes: {", ".join(sorted(unknown))}')
    return [test for test in tests if test.split('/')[0] in wanted]


def shard_count(plan, tier):
    """Runners for a tier: "shards" is one number for every tier, or {"pr": n, "full": m}."""
    setting = plan.get('shards', 1)
    return int(setting.get(tier, 1) if isinstance(setting, dict) else setting)


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
    changed = [line for line in args.changed_files.read_text().splitlines() if line] if args.changed_files else []
    discovered = discover()
    tests = select(discovered, plan, args.tier, changed)
    # A pull request whose change can affect every test runs the whole suite on the full tier's runners.
    count = shard_count(plan, 'full' if len(tests) == len(discovered) else args.tier)
    if args.shard is not None and not 0 <= args.shard < count:
        raise SystemExit(f'--shard must be within 0..{count - 1}')
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
