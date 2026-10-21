"""Temporary: start one PR Gate build on the PR branch and collect its timings and logs.

Starts exactly one Xcode Cloud build; never retries a start.
"""
import json
import os
from pathlib import Path
import sys
import time
import urllib.request

sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..', 'agent'))
from appstoreconnect import from_environment  # noqa: E402

PR_GATE = 'FD7B155C-3973-4DA5-A0A1-A6886411C5D3'
BRANCH = os.environ['GATE_BRANCH']
EXPECTED = os.environ['GATE_SHA']


def main():
    out = Path(sys.argv[1])
    out.mkdir(parents=True, exist_ok=True)
    client = from_environment(os.environ['APP_STORE_CONNECT_KEY_PATH'])
    workflow = client.request('GET', f'/v1/ciWorkflows/{PR_GATE}?include=repository')['data']
    repository = workflow['relationships']['repository']['data']['id']
    refs = client.paginate(f'/v1/scmRepositories/{repository}/gitReferences?limit=200')
    matches = [r for r in refs if r['attributes'].get('canonicalName') == f'refs/heads/{BRANCH}' and not r['attributes'].get('isDeleted')]
    if len(matches) != 1:
        raise SystemExit(f'branch not resolved: {len(matches)}')
    created = client.request('POST', '/v1/ciBuildRuns', {'data': {'type': 'ciBuildRuns', 'attributes': {'clean': False},
        'relationships': {'workflow': {'data': {'type': 'ciWorkflows', 'id': PR_GATE}},
                          'sourceBranchOrTag': {'data': {'type': 'scmGitReferences', 'id': matches[0]['id']}}}}},
        retry_server_errors=False)['data']
    build = created['id']
    print(f'STARTED build={build} number={created["attributes"].get("number")}', flush=True)
    deadline = time.time() + 95 * 60
    run = created['attributes']
    while time.time() < deadline:
        try:
            run = client.request('GET', f'/v1/ciBuildRuns/{build}')['data']['attributes']
        except Exception as error:  # a read failure must not abandon the started build
            print(f'poll error: {error}', flush=True)
            time.sleep(60)
            continue
        print(f'progress={run.get("executionProgress")} status={run.get("completionStatus")}', flush=True)
        if run.get('executionProgress') == 'COMPLETE':
            break
        time.sleep(60)
    summary = {'build': build, 'run': run, 'expectedSha': EXPECTED, 'actions': []}
    sha = (run.get('sourceCommit') or {}).get('commitSha')
    print(f'sourceCommit={sha} expected={EXPECTED} match={sha == EXPECTED}', flush=True)
    for action in client.paginate(f'/v1/ciBuildRuns/{build}/actions?limit=200'):
        a = action['attributes']
        record = {k: a.get(k) for k in ('name', 'actionType', 'startedDate', 'finishedDate', 'completionStatus', 'issueCounts')}
        summary['actions'].append(record)
        print(json.dumps(record), flush=True)
        if a.get('actionType') == 'TEST':
            tests = [t['attributes'] for t in client.paginate(f'/v1/ciBuildActions/{action["id"]}/testResults?limit=200')]
            (out / 'tests.json').write_text(json.dumps(tests, ensure_ascii=False, indent=2))
            counts = {}
            for t in tests:
                counts[t.get('status')] = counts.get(t.get('status'), 0) + 1
            print('TESTS', counts, flush=True)
        for artifact in client.paginate(f'/v1/ciBuildActions/{action["id"]}/artifacts?limit=200'):
            f = artifact['attributes']
            name = f.get('fileName') or ''
            print('artifact', a.get('actionType'), f.get('fileType'), name, f.get('fileSize'), flush=True)
            wanted = f.get('fileType') == 'LOG_BUNDLE' or (f.get('fileType') == 'RESULT_BUNDLE' and (
                'test-without-building' in name or 'crash_log' in name))
            if wanted and (f.get('fileSize') or 0) > 100:
                safe = ''.join(c if c.isalnum() or c in '.-' else '-' for c in name)
                with urllib.request.urlopen(f['downloadUrl'], timeout=600) as response, (out / safe).open('wb') as file:
                    while chunk := response.read(1 << 20):
                        file.write(chunk)
                print('downloaded', safe, flush=True)
    (out / 'summary.json').write_text(json.dumps(summary, ensure_ascii=False, indent=2))


if __name__ == '__main__':
    main()
