"""Trusted Linux controller for Ready -> external gate -> Issue worker.

The controller runs code from main in the `control` job of agent.yml (the
store accepts only agent.yml and agent-prototype.yml). The gate records in
the store are bookkeeping: the outcome that completes or repairs an Issue is
the commit status CONTEXT, which only this job can write (the macOS worker
has no statuses: write). GitHub's concurrency serializes controllers; CAS
also protects records against stale administrative writes.
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
import time
import urllib.parse

from agentlib import GitHub, REPLY_MARKER, Store, append_summary, dispatch, gate_config, iso, session_key
import checkpoints
import delivery
from appstoreconnect import from_environment

CONTEXT = 'Struis / Ready gate'
TERMINAL = {'complete', 'invalidated', 'blocked'}
ATTEMPT_PREFIX = 'Gate attempt '
CONTROLLER_LOGIN = 'github-actions[bot]'


class CloudStartRejected(RuntimeError):
    """App Store Connect answered the start with an HTTP 4xx: no build exists."""


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
    selected = gate_config()['backend']
    if selected not in ('xcode-cloud', 'github'):
        raise RuntimeError('gate-config.json backend must be xcode-cloud or github')
    return selected


def max_attempts():
    limit = gate_config()['gateMaxAttempts']
    if not isinstance(limit, int) or limit < 1:
        raise RuntimeError('gate-config.json gateMaxAttempts must be a positive integer')
    return limit


def cloud_url(build_id):
    return f'https://appstoreconnect.apple.com/teams/apps/{gate_config()["appStoreConnectAppId"]}/ci/builds/{build_id}'


def gate_status(gh, head):
    """The newest CONTEXT state written by the controller for this exact SHA."""
    for item in gh.paginate(f'/repos/{gh.repository}/commits/{head}/statuses'):
        if item.get('context') == CONTEXT and (item.get('creator') or {}).get('login') == CONTROLLER_LOGIN:
            return item.get('state')
    return None


def status_attempts(gh, issue, branch):
    """Gate starts recorded as statuses on this Issue's PR commits.

    Statuses cannot be deleted and the worker cannot write them, so the limit
    holds even if the store's counter were reset or a PR recreated.
    """
    owner = gh.repository.split('/')[0]
    query = urllib.parse.urlencode({'head': f'{owner}:{branch}', 'state': 'all'})
    shas = set()
    for pr in gh.paginate(f'/repos/{gh.repository}/pulls?{query}'):
        if issue_for(pr) == issue:
            shas.update(commit['sha'] for commit in gh.paginate(f'/repos/{gh.repository}/pulls/{pr["number"]}/commits'))
    count = 0
    for sha in sorted(shas):
        for item in gh.paginate(f'/repos/{gh.repository}/commits/{sha}/statuses'):
            if (item.get('context') == CONTEXT and (item.get('creator') or {}).get('login') == CONTROLLER_LOGIN
                    and item.get('state') == 'pending' and (item.get('description') or '').startswith(ATTEMPT_PREFIX)):
                count += 1
    return count


def resolve_branch(client, workflow, branch):
    repository = workflow['relationships']['repository']['data']['id']
    refs = client.paginate(f'/v1/scmRepositories/{repository}/gitReferences?limit=200')
    matches = [ref for ref in refs if ref['attributes'].get('canonicalName') == f'refs/heads/{branch}'
               and not ref['attributes'].get('isDeleted')]
    if len(matches) != 1:
        raise RuntimeError(f'Could not uniquely resolve {branch} in Xcode Cloud')
    return matches[0]['id']


def post_build(client, workflow_id, reference):
    try:
        # Never retried: after a 5xx or a lost response the build may exist.
        return client.request('POST', '/v1/ciBuildRuns', {'data': {'type': 'ciBuildRuns',
            'attributes': {'clean': False}, 'relationships': {
                'workflow': {'data': {'type': 'ciWorkflows', 'id': workflow_id}},
                'sourceBranchOrTag': {'data': {'type': 'scmGitReferences', 'id': reference}}}}},
            retry_server_errors=False)['data']
    except RuntimeError as error:
        if re.search(r': HTTP 4\d\d ', str(error)):
            raise CloudStartRejected(str(error)) from None
        raise


def start_cloud_build(record, workflow, save):
    client = cloud_client()
    reference = resolve_branch(client, workflow, record['branch'])
    # ASC accepts a branch reference, not a commit SHA. Verify the
    # sourceCommit SHA in the returned build and again at completion.
    record['cloudSubmittedAt'] = iso()
    save(record)
    created = post_build(client, workflow['id'], reference)
    record['cloudRun'] = created['id']
    record['cloudSourceRef'] = reference
    record['url'] = cloud_url(created['id'])
    reported_sha = created.get('attributes', {}).get('sourceCommit', {}).get('commitSha')
    if reported_sha and reported_sha != record['head']:
        raise RuntimeError('Xcode Cloud started a different sourceCommit SHA')


def cloud_client():
    return from_environment(os.environ['APP_STORE_CONNECT_KEY_PATH'])


def cloud_workflow(client):
    identifier = gate_config()['xcodeCloudPrGateWorkflowId']
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
        parts = checkpoints.load_components(store, checkpoint, (*delivery.EVIDENCE_FILES, 'run.json'))
        run = json.loads(parts['run.json'])
        request = {'schema': 1, 'request': secrets.token_hex(12), 'issue': issue, 'pr': pr['number'],
                   'head': pr['head']['sha'], 'branch': pr['head']['ref'], 'at': iso(), 'checkpoint': checkpoint,
                   'evidence': delivery.frozen_evidence(checkpoint, {name: parts[name] for name in delivery.EVIDENCE_FILES}),
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
    components = delivery.request_evidence(store, request)
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
    request = dict(request, expectedTests=sorted(required), evidence=delivery.frozen_evidence(checkpoint, components))
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
            limit = max_attempts()
            counter = store.get_json(f'gates/issue-{request["issue"]}.json') or {}
            attempts = max(int(counter.get('attempts', 0)), int(old.get('attempts', 0)),
                           status_attempts(gh, request['issue'], request['branch']))
            if attempts >= limit:
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
            status(gh, record, 'pending', f'{ATTEMPT_PREFIX}{attempts + 1}/{limit}: starting {selected}')
            # The Linux control-plane tests are mandatory for either backend.
            self.dispatch(record, 'agent-tests.yml', {'source_ref': record['head']})
            current = gh.get(f'/repos/{gh.repository}/pulls/{number}')
            if current['head']['sha'] != record['head'] or current['draft']:
                return self.invalidate(record, current, 'HEAD changed before external gate start')
            if selected == 'xcode-cloud':
                try:
                    start_cloud_build(record, workflow, self.save)
                except CloudStartRejected as error:
                    # Apple answered without creating a build (for example the
                    # month's compute hours are used up): use the GitHub fallback.
                    record.update(backend='github', cloudStartError=str(error))
                    self.save(record)
                    if record.get('issue'):
                        gh.comment(record['issue'], f'{REPLY_MARKER}\n\nXcode Cloudが門の開始を受け付けなかったため、'
                                                    f'GitHubの予備（ios.yml）で門を流します。\n\n{error}')
            if record['backend'] == 'github':
                self.dispatch(record, 'ios.yml', {'source_ref': record['head'], 'ui_tier': 'pr', 'gate_pr': str(number)})
            record['phase'] = 'waiting'
            self.save(record)
            status(gh, record, 'pending', f'Ready HEAD: waiting for {record["backend"]}')
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
        dispatch(self.gh, 'agent-issue', {'issue': record['issue'], 'automatic_retry': 'true',
                                          'gate_result': record['request']})
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
    # The store record is writable by every agent.yml job; the outcome must
    # also be the controller's commit status on this exact SHA.
    if gate_status(gh, record['head']) != ('success' if record.get('success') else 'failure'):
        print(f'Gate record {request_id} does not match the controller status; ignoring it')
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
            scope = record['scope']
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
    components = delivery.request_evidence(store, record)
    snapshot = json.loads(components['request-snapshot.json'])
    store.put_json(session_key(number, 'repair-request.json'), snapshot)
    repair = dict(record['scope'], head=record['head'], requestSnapshot=True,
                  requestSha256=hashlib.sha256(json.dumps(snapshot, ensure_ascii=False, indent=2).encode()).hexdigest())
    def failed(current):
        current.update(repair=repair, pendingRestartKind='validation', processedGate=request_id,
                       sessionRepair=False, autoRestarts=0, workerStatus='idle',
                       validationFailure={'gate': record['request'], 'head': record['head'], 'results': record['results']})
        return current
    updated = store.update_json(session_key(number, 'state.json'), failed, default={})
    if record['attempts'] >= max_attempts():
        store.update_json(session_key(number, 'state.json'), lambda current: dict(current, workerStatus='waiting-instructions'), default={})
        gh.comment(number, f'{REPLY_MARKER}\n\n門が赤になりDraftへ戻しました。門の起動回数が上限に達したため自動修正は開始せず、元の依頼・HEAD・失敗結果を保持しています。次の進め方をIssueで指示してください。\n\nHEAD: `{record["head"]}`')
        return False
    return True


def waiting_records(store):
    records = []
    for item in store.list('gates/'):
        if re.fullmatch(r'gates/pr-\d+\.json', item['key']):
            record = store.get_json(item['key']) or {}
            if record.get('phase') not in TERMINAL:
                records.append(record)
    return records


def watch(controller, minutes, interval=60, clock=time.monotonic, sleep=time.sleep):
    """Keep polling while a gate is running, so a result does not wait for an event.

    Only this Linux job waits (free on a public repository); no macOS runner is
    held. Each pass is a full reconcile, so a Ready that arrives meanwhile also
    starts promptly. A run that reaches the limit leaves the rest to the next
    event or the hourly reconcile.
    """
    deadline = clock() + minutes * 60
    last_error = None
    while waiting_records(controller.store) and clock() < deadline:
        sleep(interval)
        try:
            controller.reconcile()
            last_error = None
        except Exception as error:
            last_error = error
            print(f'Gate reconcile deferred: {error}', flush=True)
    if last_error:
        raise last_error


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--pr', type=int)
    parser.add_argument('--request')
    parser.add_argument('--watch-minutes', type=float)
    args = parser.parse_args()
    controller = Controller()
    try:
        if args.pr:
            controller.start(args.pr, args.request)
        else:
            controller.reconcile()
    finally:
        minutes = gate_config()['gateWatchMinutes'] if args.watch_minutes is None else args.watch_minutes
        watch(controller, minutes)
    append_summary('Ready gate controller reconciled on Linux; no macOS runner was held while waiting.')


if __name__ == '__main__':
    main()
