#!/usr/bin/env python3
"""Generate Xcode Cloud test plans from the same UI selection used locally.

The gate omits only the methods in xcode-cloud-exclusions.json and runs the UI
test classes in parallel on simulator clones (Xcode distributes whole classes,
so long tests sit in classes of their own). Release keeps every test and runs
them serially, so its performance test measures a quiet simulator. Missing diff
information expands the gate to every eligible UI test; it must never quietly
reduce coverage to the minimum E2E classes.
"""
import argparse
import json
import os
from pathlib import Path
import subprocess
import uuid

import ui_test_plan

ROOT = ui_test_plan.ROOT
EXCLUSIONS = Path(__file__).with_name('xcode-cloud-exclusions.json')
TARGETS = {
    'striusTests': '992C09BB2F927BB9009FF690',
    'striusUITests': '992C09C52F927BB9009FF690',
}


def changed_files(base, root=ROOT):
    """Return the merge-base diff, or None to request conservative full coverage."""
    def git(*args):
        return subprocess.check_output(['git', *args], cwd=root, text=True, stderr=subprocess.DEVNULL,
                                       timeout=120, env=dict(os.environ, GIT_TERMINAL_PROMPT='0')).strip()
    try:
        git('check-ref-format', '--branch', base)
        git('fetch', '--no-tags', 'origin', f'refs/heads/{base}:refs/remotes/origin/{base}')
        return git('diff', '--name-only', '--no-renames', f'origin/{base}...HEAD').splitlines()
    except (subprocess.CalledProcessError, subprocess.TimeoutExpired):
        return None


def exclusions_for(discovered, manifest):
    if manifest.get('version') != 1:
        raise ValueError('Unsupported Xcode Cloud exclusion manifest version')
    excluded = {}
    for entry in manifest.get('methods', []):
        name = entry.get('test', '')
        if not entry.get('reason') or not entry.get('source'):
            raise ValueError(f'Exclusion needs a reason and source: {name}')
        if name not in discovered:
            raise ValueError(f'Exclusion names an unknown UI test: {name}')
        if name in excluded:
            raise ValueError(f'Duplicate exclusion: {name}')
        excluded[name] = entry
    return excluded


def generate(tier, changed, discovered=None, selection=None, manifest=None):
    discovered = ui_test_plan.discover() if discovered is None else discovered
    selection = json.loads(ui_test_plan.PLAN.read_text()) if selection is None else selection
    manifest = json.loads(EXCLUSIONS.read_text()) if manifest is None else manifest
    exclusions = exclusions_for(discovered, manifest)
    selected = (list(discovered) if tier == 'full' or changed is None
                else ui_test_plan.select(discovered, selection, 'pr', changed))
    omitted = sorted(set(selected) & exclusions.keys()) if tier == 'pr' else []
    selected = sorted(set(selected) - set(omitted))
    if not selected:
        raise ValueError('The Xcode Cloud UI test selection is empty')
    plan_name = 'PR Gate' if tier == 'pr' else 'Release'
    targets = [
        {'target': {'containerPath': 'container:strius.xcodeproj', 'identifier': TARGETS['striusTests'], 'name': 'striusTests'}},
        {'parallelizable': tier == 'pr',
         'selectedTests': [test + '()' for test in selected],
         'target': {'containerPath': 'container:strius.xcodeproj', 'identifier': TARGETS['striusUITests'], 'name': 'striusUITests'}},
    ]
    plan = {
        'configurations': [{'id': str(uuid.uuid5(uuid.NAMESPACE_URL, f'https://github.com/DigiLog-lab/struis-ios/{plan_name}')).upper(),
                            'name': plan_name, 'options': {}}],
        'defaultOptions': {'codeCoverage': False},
        'testTargets': targets,
        'version': 1,
    }
    report = {'tier': tier, 'changedFiles': changed, 'allEligibleUI': tier == 'full' or changed is None,
              'unitTests': 'all', 'uiTests': selected,
              'excludedUI': [exclusions[test] for test in omitted]}
    return plan, report


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--tier', choices=['pr', 'full'], required=True)
    diff = parser.add_mutually_exclusive_group()
    diff.add_argument('--base', help='Fetch this branch and compare its merge base with HEAD')
    diff.add_argument('--changed-files', type=Path)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--report', type=Path)
    args = parser.parse_args(argv)
    changed = None
    if args.changed_files:
        changed = [line for line in args.changed_files.read_text().splitlines() if line]
    elif args.base:
        changed = changed_files(args.base)
    plan, report = generate(args.tier, changed)
    report['checkoutHead'] = subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=ROOT, text=True).strip()
    report['head'] = (os.environ.get('CI_PULL_REQUEST_SOURCE_COMMIT')
                      or os.environ.get('CI_COMMIT') or report['checkoutHead'])
    report['cloudBuild'] = os.environ.get('CI_BUILD_ID')
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(plan, indent=2) + '\n')
    if args.report:
        args.report.parent.mkdir(parents=True, exist_ok=True)
        args.report.write_text(json.dumps(report, ensure_ascii=False, indent=2) + '\n')
    print(json.dumps(report, ensure_ascii=False, indent=2))


if __name__ == '__main__':
    main()
