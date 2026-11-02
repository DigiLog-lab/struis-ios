"""After an agent Issue closes: drop what only that Issue used.

Runs on Linux in agent.yml with actions: write (Actions caches) and contents: write (branches).
Deletes the working branch's DerivedData cache entries, the working branch itself (unless an open PR
still comes from it) and the Issue's handoff branch. A deleted working branch can be restored from its
merged or closed PR. The Native Runtime cache is shared and never touched here.
"""
import hashlib
import json
import os
import re
import urllib.parse

from agentlib import GitHub, Store, append_summary, session_key


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


def delete_ref(gh, branch):
    try:
        gh.request('DELETE', f'/repos/{gh.repository}/git/refs/heads/{urllib.parse.quote(branch, safe="/")}', retry=False)
        return True
    except RuntimeError as error:
        if 'HTTP 404' in str(error) or 'HTTP 422' in str(error):
            return False
        raise


def delete_handoff(gh, number):
    return delete_ref(gh, f'handoff/issue-{number}')


def delete_work_branch(gh, branch):
    """Delete the Issue's working branch. Only agent/ branches, and only when no open PR comes from it."""
    if not branch.startswith('agent/'):
        return 'kept (not an agent branch)'
    owner = gh.repository.split('/')[0]
    query = urllib.parse.urlencode({'state': 'open', 'head': f'{owner}:{branch}', 'per_page': 1})
    if gh.get(f'/repos/{gh.repository}/pulls?{query}'):
        return 'kept (open PR)'
    return 'deleted' if delete_ref(gh, branch) else 'not present'


WORK_BRANCH = re.compile(r'^agent/issue-([1-9]\d*)(?:-.+)?$')


def sweep_closed(gh):
    """Delete agent/issue-<n>[-…] branches whose Issue is closed and that no open PR comes from.

    Catches what the close-time cleanup missed: branches left before it existed, and side branches
    such as agent/issue-22-wip that the Issue's state does not name. Run when main moves.
    """
    refs = gh.get(f'/repos/{gh.repository}/git/matching-refs/heads/agent/issue-')
    states, deleted = {}, []
    for ref in refs:
        branch = ref['ref'].removeprefix('refs/heads/')
        match = WORK_BRANCH.match(branch)
        if not match:
            continue
        number = int(match[1])
        if number not in states:
            states[number] = gh.get(f'/repos/{gh.repository}/issues/{number}')['state']
        if states[number] == 'closed' and delete_work_branch(gh, branch) == 'deleted':
            deleted.append(branch)
    append_summary(f'Working branches of closed Issues deleted: {", ".join(deleted) or "none"}.')
    return deleted


def cleanup(number, branch, gh):
    branch = branch or f'agent/issue-{number}'
    caches = delete_branch_cache(gh, branch)
    work = delete_work_branch(gh, branch)
    handoff = delete_handoff(gh, number)
    append_summary(f'Issue #{number}: {caches} DerivedData cache entries deleted; '
                   f'working branch `{branch}` {work}; handoff branch {"deleted" if handoff else "not present"}.')


def main():
    event = json.loads(open(os.environ['GITHUB_EVENT_PATH']).read())
    issue = event.get('issue') or {}
    if event.get('action') != 'closed' or not issue or issue.get('pull_request'):
        return
    number = issue['number']
    state = Store().get_json(session_key(number, 'state.json')) or {}
    cleanup(number, state.get('branch'), GitHub())


if __name__ == '__main__':
    main()
