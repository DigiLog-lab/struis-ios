"""Report the end of a `Verify PR #<n> <sha>` run of ios.yml back to the PR and the Issue.

Runs on Linux in agent.yml, called by that run's last job, from main's code only. The PR and the commit
come from the run's repository_dispatch payload (the commit ios.yml checked out), the result from its
jobs (VERIFY_CONCLUSION). It writes the commit status
`Struis / verify` on the verified SHA (shown on the PR), and when that SHA is still
the head of the open PR: on green it tells the Issue the PR can be merged, on red it records the
failure and wakes the Issue's agent to fix it.
"""
import json
import os
import re

from agentlib import GitHub, REPLY_MARKER, Store, append_summary, dispatch, iso, run_url, session_key

CONTEXT = 'Struis / verify'
TITLE = re.compile(r'^Verify PR #([1-9]\d*) ([0-9a-f]{40})$')
PR_ISSUE = re.compile(r'<!-- struis-agent:issue=([1-9]\d*) -->')


def parse(title):
    match = TITLE.match(title or '')
    return (int(match[1]), match[2]) if match else None


def from_dispatch(event, conclusion, url, run_id, tier=None):
    """The shape report() reads, from the verification run's own repository_dispatch payload."""
    payload = event.get('client_payload') or {}
    return {'workflow_run': {'id': run_id, 'display_title': f"Verify PR #{payload.get('pr')} {payload.get('sha')}",
                             'conclusion': conclusion, 'html_url': url, 'ui_tier': payload.get('ui_tier'), 'tier': tier}}


def failed_steps(gh, run_id):
    jobs = gh.get(f'/repos/{gh.repository}/actions/runs/{run_id}/jobs?per_page=100')['jobs']
    failed = []
    for job in jobs:
        if job.get('conclusion') in ('success', 'skipped', None):
            continue
        steps = [step['name'] for step in job.get('steps') or [] if step.get('conclusion') not in ('success', 'skipped', None)]
        failed.append({'job': job['name'], 'conclusion': job['conclusion'], 'steps': steps, 'url': job.get('html_url')})
    return failed


# What the merge queue (scripts/ci/merge_queue.py) writes when it gives up on a commit or sets an old green back.
QUEUE_PREFIX = 'マージキュー: '
QUEUE_STALE = QUEUE_PREFIX + 'main が進んだので、キューで検証し直します'


def abandoned_by_queue(gh, sha):
    """The queue dropped this commit (red with its reason: e.g. the verification ran past two hours and the
    next PR is being verified) or set its green back because main moved. A late result must not overwrite
    that: a success would let auto-merge merge it beside the next PR's verification."""
    for status in gh.get(f'/repos/{gh.repository}/commits/{sha}/status').get('statuses', []):
        if status.get('context') == CONTEXT:
            description = status.get('description') or ''
            return description.startswith(QUEUE_PREFIX) and (
                status.get('state') in ('failure', 'error') or description == QUEUE_STALE)
    return False


def report(event, gh, store):
    run = event['workflow_run']
    parsed = parse(run.get('display_title'))
    if not parsed:
        print('Not a PR verification run')
        return
    number, sha = parsed
    if abandoned_by_queue(gh, sha):
        append_summary(f'PR #{number} `{sha[:12]}`: {run.get("conclusion")}, not written (the merge queue gave up on this commit)')
        return
    if run.get('conclusion') == 'success' and gh.get(f'/repos/{gh.repository}/pulls/{number}').get('state') != 'open':
        # Closed while it was verified: a green now would let it merge on an older main if it were reopened.
        append_summary(f'PR #{number} `{sha[:12]}`: success, not written (the PR is closed)')
        return
    conclusion = run.get('conclusion')
    green = conclusion == 'success'
    # A cancelled run (replaced or stopped by hand) says nothing about the code: an error status, no wake-up.
    status = 'success' if green else 'error' if conclusion == 'cancelled' else 'failure'
    tested = ('全単体テストのみ(UIテストなし)' if run.get('ui_tier') == 'unit'
              else '見た目だけ(Release archiveのみ)' if run.get('tier') == 'cosmetic'
              else 'アプリに触らない変更(macOSなし)' if run.get('tier') == 'none'
              else '全単体テスト＋変更に関係するUIテスト')
    gh.request('POST', f'/repos/{gh.repository}/statuses/{sha}', {
        'state': status, 'context': CONTEXT, 'target_url': run['html_url'],
        'description': f'ios.yml: {tested}' if green else f'ios.yml: {conclusion}'})
    pr = gh.get(f'/repos/{gh.repository}/pulls/{number}')
    match = PR_ISSUE.search(pr.get('body') or '')
    current = pr['state'] == 'open' and pr['head']['sha'] == sha
    append_summary(f'PR #{number} `{sha[:12]}`: {conclusion} (current head: {current})')
    if not match or not current or status == 'error':
        return
    issue = int(match[1])
    key = session_key(issue, 'state.json')
    if green:
        def clear(state):
            state.pop('verifyFailure', None)
            return state
        store.update_json(key, clear, default={})
        gh.comment(issue, f'{REPLY_MARKER}\n\n✅ PR #{number} の検証(`{sha[:12]}`)が緑です。最新のmainを含んだこのHEADでマージできます。\n\n- 検証: {run["html_url"]}')
        return
    failure = {'pr': number, 'sha': sha, 'run': run['html_url'], 'conclusion': conclusion,
               'failed': failed_steps(gh, run['id']), 'at': iso()}

    def record(state):
        state['verifyFailure'] = failure
        return state
    store.update_json(key, record, default={})
    dispatch(gh, 'agent-issue', {'issue': issue})
    gh.comment(issue, f'{REPLY_MARKER}\n\n❌ PR #{number} の検証(`{sha[:12]}`)が赤でした。エージェントに直させます。\n\n- 検証: {run["html_url"]}')


def main():
    event = json.loads(open(os.environ['GITHUB_EVENT_PATH']).read())
    report(from_dispatch(event, os.environ['VERIFY_CONCLUSION'], run_url(), os.environ['GITHUB_RUN_ID'],
                         os.environ.get('VERIFY_TIER')), GitHub(), Store())


if __name__ == '__main__':
    main()
