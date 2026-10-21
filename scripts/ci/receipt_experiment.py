#!/usr/bin/env python3
"""Offline proof of conservative test-result reuse; never publishes a CI check.

Inputs must come from authenticated GitHub reads by a trusted controller.
The only ignored path is this experiment's report directory. All other files,
including workflows, tests, resources, unknown paths and submodules, invalidate
the whole receipt. Module-level reuse is intentionally not implemented here.
"""
from datetime import datetime
import hashlib
import json
from pathlib import Path
import zipfile


def digest(value):
    return hashlib.sha256(json.dumps(value, sort_keys=True, separators=(',', ':')).encode()).hexdigest()


def fingerprint(tree, context):
    if tree.get('truncated'):
        raise ValueError('Truncated source inventory')
    entries = []
    for entry in tree['tree']:
        if entry['type'] == 'tree':
            continue
        if entry['path'].startswith('docs/ci-experiments/'):
            continue
        entries.append([entry['path'], entry['mode'], entry['type'], entry['sha']])
    if not entries:
        raise ValueError('Empty source inventory')
    return digest({'files': sorted(entries), 'context': context})


def test_cases(nodes):
    found = []
    for node in nodes:
        if node.get('nodeType') == 'Test Case':
            found.append(node)
        else:
            found.extend(test_cases(node.get('children', [])))
    return found


def validate_results(unit, ui, nodes, policy):
    required = set(policy['uiTests'])
    allowed_skips = set(policy['allowedUISkips'])
    cases = test_cases(nodes['testNodes'])
    names = [c.get('nodeIdentifier', '').removesuffix('()') for c in cases]
    if len(names) != len(set(names)) or set(names) != required:
        raise ValueError('Missing, duplicate or unexpected UI methods')
    skipped = {name for name, case in zip(names, cases) if case.get('result') == 'Skipped'}
    if skipped != allowed_skips:
        raise ValueError('Skipped test set differs from explicit policy')
    if any(c.get('result') not in ('Passed', 'Skipped') for c in cases):
        raise ValueError('UI failure or unknown result')
    for summary in (unit, ui):
        if summary.get('result') != 'Passed' or summary.get('failedTests') != 0:
            raise ValueError('Failed or missing result summary')
    if (ui['totalTestCount'] != len(required) or ui['skippedTests'] != len(skipped)
            or ui['passedTests'] != len(required) - len(skipped)):
        raise ValueError('UI summary does not match complete case inventory')
    if (unit['totalTestCount'] != policy['unitTotal']
            or unit['skippedTests'] != policy['unitSkipped']
            or unit['passedTests'] != policy['unitTotal'] - policy['unitSkipped']):
        raise ValueError('Unit summary differs from explicit policy')


def validate_origin(job, artifact, archive, source_commit, now):
    run = artifact['workflow_run']
    if (job.get('status') != 'completed' or job.get('conclusion') != 'success'
            or job.get('head_sha') != source_commit
            or run.get('head_sha') != source_commit or job.get('run_id') != run.get('id')
            or run.get('repository_id') != 1412177773):
        raise ValueError('GitHub source or successful job provenance mismatch')
    if artifact.get('expired') or artifact.get('digest') != 'sha256:' + hashlib.sha256(archive).hexdigest():
        raise ValueError('Expired or altered artifact')
    completed = datetime.fromisoformat(job['completed_at'].replace('Z', '+00:00')).timestamp()
    if not 0 <= now - completed <= 86400:
        raise ValueError('Receipt outside the explicit 24-hour window')


def make_receipt(data, archive_path, now):
    archive = Path(archive_path).read_bytes()
    validate_origin(data['job'], data['artifact'], archive, data['sourceCommit'], now)
    with zipfile.ZipFile(archive_path) as z:
        measurements = json.loads(z.read('measurements.json'))
        expected_name = f"ci-overnight-{data['job']['run_id']}-{measurements['configuration']}-{measurements['repetition']}"
        expected_job = f"{measurements['configuration']} / repeat {measurements['repetition']}"
        if data['artifact']['name'] != expected_name or data['job']['name'] != expected_job:
            raise ValueError('Artifact is not bound to the successful matrix job')
        if (measurements['commit'] != data['sourceCommit']
                or measurements['configuration'] != data['context']['configuration']
                or measurements['workers'] != data['context']['workers']
                or measurements['variant'] != data['context']['variant']
                or any(r['exitCode'] for r in measurements['runs'])):
            raise ValueError('Recorded execution context or command outcome mismatch')
        validate_results(json.loads(z.read('unit-summary.json')), json.loads(z.read('ui-summary.json')),
                         json.loads(z.read('ui-tests.json')), data['context']['policy'])
    return {'version': 1, 'inputFingerprint': fingerprint(data['sourceTree'], data['context']),
            'sourceCommit': data['sourceCommit'], 'jobId': data['job']['id'],
            'runId': data['job']['run_id'], 'artifactId': data['artifact']['id'],
            'context': data['context'], 'scope': 'whole repository except experiment reports'}


def reusable(receipt, candidate_tree, context):
    if receipt.get('version') != 1:
        raise ValueError('Unknown receipt version')
    return receipt['inputFingerprint'] == fingerprint(candidate_tree, context)


if __name__ == '__main__':
    import argparse
    import time
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--data', type=Path, required=True)
    parser.add_argument('--artifact', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    started = time.monotonic()
    data = json.loads(args.data.read_text())
    receipt = make_receipt(data, args.artifact, time.time())
    decisions = [{'commit': c['commit'], 'label': c['label'],
                  'reusable': reusable(receipt, c['tree'], data['context'])}
                 for c in data['candidates']]
    result = {'receipt': receipt, 'decisions': decisions, 'validationSeconds': time.monotonic() - started,
              'limitation': 'Offline validation only: no CI check is published, no production gate is changed, and no ten-minute end-to-end gate is claimed.'}
    args.output.write_text(json.dumps(result, ensure_ascii=False, indent=2) + '\n')
    print(json.dumps({'decisions': decisions, 'validationSeconds': result['validationSeconds']}, ensure_ascii=False))

