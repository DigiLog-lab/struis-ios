#!/usr/bin/env python3
"""Choose which UI test methods a pull request runs, from the contracts in ui-test-plan.json.

Policy (docs/testing.md): every pull request runs all unit tests plus the UI tests of each contract its
change touches. There is no nightly full run, so a UI test that no contract selects never guards a merge.

ui-test-plan.json (schema 2):
  contracts   {name: {property, tests: ["Class/method"], paths: [glob]}}; a changed file that matches a
              contract's paths selects every test of that contract
  everything  globs whose change can affect any screen: every contract test runs
  folders     {glob: [contract names]} for a file no contract names, first match wins ([] = no UI test)
  guarded     globs of app and UI test sources; a guarded file that no rule covers stops the plan, so
              a new file is classified instead of quietly running nothing
  manual      {"Class/method": reason} run by hand (real device, real Codex, looked at as an image)
  excluded    {"Class/method": reason} never run as a regression test
  shards      {"full": n} runners for a manual full run
  durations   measured seconds per "Class/method" (unknown methods count as DEFAULT_SECONDS)
Every discovered UI test is in at least one contract or in exactly one of manual/excluded.
strius.xcodeproj/project.pbxproj selects nothing when its diff only adds or removes file references
(the added files select their own contracts); any other project change selects everything.
A changed striusUITests file selects the contract tests it declares; a striusUITests file that declares
no test class (UITestSupport.swift) selects everything.

--list prints the pull-request selection as JSON (contracts, reasons, uiTests). An empty uiTests list
is a valid answer: the caller then runs only the unit tests and must not call xcodebuild with an empty
-only-testing filter, which would run every test.
With --shard N / --matrix, prints the full tier split across runners (manual full runs).
"""
import argparse
import fnmatch
import json
import os
from pathlib import Path
import re
import subprocess
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
# Any indented test-shaped function, whatever attributes or modifiers precede it, as long as it is the
# first declaration on the line (`func helper() { func testX() {} }` declares a local function). Private ones are
# invisible to XCTest. Discovery and the completeness check use the same pattern, so a test is
# either attributed to a test class or reported, never silently skipped.
TEST_FUNC = re.compile(r'^(?!\s*//)\s+(?:(?:(?!\bfunc\b)[^{}])*?\s)??func\s+(test\w*)\s*\(\s*\)')
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


def file_classes(directory=TESTS):
    """{'striusUITests/<file>.swift': test classes declared there, with their subclasses}."""
    parents, declared = {}, {}
    for path in sorted(directory.rglob('*.swift')):
        relative = f'{directory.name}/{path.relative_to(directory)}'
        for line in code_lines(path.read_text(), relative):
            match = CLASS.match(line)
            if match:
                parents[match[1]] = match[2]
                declared.setdefault(relative, set()).add(match[1])
    def descendants(name):
        found = {name}
        while True:
            more = {child for child, parent in parents.items() if parent in found} - found
            if not more:
                return found
            found |= more
    return {path: set().union(*(descendants(name) for name in names)) for path, names in declared.items()}


class PlanError(SystemExit):
    """The plan cannot be trusted (an unclassified test or an unmapped source file)."""


PROJECT_FILE = 'strius.xcodeproj/project.pbxproj'
EVERYTHING = '*'
# Lines a file being added to or removed from the app target writes into project.pbxproj.
FILE_LIST_LINES = (
    re.compile(r'^\t\t[0-9A-F]{24} /\* [^*]+ \*/ = \{isa = PBX(?:BuildFile|FileReference);.*\};$'),
    re.compile(r'^\t\t\t\t[0-9A-F]{24} /\* [^*]+ \*/,$'),
)


def contract_tests(plan):
    return {name: list(contract['tests']) for name, contract in plan['contracts'].items()}


def validate(plan, discovered):
    """Every discovered UI test is classified, and the plan names only real tests and contracts."""
    if plan.get('schema') != 2:
        raise PlanError('ui-test-plan.json must be schema 2 (contracts)')
    known = set(discovered)
    in_contract = {test for tests in contract_tests(plan).values() for test in tests}
    manual, excluded = set(plan.get('manual', {})), set(plan.get('excluded', {}))
    named = in_contract | manual | excluded
    problems = []
    if unknown := sorted(named - known):
        problems.append('names UI tests that do not exist: ' + ', '.join(unknown))
    if loose := sorted(known - named):
        problems.append('these UI tests are in no contract and not manual or excluded: ' + ', '.join(loose))
    if twice := sorted((in_contract & (manual | excluded)) | (manual & excluded)):
        problems.append('these UI tests are classified twice: ' + ', '.join(twice))
    for pattern, names in plan.get('folders', {}).items():
        if missing := sorted(set(names) - plan['contracts'].keys()):
            problems.append(f'folder {pattern} names unknown contracts: ' + ', '.join(missing))
    if problems:
        raise PlanError('ui-test-plan.json: ' + '; '.join(problems))


def matches(path, patterns):
    return any(fnmatch.fnmatch(path, pattern) for pattern in patterns)


def file_list_only(diff):
    """True when every changed line of a project.pbxproj diff only adds or removes a file reference."""
    if diff is None:
        return False
    for line in diff.splitlines():
        if line.startswith(('+++', '---')) or not line.startswith(('+', '-')):
            continue
        if not any(pattern.match(line[1:]) for pattern in FILE_LIST_LINES):
            return False
    return True


def contracts_for(path, plan, project_diff=None):
    """The contract names one changed non-UI-test file selects, EVERYTHING, or an empty set."""
    if path == PROJECT_FILE:
        return set() if file_list_only(project_diff) else {EVERYTHING}
    if matches(path, plan.get('everything', [])):
        return {EVERYTHING}
    named = {name for name, contract in plan['contracts'].items() if matches(path, contract['paths'])}
    if named:
        return named
    for pattern, names in plan.get('folders', {}).items():
        if fnmatch.fnmatch(path, pattern):
            return set(names)
    if matches(path, plan.get('guarded', [])):
        raise PlanError(f'{path} is not covered by ui-test-plan.json. Add it to a contract\'s paths, a folder, '
                        'or "everything" so its UI tests are chosen on purpose.')
    return set()


def explain(tests, plan, changed, project_diff=None):
    """Return (selected tests, {contract or file reason: [changed paths]})."""
    validate(plan, tests)
    by_contract = contract_tests(plan)
    every = sorted({test for names in by_contract.values() for test in names})
    if changed is None:
        return every, {'everything': ['(no diff: every contract)']}
    chosen, reasons, direct = set(), {}, set()
    declared = None
    for path in changed:
        if path.startswith('striusUITests/') and path.endswith('.swift'):
            if declared is None:
                declared = file_classes()
            test_classes = {test.split('/')[0] for test in tests}
            # Test classes declared in the file (a deleted test file is known by its name).
            classes = (declared.get(path) or {Path(path).stem}) & test_classes
            if not classes:  # shared support code (no test class), even if it declares helper classes
                names = {EVERYTHING}
            else:
                own = {test for test in every if test.split('/')[0] in classes}
                direct |= own
                if own:
                    reasons.setdefault('changed UI test file', []).append(path)
                continue
        else:
            names = contracts_for(path, plan, project_diff)
        for name in names:
            reasons.setdefault('everything' if name == EVERYTHING else name, []).append(path)
        chosen |= names
    if EVERYTHING in chosen:
        return every, reasons
    selected = {test for name in chosen for test in by_contract[name]} | direct
    return sorted(selected), reasons


def select(tests, plan, tier, changed, project_diff=None):
    """UI tests for a tier: 'full' = every discovered test, 'pr' = the contract selection."""
    if tier != 'pr':
        return list(tests)
    return explain(tests, plan, changed, project_diff)[0]


def git_diff(base, *paths, root=ROOT, context=None):
    """`git diff origin/<base>...HEAD`, or None when the base cannot be fetched (callers widen to everything)."""
    def git(*args):
        return subprocess.check_output(['git', *args], cwd=root, text=True, stderr=subprocess.DEVNULL,
                                       timeout=120, env=dict(os.environ, GIT_TERMINAL_PROMPT='0'))
    try:
        git('check-ref-format', '--branch', base)
        git('fetch', '--no-tags', 'origin', f'refs/heads/{base}:refs/remotes/origin/{base}')
        options = ['--name-only'] if not paths else [f'-U{context or 0}']
        return git('diff', *options, '--no-renames', f'origin/{base}...HEAD', '--', *paths)
    except (subprocess.CalledProcessError, subprocess.TimeoutExpired, OSError):
        return None


def changed_files(base, root=ROOT):
    """Paths changed since the merge base with origin/<base>, or None to request every contract."""
    names = git_diff(base, root=root)
    return None if names is None else [line for line in names.splitlines() if line]


def project_diff(base, root=ROOT):
    return git_diff(base, PROJECT_FILE, root=root)


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


def read_lines(path):
    return [line for line in path.read_text().splitlines() if line] if path else []


def main(argv=None):
    parser = argparse.ArgumentParser()
    mode = parser.add_mutually_exclusive_group(required=True)
    mode.add_argument('--list', action='store_true', help='print the pull-request selection as JSON')
    mode.add_argument('--shard', type=int, help='0-based shard index (full tier)')
    mode.add_argument('--matrix', action='store_true', help='print the non-empty full-tier shards as JSON')
    parser.add_argument('--changed-files', type=Path, help='newline-separated changed paths (--list)')
    parser.add_argument('--no-diff', action='store_true', help='the diff is unknown: select every contract (--list)')
    parser.add_argument('--project-diff', type=Path, help='`git diff -U0` of strius.xcodeproj/project.pbxproj (--list)')
    parser.add_argument('--plan', type=Path, default=PLAN)
    args = parser.parse_args(argv)
    plan = json.loads(args.plan.read_text())
    discovered = discover()
    if args.list:
        changed = None if args.no_diff else read_lines(args.changed_files)
        diff = args.project_diff.read_text() if args.project_diff else None
        tests, reasons = explain(discovered, plan, changed, diff)
        minutes = sum(plan.get('durations', {}).get(test, DEFAULT_SECONDS) for test in tests) / 60
        print(f'UI tests: {len(tests)} selected by {", ".join(sorted(reasons)) or "no contract"} '
              f'(about {minutes:.1f} min of test time)', file=sys.stderr)
        print(json.dumps({'changedFiles': changed, 'reasons': reasons, 'uiTests': tests}, ensure_ascii=False))
        return
    validate(plan, discovered)
    count = shard_count(plan, 'full')
    if args.shard is not None and not 0 <= args.shard < count:
        raise SystemExit(f'--shard must be within 0..{count - 1}')
    shards = shard(discovered, count, plan.get('durations', {}))
    if args.matrix:
        matrix = [{'shard': index, 'tests': ' '.join(f'-only-testing:striusUITests/{test}' for test in part),
                   'count': len(part), 'minutes': round(seconds / 60, 1)}
                  for index, (seconds, part) in enumerate(shards) if part]
        print(f'UI tests: {len(discovered)} (full) across {len(matrix)} runner(s): '
              + ', '.join(f"{item['count']} tests ~{item['minutes']} min" for item in matrix), file=sys.stderr)
        print(json.dumps(matrix))
        return
    seconds, mine = shards[args.shard]
    print(f'UI tests: {len(discovered)} (full); shard {args.shard + 1}/{count}: '
          f'{len(mine)} tests, about {seconds / 60:.1f} min', file=sys.stderr)
    for test in mine:
        print(f'-only-testing:striusUITests/{test}')


if __name__ == '__main__':
    main()
