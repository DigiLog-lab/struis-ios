"""Start an Xcode Cloud build on request (repository_dispatch event `xcode-cloud`).

client_payload: {"workflow": "release" | "pr-gate", "branch": "main", "issue": "N"}
Release (TestFlight internal distribution) runs only from main. The job waits
for the build and writes its actions and failed tests to the run summary, and
to the Issue when one is given. This is how a person or an agent without the
App Store Connect key asks for a build: the key stays in this Linux job.
"""
import json
import os
import re
import time

from agentlib import GitHub, REPLY_MARKER, append_summary, gate_config
from gate import cloud_client, cloud_url, post_build, resolve_branch

WORKFLOWS = {'release': 'xcodeCloudReleaseWorkflowId', 'pr-gate': 'xcodeCloudPrGateWorkflowId'}
BRANCH = re.compile(r'^[A-Za-z0-9._/-]{1,200}$')


def payload():
    event = json.loads(open(os.environ['GITHUB_EVENT_PATH']).read())
    data = event.get('client_payload') or {}
    workflow, branch = data.get('workflow', ''), data.get('branch') or 'main'
    issue = data.get('issue') or ''
    if workflow not in WORKFLOWS:
        raise SystemExit(f'Unknown workflow {workflow!r}; use release or pr-gate')
    if not BRANCH.match(branch) or '..' in branch:
        raise SystemExit('Invalid branch')
    if workflow == 'release' and branch != 'main':
        raise SystemExit('Release distributes to TestFlight and runs only from main')
    if issue and not issue.isdecimal():
        raise SystemExit('issue must be a number')
    return workflow, branch, int(issue) if issue else None


def summarize(client, build_id):
    lines = []
    for action in client.paginate(f'/v1/ciBuildRuns/{build_id}/actions?limit=200'):
        a = action['attributes']
        lines.append(f'- {a.get("name")} ({a.get("actionType")}): {a.get("completionStatus")} '
                     f'{a.get("startedDate")} → {a.get("finishedDate")}')
        if a.get('actionType') == 'TEST':
            failed = [f'{t["attributes"].get("className")}/{t["attributes"].get("name")}'
                      for t in client.paginate(f'/v1/ciBuildActions/{action["id"]}/testResults?limit=200')
                      if t['attributes'].get('status') not in ('SUCCESS', 'SKIPPED')]
            lines += [f'  - 失敗: `{name}`' for name in failed[:30]]
    return lines


def main():
    workflow_key, branch, issue = payload()
    client = cloud_client()
    workflow_id = gate_config()[WORKFLOWS[workflow_key]]
    workflow = client.request('GET', f'/v1/ciWorkflows/{workflow_id}?include=repository')['data']
    created = post_build(client, workflow_id, resolve_branch(client, workflow, branch))
    url = cloud_url(created['id'])
    number = created.get('attributes', {}).get('number')
    append_summary(f'Xcode Cloud {workflow_key} build {number} on {branch}: {url}')
    gh = GitHub()
    if issue:
        gh.comment(issue, f'{REPLY_MARKER}\n\nXcode Cloudの{workflow_key}（ビルド{number}、{branch}）を開始しました: {url}')
    deadline = time.monotonic() + 100 * 60
    while time.monotonic() < deadline:
        attributes = client.request('GET', f'/v1/ciBuildRuns/{created["id"]}')['data']['attributes']
        if attributes.get('executionProgress') == 'COMPLETE':
            lines = [f'Xcode Cloud {workflow_key} build {number}: {attributes.get("completionStatus")}',
                     f'commit `{(attributes.get("sourceCommit") or {}).get("commitSha")}`', *summarize(client, created['id'])]
            append_summary('\n'.join(lines))
            if issue:
                gh.comment(issue, REPLY_MARKER + '\n\n' + '\n'.join(lines) + f'\n\n{url}')
            if attributes.get('completionStatus') != 'SUCCEEDED':
                raise SystemExit(1)
            return
        time.sleep(60)
    append_summary(f'Xcode Cloud {workflow_key} build {number} is still running: {url}')


if __name__ == '__main__':
    main()
