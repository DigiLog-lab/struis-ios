"""Trusted Linux controller for Ready -> external gate -> Issue worker.

The controller runs code from main. Workers may read gates/*, but the store
allows only this workflow to write it. GitHub's job concurrency serializes
controllers; CAS also protects records against stale administrative writes.
"""
import argparse
import base64
import datetime
import hashlib
import json
import os
from pathlib import Path
import re
import secrets
import tempfile
import urllib.parse

from agentlib import GitHub, REPLY_MARKER, Store, append_summary, iso, session_key
import checkpoints
import delivery
from appstoreconnect import from_environment

CONTEXT = 'Struis / Ready gate'
TERMINAL = {'complete', 'invalidated', 'blocked'}


def gate_key(pr):
    return f'gates/pr-{int(pr)}.json'


def issue_for(pr):
    match = re.search(r'<!-- struis-agent:issue=([1-9]\d*) -->', pr.get('body') or '')
    return int(match[1]) if match else None


def status(gh, record, state, description):
    gh.request('POST', f'/repos/{gh.repository}/statuses/{record["head"]}',
               {'state': state, 'context': CONTEXT, 'description': description[:140],
                'target_url': record.get('url') or f'https://github.com/{gh.repository}/pull/{record["pr"]}'})


def backend():
    selected = os.environ.get('AGENT_GATE_BACKEND', 'xcode-cloud')
    if selected not in ('xcode-cloud', 'github'):
        raise RuntimeError('AGENT_GATE_BACKEND must be xcode-cloud or github')
    remaining, estimate = os.environ.get('XCODE_CLOUD_REMAINING_MINUTES'), os.environ.get('AGENT_GATE_ESTIMATED_MINUTES')
    if remaining is not None and remaining != '' and estimate is not None and estimate != '':
        if float(remaining) < 0 or float(estimate) <= 0:
            raise RuntimeError('Cloud remaining/estimated minutes are invalid')
        if float(remaining) < float(estimate):
            selected = 'github'
    return selected


def cloud_client():
    return from_environment(os.environ['APP_STORE_CONNECT_KEY_PATH'])


def cloud_workflow(client):
    identifier = os.environ['XCODE_CLOUD_PR_GATE_WORKFLOW_ID']
    workflow = client.request('GET', f'/v1/ciWorkflows/{identifier}?include=repository')['data']
    attributes = workflow['attributes']
    if not attributes.get('isEnabled') or attributes.get('clean'):
        raise RuntimeError('PR Gate must be enabled with Clean disabled')
    if attributes.get('containerFilePath') != 'strius.xcodeproj':
        raise RuntimeError('PR Gate must use strius.xcodeproj')
    actions = attributes.get('actions', [])
    if not any(action.get('actionType') == 'TEST' and action.get('scheme') == 'StruisPRGate'
               and action.get('isRequiredToPass') is True for action in actions):
        raise RuntimeError('PR Gate needs a TEST action using StruisPRGate')
    if any(attributes.get(name) for name in ('branchStartCondition', 'pullRequestStartCondition', 'tagStartCondition', 'scheduledStartCondition')):
        raise RuntimeError('PR Gate must be started manually by the Ready controller')
    if any(action.get('actionType') == 'ARCHIVE' for action in actions):
        raise RuntimeError('PR Gate may not archive or distribute builds')
    return workflow


def request_data(store, gh, pr, request_id=None, renew=False):
    issue = issue_for(pr)
    if not issue or (pr['head'].get('repo') or {}).get('full_name') != gh.repository:
        raise RuntimeError('Only marked same-repository agent PRs may start a gate')
    request = store.get_json(session_key(issue, 'gate-request.json'))
    if not request_id and (renew or not request or request.get('head') != pr['head']['sha'] or request.get('pr') != pr['number']):
        # A human may clear Draft in GitHub after local-verify saved its proof,
        # without running agentctl ready. Both paths use the same validation.
        checkpoint = store.get_json(session_key(issue, 'workspace.json')) or {}
        if not checkpoint.get('prefix') or checkpoint.get('closed'):
            raise RuntimeError('No completed checkpoint for this Ready transition')
        parts = checkpoints.load_components(store, checkpoint)
        run = json.loads(parts['run.json'])
        request = {'schema': 1, 'request': secrets.token_hex(12), 'issue': issue, 'pr': pr['number'],
                   'head': pr['head']['sha'], 'branch': pr['head']['ref'], 'at': iso(), 'checkpoint': checkpoint,
                   'scope': {'includedComments': run['includedComments'], 'includedIssueBody': run['includedIssueBody']}}
        store.put_json(session_key(issue, 'gate-request.json'), request)
    if not request or (request_id and request.get('request') != request_id):
        raise RuntimeError('No matching Ready request')
    if (request.get('pr') != pr['number'] or request.get('head') != pr['head']['sha']
            or request.get('branch') != pr['head']['ref']):
        raise RuntimeError('Ready request does not match the current PR HEAD')
    checkpoint = request['checkpoint']
    expected_prefix = session_key(issue, f'checkpoints/{checkpoint["saveId"]}')
    if checkpoint.get('prefix') != expected_prefix or checkpoint.get('head') != request['head']:
        raise RuntimeError('Ready checkpoint is outside this Issue/HEAD')
    components = checkpoints.load_components(store, checkpoint)
    local = json.loads(components['local-verification.json'])
    snapshot = json.loads(components['request-snapshot.json'])
    items = json.loads(components['work-items.json'])
    if not delivery.verified(local, request['head'], snapshot, items):
        raise RuntimeError('Ready checkpoint has no complete exact-HEAD local verification')
    content = gh.get(f'/repos/{gh.repository}/contents/scripts/ci/xcode-cloud-exclusions.json?ref={request["head"]}')
    manifest = json.loads(base64.b64decode(content['content']))
    if manifest.get('version') != 1:
        raise RuntimeError('Unknown gate exclusion manifest')
    omitted = {item['test'] for item in manifest['methods']}
    units = next(check for check in local['checks'] if check['name'] == 'unit-tests')
    required = {normalize_test(*row['test'].rsplit('/', 1)) for row in delivery.test_rows(units['testResults'])}
    required.update(set(local['selection']['uiTests']) - omitted)
    request = dict(request, expectedTests=sorted(required))
    if not request_id:
        body = re.sub(re.escape(delivery.SUMMARY_START) + r'.*?' + re.escape(delivery.SUMMARY_END),
                      '', pr.get('body') or '', flags=re.S).strip()
        updated_body = body + '\n\n' + delivery.summary(local)
        if updated_body != pr.get('body'):
            gh.request('PATCH', f'/repos/{gh.repository}/pulls/{pr["number"]}', {'body': updated_body})
    return request, snapshot


def normalize_test(class_name, name):
    return class_name.rsplit('/', 1)[-1].rsplit('.', 1)[-1] + '/' + name.removesuffix('()')


class Controller:
    def __init__(self, gh=None, store=None):
        self.gh, self.store = gh or GitHub(), store or Store()

    def save(self, record):
        self.store.update_json(gate_key(record['pr']), lambda old: record, default={})

    def start(self, number, request_id=None):
        gh, store = self.gh, self.store
        pr = gh.get(f'/repos/{gh.repository}/pulls/{number}')
        if pr['state'] != 'open' or pr['draft']:
            return
        old = store.get_json(gate_key(number)) or {}
        if (request_id and old.get('request') == request_id and old.get('head') == pr['head']['sha']
                and old.get('phase') in TERMINAL):
            if not (old.get('phase') == 'complete' and old.get('success')):
                delivery.draft(gh, pr)
            return old
        try:
            request, _ = request_data(store, gh, pr, request_id,
                                      renew=not request_id and old.get('phase') in ('blocked', 'invalidated'))
            old = store.get_json(gate_key(number)) or {}
            if old.get('request') == request['request']:
                # Accepted dispatches are never repeated because a listing or
                # callback has not yet become visible.
                if old.get('phase') not in TERMINAL:
                    return self.poll(old)
                if not old.get('success'):
                    delivery.draft(gh, pr)
                return old
            if old and old.get('phase') not in TERMINAL:
                self.invalidate(old, pr, 'A newer Ready request replaced this gate', redraft=False)
            limit = os.environ.get('AGENT_GATE_MAX_ATTEMPTS', '')
            if not limit.isdecimal() or int(limit) < 1:
                raise RuntimeError('Configure the decided AGENT_GATE_MAX_ATTEMPTS before enabling Ready')
            counter = store.get_json(f'gates/issue-{request["issue"]}.json') or {}
            attempts = max(int(counter.get('attempts', 0)), int(old.get('attempts', 0)))
            if attempts >= int(limit):
                raise RuntimeError('Gate attempt limit reached; leave Draft for Issue instructions')
            selected = backend()
            workflow = cloud_workflow(cloud_client()) if selected == 'xcode-cloud' else None
            record = dict(request, backend=selected, attempts=attempts + 1,
                          phase='starting', startedAt=iso(), dispatched=[])
            store.update_json(f'gates/issue-{request["issue"]}.json',
                              lambda current: {'attempts': attempts + 1, 'lastRequest': request['request'], 'at': iso()}, default={})
            if workflow:
                record['workflow'] = workflow['id']
            self.save(record)
            status(gh, record, 'pending', 'Ready HEAD: external gate starting')
            # The Linux control-plane tests are mandatory for either backend.
            self.dispatch(record, 'agent-tests.yml', {'source_ref': record['head']})
            current = gh.get(f'/repos/{gh.repository}/pulls/{number}')
            if current['head']['sha'] != record['head'] or current['draft']:
                return self.invalidate(record, current, 'HEAD changed before external gate start')
            if selected == 'github':
                self.dispatch(record, 'ios.yml', {'source_ref': record['head'], 'ui_tier': 'pr', 'gate_pr': str(number)})
            else:
                client = cloud_client()
                repository = workflow['relationships']['repository']['data']['id']
                refs = client.paginate(f'/v1/scmRepositories/{repository}/gitReferences?limit=200')
                matches = [ref for ref in refs if ref['attributes'].get('canonicalName') == f'refs/heads/{record["branch"]}'
                           and not ref['attributes'].get('isDeleted')]
                if len(matches) != 1:
                    raise RuntimeError('Could not uniquely resolve the PR branch in Xcode Cloud')
                # ASC accepts a branch reference, not a commit SHA. Verify the
                # sourceCommit SHA in the returned build and again at completion.
                record['cloudSubmittedAt'] = iso()
                self.save(record)
                created = client.request('POST', '/v1/ciBuildRuns', {'data': {'type': 'ciBuildRuns',
                    'attributes': {'clean': False}, 'relationships': {
                        'workflow': {'data': {'type': 'ciWorkflows', 'id': workflow['id']}},
                        'sourceBranchOrTag': {'data': {'type': 'scmGitReferences', 'id': matches[0]['id']}}}}})['data']
                record['cloudRun'] = created['id']
                record['cloudSourceRef'] = matches[0]['id']
                record['url'] = f'https://appstoreconnect.apple.com/teams/apps/{os.environ["APP_STORE_CONNECT_APP_ID"]}/ci/builds/{created["id"]}'
                reported_sha = created.get('attributes', {}).get('sourceCommit', {}).get('commitSha')
                if reported_sha and reported_sha != record['head']:
                    raise RuntimeError('Xcode Cloud started a different sourceCommit SHA')
            record['phase'] = 'waiting'
            self.save(record)
            status(gh, record, 'pending', f'Ready HEAD: waiting for {selected}')
            return record
        except Exception as error:
            # Configuration/API-start errors need instructions, not a repair
            # loop that repeatedly consumes machines without a test failure.
            record = store.get_json(gate_key(number)) or {}
            if record.get('head') != pr['head']['sha']:
                record = {'pr': number, 'issue': issue_for(pr), 'head': pr['head']['sha'],
                          'attempts': record.get('attempts', 0)}
            record.update(phase='blocked', error=str(error), finishedAt=iso())
            self.save(record)
            delivery.draft(gh, pr)
            status(gh, record, 'error', 'Gate start blocked; see Issue instructions')
            if record.get('issue'):
                gh.comment(record['issue'], f'{REPLY_MARKER}\n\n門の起動を停止してDraftに戻しました。\n\n{error}')
            raise

    def dispatch(self, record, workflow, inputs):
        # Intent is durable before the non-idempotent POST. In an ambiguous
        # network failure we stop Draft rather than automatically start twice.
        record['dispatched'].append(workflow)
        self.save(record)
        self.gh.request('POST', f'/repos/{self.gh.repository}/actions/workflows/{workflow}/dispatches',
                        {'ref': 'main', 'inputs': dict(inputs, ci_request=record['request'])})

    def invalidate(self, record, pr, reason, redraft=True):
        record.update(phase='invalidated', error=reason, finishedAt=iso())
        self.save(record)
        if redraft and pr['state'] == 'open' and not pr['draft']:
            delivery.draft(self.gh, pr)
        status(self.gh, record, 'error', reason)
        return record

    def workflow_result(self, workflow, record):
        gh = self.gh
        runs = gh.get(f'/repos/{gh.repository}/actions/workflows/{workflow}/runs?event=workflow_dispatch&per_page=100')['workflow_runs']
        title = ('iOS CI ' if workflow == 'ios.yml' else 'Agent tests CI ') + record['request'] + ' ' + record['head']
        candidates = [run for run in runs if run.get('display_title') == title and run.get('head_branch') == 'main']
        if not candidates:
            return None
        latest = max(candidates, key=lambda run: (run['id'], run.get('run_attempt', 1)))
        # Require main's workflow file, but the job checks out the requested SHA.
        inputs = gh.get(f'/repos/{gh.repository}/actions/runs/{latest["id"]}')
        if not inputs.get('path', '').split('@')[0].endswith(f'/.github/workflows/{workflow}') and inputs.get('path') != f'.github/workflows/{workflow}':
            raise RuntimeError('Gate workflow path differs')
        return latest

    def poll(self, record):
        gh = self.gh
        if record.get('phase') in TERMINAL:
            if record.get('phase') == 'complete' and not record.get('wakeDispatched'):
                self.wake(record)
            return record
        pr = gh.get(f'/repos/{gh.repository}/pulls/{record["pr"]}')
        if pr['state'] != 'open' or pr['draft'] or pr['head']['sha'] != record['head']:
            return self.invalidate(record, pr, 'Ready HEAD changed or Draft/closed; previous result is invalid')
        if record['phase'] == 'starting':
            # A crash in a non-idempotent start cannot safely be retried.
            return self.invalidate(record, pr, 'Interrupted gate start; no duplicate build was started')
        results = {}
        for workflow in record['dispatched']:
            current = self.workflow_result(workflow, record)
            if current:
                results[workflow] = {'id': current['id'], 'attempt': current.get('run_attempt', 1),
                                     'status': current['status'], 'conclusion': current.get('conclusion'), 'url': current['html_url']}
        if record['backend'] == 'xcode-cloud':
            client = cloud_client()
            cloud = client.request('GET', f'/v1/ciBuildRuns/{record["cloudRun"]}?include=workflow')['data']
            attributes = cloud['attributes']
            actual = attributes.get('sourceCommit', {}).get('commitSha')
            if actual and actual != record['head']:
                return self.invalidate(record, pr, 'Xcode Cloud sourceCommit differs from the Ready HEAD')
            workflow = cloud.get('relationships', {}).get('workflow', {}).get('data', {}).get('id')
            if workflow != record['workflow']:
                raise RuntimeError('Xcode Cloud workflow differs')
            done = attributes.get('executionProgress') == 'COMPLETE'
            if done and not actual:
                raise RuntimeError('Completed Cloud build has no sourceCommit SHA')
            results['xcode-cloud'] = {'id': cloud['id'], 'status': 'completed' if done else 'in_progress',
                                      'conclusion': 'success' if attributes.get('completionStatus') == 'SUCCEEDED' else attributes.get('completionStatus'),
                                      'sourceCommit': actual, 'startedAt': attributes.get('startedDate'),
                                      'finishedAt': attributes.get('finishedDate'), 'url': record['url']}
            if done:
                actions = client.paginate(f'/v1/ciBuildRuns/{cloud["id"]}/actions?limit=200')
                tests, issues, action_records = [], [], []
                for action in actions:
                    action_records.append(dict(action['attributes'], id=action['id']))
                    if action['attributes'].get('actionType') == 'TEST':
                        tests.extend(item['attributes'] for item in client.paginate(f'/v1/ciBuildActions/{action["id"]}/testResults?limit=200'))
                    if action['attributes'].get('completionStatus') not in ('SUCCEEDED', 'SKIPPED'):
                        issues.extend(item['attributes'] for item in client.paginate(f'/v1/ciBuildActions/{action["id"]}/issues?limit=200'))
                result = results['xcode-cloud']
                result.update(actions=action_records, tests=tests, issues=issues)
                actual_tests = {normalize_test(test.get('className', ''), test.get('name', '')) for test in tests}
                result['missingTests'] = sorted(set(record['expectedTests']) - actual_tests)
                test_actions = [action for action in action_records if action.get('actionType') == 'TEST']
                if (not tests or result['missingTests'] or not test_actions or any(action.get('completionStatus') != 'SUCCEEDED' for action in test_actions)
                        or any(test.get('status') not in ('SUCCESS', 'SKIPPED') for test in tests)):
                    result['conclusion'] = 'failure'
        record['results'] = results
        required = ['agent-tests.yml', 'ios.yml' if record['backend'] == 'github' else 'xcode-cloud']
        failed = any(results.get(name, {}).get('status') == 'completed' and results[name]['conclusion'] != 'success' for name in required)
        done = all(results.get(name, {}).get('status') == 'completed' for name in required)
        if not failed and not done:
            self.save(record)
            return record
        # Recheck after reading remote results; an old SHA can never complete a new request.
        fresh = gh.get(f'/repos/{gh.repository}/pulls/{record["pr"]}')
        if fresh['head']['sha'] != record['head'] or fresh['draft'] or fresh['state'] != 'open':
            return self.invalidate(record, fresh, 'HEAD changed while collecting gate results')
        record.update(phase='complete', success=not failed, finishedAt=iso())
        self.save(record)
        status(gh, record, 'failure' if failed else 'success', 'External gate failed' if failed else 'Exact Ready HEAD passed local verification and external gate')
        if failed:
            delivery.draft(gh, fresh)
        self.wake(record)
        return record

    def wake(self, record):
        self.gh.request('POST', f'/repos/{self.gh.repository}/actions/workflows/agent.yml/dispatches',
                        {'ref': 'main', 'inputs': {'issue': str(record['issue']), 'automatic_retry': 'true',
                                                 'gate_result': record['request']}})
        record['wakeDispatched'] = True
        self.save(record)

    def reconcile(self):
        # Also recovers a Ready transition whose explicit dispatch was lost.
        errors = []
        def attempt(operation):
            try:
                return operation()
            except Exception as error:
                errors.append(str(error))
                print(f'Gate reconciliation deferred for one PR: {error}')
        def reconcile_pr(pr):
            old = self.store.get_json(gate_key(pr['number'])) or {}
            if old.get('phase') == 'complete' and old.get('head') == pr['head']['sha']:
                # Completion deletes checkpoints; the protected result remains.
                if not old.get('wakeDispatched'):
                    self.wake(old)
            elif old.get('head') != pr['head']['sha'] and old.get('phase') not in TERMINAL and old:
                self.invalidate(old, pr, 'Ready HEAD changed; previous result is invalid')
            else:
                self.start(pr['number'])
        for pr in self.gh.paginate(f'/repos/{self.gh.repository}/pulls?state=open&per_page=100'):
            if issue_for(pr) and not pr['draft']:
                attempt(lambda: reconcile_pr(pr))
        for item in self.store.list('gates/'):
            if re.fullmatch(r'gates/pr-\d+\.json', item['key']):
                record = self.store.get_json(item['key'])
                if record and (record.get('phase') not in TERMINAL or (record.get('phase') == 'complete' and not record.get('wakeDispatched'))):
                    attempt(lambda: self.poll(record))
        if errors:
            raise RuntimeError('Gate reconciliation errors: ' + '; '.join(errors))


def consume_result(number, request_id, gh=None, store=None):
    """Route a gate wake on Linux; only a failed test starts a macOS repair."""
    gh, store = gh or GitHub(), store or Store()
    request = store.get_json(session_key(number, 'gate-request.json')) or {}
    if request.get('request') != request_id:
        return False
    record = store.get_json(gate_key(request['pr'])) or {}
    if record.get('request') != request_id or record.get('phase') != 'complete':
        return False
    pr = gh.get(f'/repos/{gh.repository}/pulls/{request["pr"]}')
    if pr['state'] != 'open' or pr['head']['sha'] != record['head']:
        return False
    state = store.get_json(session_key(number, 'state.json')) or {}
    if state.get('processedGate') == request_id:
        return not record['success'] and bool(state.get('repair')) and state.get('workerStatus') not in ('running', 'waiting-instructions')
    if record['success']:
        if pr['draft']:
            return False
        def completed(current):
            current.update(validatedHead=record['head'], validatedGate=request_id, processedGate=request_id,
                           workerStatus='idle', autoRestarts=0)
            current.pop('repair', None)
            current.pop('validationFailure', None)
            scope = request['scope']
            current['lastCommentId'] = max([int(current.get('lastCommentId') or 0), *scope['includedComments']])
            if scope['includedIssueBody']:
                current['issueBodyProcessed'] = True
            return current
        store.update_json(session_key(number, 'state.json'), completed, default={})
        try:
            checkpoints.clear(store, number, 'gate-passed')
        except Exception as error:
            print(f'Completion cleanup deferred: {type(error).__name__}')
        gh.comment(number, f'{REPLY_MARKER}\n\n全項目の実装、手元検証、門が完了しました。\n\n'
                           f'- HEAD: `{record["head"]}`\n- PR: {pr["html_url"]}\n- 門: {record.get("url") or pr["html_url"]}\n\nマージは人が行います。')
        return False
    components = checkpoints.load_components(store, request['checkpoint'])
    snapshot = json.loads(components['request-snapshot.json'])
    store.put_json(session_key(number, 'repair-request.json'), snapshot)
    repair = dict(request['scope'], head=record['head'], requestSnapshot=True,
                  requestSha256=hashlib.sha256(json.dumps(snapshot, ensure_ascii=False, indent=2).encode()).hexdigest())
    def failed(current):
        current.update(repair=repair, pendingRestartKind='validation', processedGate=request_id,
                       sessionRepair=False, autoRestarts=0, workerStatus='idle',
                       validationFailure={'gate': record['request'], 'head': record['head'], 'results': record['results']})
        return current
    updated = store.update_json(session_key(number, 'state.json'), failed, default={})
    limit = os.environ.get('AGENT_GATE_MAX_ATTEMPTS', '')
    if not limit.isdecimal() or int(limit) < 1 or record['attempts'] >= int(limit):
        store.update_json(session_key(number, 'state.json'), lambda current: dict(current, workerStatus='waiting-instructions'), default={})
        gh.comment(number, f'{REPLY_MARKER}\n\n門が赤になりDraftへ戻しました。門の起動回数が上限に達したため自動修正は開始せず、元の依頼・HEAD・失敗結果を保持しています。次の進め方をIssueで指示してください。\n\nHEAD: `{record["head"]}`')
        return False
    return True


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--pr', type=int)
    parser.add_argument('--request')
    args = parser.parse_args()
    controller = Controller()
    if args.pr:
        controller.start(args.pr, args.request)
    else:
        controller.reconcile()
    append_summary('Ready gate controller reconciled on Linux; no macOS runner was held while waiting.')


if __name__ == '__main__':
    main()
