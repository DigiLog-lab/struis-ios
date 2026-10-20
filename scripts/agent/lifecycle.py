"""Reconcile checkpoint-only R2 lifecycle prefixes, preserving other rules.

R2 matches prefixes, not globs: sessions/*/checkpoints/ is not a valid wildcard
rule. One managed rule per Issue preserves state.json and workspace.json.
"""
import argparse
import json
import os
import re
import urllib.parse
import urllib.request

from agentlib import Store, append_summary

MANAGED = re.compile(r'^struis-checkpoints-([1-9]\d*)$')


def rules_for(existing, issues, days=14):
    if not isinstance(days, int) or days < 1:
        raise ValueError('Checkpoint retention must be a positive number of days')
    rules = [rule for rule in existing if not MANAGED.fullmatch(rule.get('id', ''))]
    for issue in sorted(set(issues)):
        if not isinstance(issue, int) or issue < 1:
            raise ValueError('Invalid Issue number')
        rules.append({'id': f'struis-checkpoints-{issue}', 'enabled': True,
                      'conditions': {'prefix': f'sessions/{issue}/checkpoints/'},
                      'deleteObjectsTransition': {'condition': {'type': 'Age', 'maxAge': days * 86400}},
                      'abortMultipartUploadsTransition': {'condition': {'type': 'Age', 'maxAge': days * 86400}}})
    if len(rules) > 1000:
        raise RuntimeError('R2 lifecycle rule limit reached; checkpoint deletion needs investigation')
    return rules


def api(method, body=None):
    account = os.environ['CLOUDFLARE_ACCOUNT_ID']
    bucket = urllib.parse.quote(os.environ.get('AGENT_R2_BUCKET', 'struis-agent'), safe='')
    if not re.fullmatch(r'[a-fA-F0-9]{32}', account):
        raise ValueError('Invalid Cloudflare account ID')
    url = f'https://api.cloudflare.com/client/v4/accounts/{account}/r2/buckets/{bucket}/lifecycle'
    request = urllib.request.Request(url, method=method, data=json.dumps(body).encode() if body is not None else None,
                                     headers={'Authorization': 'Bearer ' + os.environ['CLOUDFLARE_API_TOKEN'],
                                              'Content-Type': 'application/json'})
    with urllib.request.urlopen(request, timeout=60) as response:
        result = json.load(response)
    if not result.get('success'):
        raise RuntimeError(f'Cloudflare lifecycle request failed: {result.get("errors")}')
    return result.get('result') or {}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--apply', action='store_true')
    parser.add_argument('--days', type=int, default=int(os.environ.get('AGENT_CHECKPOINT_RETENTION_DAYS', '14')))
    args = parser.parse_args()
    issues = set()
    for item in Store().list('sessions/'):
        match = re.match(r'sessions/([1-9]\d*)/checkpoints/', item['key'])
        if match:
            issues.add(int(match[1]))
    old = api('GET').get('rules', [])
    rules = rules_for(old, issues, args.days)
    if args.apply and rules != old:
        # The API replaces the whole list; fail if an administrator edited it
        # while this reconciliation was preparing its update.
        if api('GET').get('rules', []) != old:
            raise RuntimeError('Lifecycle rules changed concurrently; retry with the current rules')
        api('PUT', {'rules': rules})
    append_summary(f'R2 checkpoint lifecycle: {len(issues)} exact Issue prefixes, {args.days} days; '
                   f'{"applied" if args.apply else "preview only"}. Other rules and session state preserved.')
    if not args.apply:
        print(json.dumps({'rules': rules}, indent=2))


if __name__ == '__main__':
    main()
