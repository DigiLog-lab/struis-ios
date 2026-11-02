"""After main moves, bring every agent PR waiting for review up to date and verify it again.

Runs on Linux in agent.yml on a push to main (a merge). A PR's green `Struis / verify` only holds for
the main it was verified on, so each open, non-Draft agent PR that no longer contains main is updated
on GitHub's side (the "Update branch" merge, no runner) and its new HEAD is sent to ios.yml again. A PR
that cannot take main without conflicts wakes its Issue's agent to resolve them.
"""
import json
import os
import re
import time

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


def contains(gh, main_sha, head_sha):
    return gh.get(f'/repos/{gh.repository}/compare/{main_sha}...{head_sha}')['behind_by'] == 0


def new_head(gh, number, old, attempts=30, wait=2):
    """The update is asynchronous: wait until the PR's head moves off the old commit."""
    for _ in range(attempts):
        head = gh.get(f'/repos/{gh.repository}/pulls/{number}')['head']['sha']
        if head != old:
            return head
        time.sleep(wait)
    return None


def refresh(gh, store, main_sha, wait=2):
    lines = []
    for pr, issue in waiting_prs(gh):
        number, head = pr['number'], pr['head']['sha']
        if contains(gh, main_sha, head):
            lines.append(f'- PR #{number}: already contains main')
            continue
        try:
            gh.request_once('PUT', f'/repos/{gh.repository}/pulls/{number}/update-branch', {'expected_head_sha': head})
        except RuntimeError as error:
            if 'HTTP 422' not in str(error) or 'expected' in str(error).lower():
                lines.append(f'- PR #{number}: not updated ({error})')
                continue
            failure = {'pr': number, 'sha': head, 'conflict': True, 'main': main_sha, 'at': iso()}

            def record(state):
                state['verifyFailure'] = failure
                return state
            store.update_json(session_key(issue, 'state.json'), record, default={})
            dispatch(gh, 'agent-issue', {'issue': issue})
            gh.comment(issue, f'{REPLY_MARKER}\n\n⚠️ mainが進みましたが、PR #{number} へ取り込むと衝突します。エージェントに解消させます。')
            lines.append(f'- PR #{number}: conflict, Issue #{issue} woken')
            continue
        updated = new_head(gh, number, head, wait=wait)
        if not updated:
            lines.append(f'- PR #{number}: update accepted, new head not visible yet')
            continue
        dispatch(gh, 'verify', {'pr': number, 'sha': updated, 'issue': issue})
        gh.comment(issue, f'{REPLY_MARKER}\n\nmainが進んだので、PR #{number} に取り込み(`{updated[:12]}`)、検証し直しています。'
                          '緑になるまでマージは待ってください。')
        lines.append(f'- PR #{number}: updated to {updated[:12]}, verification started')
    append_summary('\n'.join([f'### main `{main_sha[:12]}`', *lines]) if lines else f'main `{main_sha[:12]}`: no agent PR waiting')


def main():
    event = json.loads(open(os.environ['GITHUB_EVENT_PATH']).read())
    refresh(GitHub(), Store(), event['after'])


if __name__ == '__main__':
    main()
