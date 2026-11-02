"""After an agent Issue closes: drop what only that Issue used.

Runs on Linux in agent.yml with actions: write (Actions caches) and contents: write (branches).
Deletes the branch's DerivedData cache entries and the Issue's handoff branch. The Native Runtime
cache is shared and never touched here.
"""
import hashlib
import json
import os
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


def delete_handoff(gh, number):
    branch = f'handoff/issue-{number}'
    try:
        gh.request('DELETE', f'/repos/{gh.repository}/git/refs/heads/{urllib.parse.quote(branch, safe="/")}', retry=False)
        return True
    except RuntimeError as error:
        if 'HTTP 404' in str(error) or 'HTTP 422' in str(error):
            return False
        raise


def cleanup(number, branch, gh):
    caches = delete_branch_cache(gh, branch) if branch else 0
    handoff = delete_handoff(gh, number)
    append_summary(f'Issue #{number}: {caches} DerivedData cache entries deleted; '
                   f'handoff branch {"deleted" if handoff else "not present"}.')


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
