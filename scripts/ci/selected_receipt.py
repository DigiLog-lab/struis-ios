#!/usr/bin/env python3
"""Offline exact-HEAD acceptance of an explicitly selected verification result.

This proof accepts only the pinned push experiments, never posts a check,
never selects tests from a diff, and never reuses results across source changes.
"""
from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path
import zipfile

from benchmark_selected import validate_exports

WORKFLOW = '.github/workflows/ci-selected-experiment.yml'
REPOSITORY_ID = 1412177773


def stamp(value):
    return datetime.fromisoformat(value.replace('Z', '+00:00'))


def verify(archive, job, run, artifact, expected_sha, expected_ui, expected_units,
           trusted_definition_shas, now=None):
    now = now or datetime.now(timezone.utc)
    if run.get('head_sha') not in trusted_definition_shas or run.get('path') != WORKFLOW:
        raise ValueError('Unapproved workflow definition')
    if (run.get('head_sha') != expected_sha or job.get('run_id') != run.get('id')
            or job.get('head_sha', expected_sha) != expected_sha):
        raise ValueError('Requested HEAD does not match verification origin')
    if job.get('status') != 'completed' or job.get('conclusion') != 'success':
        raise ValueError('Verification job did not succeed')
    origin = artifact.get('workflow_run', {})
    if (origin.get('id') != run.get('id') or origin.get('head_sha') != expected_sha
            or origin.get('repository_id') != REPOSITORY_ID or artifact.get('expired') is not False):
        raise ValueError('Artifact origin mismatch')
    age = (now - stamp(job['completed_at'])).total_seconds()
    if not 0 <= age <= 86400:
        raise ValueError('Expired verification')
    actual_digest = hashlib.sha256(Path(archive).read_bytes()).hexdigest()
    if artifact.get('digest') != 'sha256:' + actual_digest:
        raise ValueError('Artifact digest mismatch')
    with zipfile.ZipFile(archive) as bundle:
        record = json.loads(bundle.read('measurement.json'))
        if (record.get('status') != 'success' or record.get('commit') != expected_sha
                or str(record.get('runId')) != str(run['id']) or record.get('retries') != 0):
            raise ValueError('Result is not a successful exact-HEAD measurement')
        if artifact.get('name') != 'ci-selected-' + str(run['id']) + '-' + record['configuration']:
            raise ValueError('Artifact configuration mismatch')
        selected = record.get('selection', {}).get('selected', [])
        if len(selected) != len(set(selected)) or set(selected) != set(expected_ui):
            raise ValueError('Requested UI inventory mismatch')
        results = []
        for phase in record.get('phases', []):
            if phase.get('exitCode') != 0 or phase.get('timedOut'):
                raise ValueError('A verification command failed or timed out')
            label = phase['label']
            if label not in {'combined', 'unit', 'ui'}:
                continue
            summary = json.loads(bundle.read(label + '-summary.json'))
            nodes = json.loads(bundle.read(label + '-tests.json'))
            results.append(validate_exports(summary, nodes, expected_units, expected_ui,
                include_unit=label != 'ui', include_ui=label != 'unit' and bool(expected_ui)))
        if (sum(r['unit'] for r in results) != len(expected_units)
                or sum(r['selectedUI'] for r in results) != len(expected_ui)
                or sum(r['probe'] for r in results) != (1 if expected_ui else 0)):
            raise ValueError('Missing or duplicated verification commands')
    return {'decision': 'accept-current-head-without-another-macOS-test-run',
            'head': expected_sha, 'jobId': job['id'], 'runId': run['id'],
            'selectedUI': expected_ui, 'unitCount': len(expected_units),
            'artifactSha256': actual_digest,
            'scope': 'Explicit policy + exact HEAD; no cross-source reuse or dependency-safety proof'}
