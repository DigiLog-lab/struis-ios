"""Linux-only checkpoint and branch DerivedData cleanup; never native caches."""
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
    count = delete_branch_cache(gh, branch) if branch else 0
    append_summary(f'Issue #{number}: checkpoints cleared; {count} branch DerivedData cache entries deleted.')


def owns_pr(pr, number, branch, repository):
    return ((pr.get('head', {}).get('repo') or {}).get('full_name') == repository
            and pr['head']['ref'] == branch and issue_for(pr) == number)


def main():
    event = json.loads(open(os.environ['GITHUB_EVENT_PATH']).read())
    gh, store = GitHub(), Store()
    if event.get('pull_request'):
        pr = event['pull_request']
        number = issue_for(pr)
        if number:
            state = store.get_json(session_key(number, 'state.json')) or {}
            if owns_pr(pr, number, state.get('branch'), gh.repository):
                cleanup(number, pr['head']['ref'], gh, store)
    elif event.get('issue') and not event['issue'].get('pull_request'):
        number = event['issue']['number']
        state = store.get_json(session_key(number, 'state.json')) or {}
        if state:
            cleanup(number, state.get('branch'), gh, store)
    else:
        # GITHUB_TOKEN close events may be suppressed. Periodic reconciliation
        # checks live Issue/PR state for every published checkpoint pointer.
        for item in store.list('sessions/'):
            match = re.fullmatch(r'sessions/([1-9]\d*)/workspace.json', item['key'])
            if not match:
                continue
            number = int(match[1])
            pointer = store.get_json(item['key']) or {}
            state = store.get_json(session_key(number, 'state.json')) or {}
            branch = state.get('branch')
            issue = gh.issue(number)
            closed = issue['state'] == 'closed'
            if branch and not closed:
                query = urllib.parse.urlencode({'head': gh.repository.split('/')[0] + ':' + branch, 'state': 'all'})
                prs = [pr for pr in gh.get(f'/repos/{gh.repository}/pulls?{query}')
                       if owns_pr(pr, number, branch, gh.repository)]
                closed = bool(prs) and all(pr['state'] == 'closed' for pr in prs)
            if closed:
                cleanup(number, branch, gh, store)
            elif pointer.get('closed'):
                # Retry a failed completion cleanup, without touching state or media.
                store.prune_checkpoints(number, [], checkpoints.iso())


if __name__ == '__main__':
    main()
