"""After main moves, wake the agent of every PR waiting for review that can no longer take main.

Runs on Linux in agent.yml on a push to main (a merge, usually by the merge queue). The verification that
decides a merge runs in the merge queue on the latest main (Issue #81), so a waiting PR is no longer
brought up to date and verified again here: updating its branch would only drop its admission to the
queue. A PR that conflicts with the new main cannot enter the queue, so its Issue's agent is woken to
resolve the conflict (the worker merges main first and reports the conflicting files).
"""
import json
import os
import re
import time

import cleanup
from agentlib import GitHub, REPLY_MARKER, Store, append_summary, dispatch, iso, session_key

PR_ISSUE = re.compile(r'<!-- struis-agent:issue=([1-9]\d*) -->')


def waiting_prs(gh):
    """Open, non-Draft PRs into main from this repository that belong to an agent Issue."""
    result = []
    for pr in gh.paginate(f'/repos/{gh.repository}/pulls?state=open&base=main'):
        match = PR_ISSUE.search(pr.get('body') or '')
        if pr.get('draft') or not match or (pr['head'].get('repo') or {}).get('full_name') != gh.repository:
            continue
        result.append((pr, int(match[1])))
    return result


def mergeable(gh, number, attempts=10, wait=3):
    """GitHub computes `mergeable` in the background after main moves: None until it is known."""
    for _ in range(attempts):
        pr = gh.get(f'/repos/{gh.repository}/pulls/{number}')
        if pr.get('mergeable') is not None:
            return pr['mergeable'], pr['head']['sha']
        time.sleep(wait)
    return None, None


def refresh(gh, store, main_sha, wait=3):
    lines = []
    for pr, issue in waiting_prs(gh):
        number = pr['number']
        clean, head = mergeable(gh, number, wait=wait)
        if clean is None:
            lines.append(f'- PR #{number}: mergeability not known yet')
            continue
        if clean:
            lines.append(f'- PR #{number}: takes main without conflicts')
            continue
        failure = {'pr': number, 'sha': head, 'conflict': True, 'main': main_sha, 'at': iso()}

        def record(state):
            state['verifyFailure'] = failure
            return state
        store.update_json(session_key(issue, 'state.json'), record, default={})
        dispatch(gh, 'agent-issue', {'issue': issue})
        gh.comment(issue, f'{REPLY_MARKER}\n\n⚠️ mainが進み、PR #{number} はmainと衝突するのでマージキューに入れられません。エージェントに解消させます。')
        lines.append(f'- PR #{number}: conflict, Issue #{issue} woken')
    append_summary('\n'.join([f'### main `{main_sha[:12]}`', *lines]) if lines else f'main `{main_sha[:12]}`: no agent PR waiting')


def main():
    event = json.loads(open(os.environ['GITHUB_EVENT_PATH']).read())
    gh = GitHub()
    refresh(gh, Store(), event['after'])
    cleanup.sweep_closed(gh)


if __name__ == '__main__':
    main()
