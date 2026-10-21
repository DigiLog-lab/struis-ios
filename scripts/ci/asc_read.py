"""Temporary read-only probe of Xcode Cloud and TestFlight state.

Never starts a build. Writes JSON summaries and the TEST log bundles of the
named builds into the output directory so they can be analysed offline.
"""
import json
import os
from pathlib import Path
import sys
import urllib.request

sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..', 'agent'))
from appstoreconnect import from_environment  # noqa: E402

PR_GATE = 'FD7B155C-3973-4DA5-A0A1-A6886411C5D3'
RELEASE = '32273285-7cf2-44cf-8e31-cc0385650439'
APP = '6771995650'
BUILDS = {
    'pr-gate-153': '0b18751d-a731-4af9-92b5-9a94fff6ea10',
    'release-154': '47828e85-8b7a-4872-892b-593a7324e670',
    'release-155': '86c8a47a-0611-41ec-99fd-cc4df91f212b',
    'pr-gate-156': 'b7da65de-f371-45a8-abdb-2fdad80aa90f',
}
LOG_LIMIT = 400 * 1024 * 1024


def keep(attrs, *names):
    return {name: attrs.get(name) for name in names}


def main():
    out = Path(sys.argv[1])
    out.mkdir(parents=True, exist_ok=True)
    client = from_environment(os.environ['APP_STORE_CONNECT_KEY_PATH'])

    def dump(name, value):
        (out / f'{name}.json').write_text(json.dumps(value, ensure_ascii=False, indent=2))

    gate = client.request('GET', f'/v1/ciWorkflows/{PR_GATE}?include=product')['data']
    product = gate['relationships']['product']['data']['id']
    workflows = []
    for workflow in client.paginate(f'/v1/ciProducts/{product}/workflows?limit=200'):
        attrs = workflow['attributes']
        workflows.append({'id': workflow['id'], **keep(attrs, 'name', 'isEnabled', 'clean', 'containerFilePath',
                                                       'lastModifiedDate', 'actions', 'branchStartCondition',
                                                       'pullRequestStartCondition', 'scheduledStartCondition',
                                                       'tagStartCondition', 'manualBranchStartCondition')})
    dump('workflows', workflows)
    names = {w['id']: w['name'] for w in workflows}

    runs = []
    try:
        listing = list(client.paginate(f'/v1/ciProducts/{product}/buildRuns?limit=200&include=workflow'))
    except RuntimeError as error:
        print(f'buildRuns include=workflow rejected: {error}', flush=True)
        listing = list(client.paginate(f'/v1/ciProducts/{product}/buildRuns?limit=200'))
    for run in listing:
        attrs = run['attributes']
        if (attrs.get('createdDate') or '') < '2026-09-15':
            continue
        workflow = ((run.get('relationships') or {}).get('workflow') or {}).get('data') or {}
        actions = []
        for action in client.paginate(f'/v1/ciBuildRuns/{run["id"]}/actions?limit=200'):
            a = action['attributes']
            actions.append({'id': action['id'], **keep(a, 'name', 'actionType', 'startedDate', 'finishedDate',
                                                       'completionStatus', 'issueCounts')})
        runs.append({'id': run['id'], 'workflow': names.get(workflow.get('id'), workflow.get('id')),
                     **keep(attrs, 'number', 'createdDate', 'startedDate', 'finishedDate', 'executionProgress',
                            'completionStatus', 'startReason', 'sourceCommit', 'clean'), 'actions': actions})
    dump('build-runs', runs)
    print(f'build runs since 2026-09-15: {len(runs)}', flush=True)

    for label, build in BUILDS.items():
      try:
        for action in client.paginate(f'/v1/ciBuildRuns/{build}/actions?limit=200'):
            a = action['attributes']
            if a.get('actionType') != 'TEST':
                continue
            results = []
            for result in client.paginate(f'/v1/ciBuildActions/{action["id"]}/testResults?limit=200'):
                r = result['attributes']
                results.append(keep(r, 'className', 'name', 'status', 'message', 'destinationTestResults'))
            dump(f'tests-{label}', results)
            counts = {}
            for r in results:
                counts[r.get('status')] = counts.get(r.get('status'), 0) + 1
            print(f'{label} TEST results: {len(results)} {counts}', flush=True)
            artifacts = []
            for artifact in client.paginate(f'/v1/ciBuildActions/{action["id"]}/artifacts?limit=200'):
                f = artifact['attributes']
                artifacts.append(keep(f, 'fileType', 'fileName', 'fileSize'))
                if f.get('fileType') == 'LOG_BUNDLE' and (f.get('fileSize') or 0) <= LOG_LIMIT:
                    target = out / f'logs-{label}.zip'
                    with urllib.request.urlopen(f['downloadUrl'], timeout=600) as response, target.open('wb') as file:
                        while chunk := response.read(1 << 20):
                            file.write(chunk)
                    print(f'{label}: downloaded {target.name} ({target.stat().st_size} bytes)', flush=True)
            dump(f'artifacts-{label}', artifacts)
      except Exception as error:  # keep probing the rest
        print(f'{label}: {error!r}', flush=True)

    builds = []
    for build in client.paginate(f'/v1/builds?filter[app]={APP}&sort=-uploadedDate&limit=50&include=preReleaseVersion'):
        attrs = build['attributes']
        version = ((build.get('relationships') or {}).get('preReleaseVersion') or {}).get('data') or {}
        builds.append({'id': build['id'], 'preReleaseVersionId': version.get('id'),
                       **keep(attrs, 'version', 'uploadedDate', 'processingState', 'expired')})
        if len(builds) >= 50:
            break
    versions = {}
    for version in client.paginate(f'/v1/preReleaseVersions?filter[app]={APP}&limit=50'):
        versions[version['id']] = version['attributes'].get('version')
    for build in builds:
        build['marketingVersion'] = versions.get(build.pop('preReleaseVersionId'))
    dump('testflight-builds', builds)
    print(json.dumps(builds[:15], ensure_ascii=False), flush=True)
    return 0


if __name__ == '__main__':
    sys.exit(main())
