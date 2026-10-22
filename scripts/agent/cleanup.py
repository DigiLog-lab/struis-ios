"""Linux-only checkpoint and branch DerivedData cleanup; never native caches.

Runs in jobs with actions: write (the control job and the job after each
worker). Checkpoint artifacts that the pointer does not name are deleted;
anything missed still expires after the artifact retention period.
"""
import argparse
import hashlib
import json
import os
import re
import urllib.parse

from agentlib import GitHub, Store, append_summary, session_key
import checkpoints
from gate import issue_for


def cache_prefix(branch):
    return 'agent-derived-v1-' + hashlib.sha256(branch.encode()).hexdigest()[:16] + '-'


def delete_branch_cache(gh, branch):
    prefix, removed = cache_prefix(branch), 0
    while True:
        query = urllib.parse.urlencode({'key': prefix, 'per_page': 100})
        page = gh.get(f'/repos/{gh.repository}/actions/caches?{query}')
        matches = [item for item in page['actions_caches'] if item['key'].startswith(prefix)]
        if not matches:
            return removed
        for item in matches:
            gh.request('DELETE', f'/repos/{gh.repository}/actions/caches/{item["id"]}')
            removed += 1


def cleanup(number, branch=None, gh=None, store=None):
    gh, store = gh or GitHub(), store or Store()
    checkpoints.clear(store, number, 'issue-or-pr-closed')
    removed = checkpoints.prune(store, number)
    count = delete_branch_cache(gh, branch) if branch else 0
    append_summary(f'Issue #{number}: {removed} checkpoint artifacts and {count} branch DerivedData cache entries deleted.')


def owns_pr(pr, number, branch, repository):
    return ((pr.get('head', {}).get('repo') or {}).get('full_name') == repository
            and pr['head']['ref'] == branch and issue_for(pr) == number)


def reconcile(gh, store):
    # GITHUB_TOKEN close events may be suppressed. Periodic reconciliation
    # checks live Issue/PR state for every published checkpoint pointer.
    for item in store.list('sessions/'):
        match = re.fullmatch(r'sessions/([1-9]\d*)/workspace.json', item['key'])
        if not match:
            continue
        number = int(match[1])
        state = store.get_json(session_key(number, 'state.json')) or {}
        branch = state.get('branch')
        closed = gh.issue(number)['state'] == 'closed'
        if branch and not closed:
            query = urllib.parse.urlencode({'head': gh.repository.split('/')[0] + ':' + branch, 'state': 'all'})
            prs = [pr for pr in gh.get(f'/repos/{gh.repository}/pulls?{query}')
                   if owns_pr(pr, number, branch, gh.repository)]
            closed = bool(prs) and all(pr['state'] == 'closed' for pr in prs)
        if closed:
            cleanup(number, branch, gh, store)
        elif state.get('workerStatus') != 'running':
            # A worker never runs concurrently with this (its own job prunes
            # after it), so unreferenced saves are leftovers of a lost job.
            checkpoints.prune(store, number)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--prune-issue', type=int, help='after a worker: keep only the latest and previous save')
    args = parser.parse_args()
    gh, store = GitHub(), Store()
    if args.prune_issue:
        removed = checkpoints.prune(store, args.prune_issue)
        append_summary(f'Issue #{args.prune_issue}: {removed} unreferenced checkpoint artifacts deleted.')
        return
    event = json.loads(open(os.environ['GITHUB_EVENT_PATH']).read()) if os.environ.get('GITHUB_EVENT_PATH') else {}
    action = event.get('action')
    if event.get('pull_request') and action == 'closed':
        pr = event['pull_request']
        number = issue_for(pr)
        if number:
            state = store.get_json(session_key(number, 'state.json')) or {}
            if owns_pr(pr, number, state.get('branch'), gh.repository):
                cleanup(number, pr['head']['ref'], gh, store)
    elif event.get('issue') and not event['issue'].get('pull_request') and action == 'closed':
        number = event['issue']['number']
        state = store.get_json(session_key(number, 'state.json')) or {}
        if state:
            cleanup(number, state.get('branch'), gh, store)
    elif os.environ.get('GITHUB_EVENT_NAME') == 'schedule':
        reconcile(gh, store)


if __name__ == '__main__':
    main()
