"""Agent-side work items, exact-HEAD local verification and Ready transition."""
import hashlib
import json
import os
from pathlib import Path
import re
import secrets
import subprocess
import sys
import time

from agentlib import GitHub, Store, agent_home, dispatch, gate_config, iso, session_key
import checkpoints

MARKER = '<!-- struis-agent:issue={issue} -->'
SUMMARY_START = '<!-- struis-agent:local-verification -->'
SUMMARY_END = '<!-- /struis-agent:local-verification -->'
EVIDENCE_FILES = ('local-verification.json', 'request-snapshot.json', 'work-items.json')


def enabled():
    return os.environ.get('AGENT_VALIDATION_MODE') == 'gate'


def read(name, default=None):
    path = agent_home() / name
    return json.loads(path.read_text()) if path.exists() else default


def write(name, value):
    path = agent_home() / name
    temporary = path.with_suffix('.tmp')
    temporary.write_text(json.dumps(value, ensure_ascii=False, indent=2))
    temporary.replace(path)


def git(*args):
    return checkpoints.git(*args).decode().strip()


def clean_pushed(run):
    if git('status', '--porcelain'):
        raise RuntimeError('Commit and push every change before verification/Ready')
    head = git('rev-parse', 'HEAD')
    remote = git('ls-remote', '--heads', 'origin', run['branch']).split('\t')[0]
    if head != remote:
        raise RuntimeError('HEAD differs from the pushed branch')
    return head


def initialize_items(snapshot):
    previous = {item['id']: item for item in (read('work-items.json', {}) or {}).get('items', [])}
    items = []
    sources = [('issue', snapshot['issue']['body'])] + [
        (f'comment-{comment["id"]}', comment['body']) for comment in snapshot['comments'] if not comment.get('bot')]
    for source, text in sources:
        # The complete request remains available in request-snapshot.json.
        # Explicit numbered/checkbox items get their own completion record.
        parts = re.findall(r'^\s*(?:\d+[.)]|[-*]\s+\[[ xX]\])\s+(.+)$', text, re.M)
        for index, part in enumerate(parts or [text.strip() or '(本文なし)'], 1):
            identifier = f'{source}-{index}'
            fingerprint = hashlib.sha256(part.encode()).hexdigest()
            old = previous.get(identifier, {})
            items.append(dict(old, id=identifier, text=part, sha256=fingerprint)
                         if old.get('sha256') == fingerprint else
                         {'id': identifier, 'text': part, 'sha256': fingerprint, 'complete': False})
    result = {'schema': 1, 'items': items}
    write('work-items.json', result)
    return result


def scope_digest(snapshot):
    scope = {'issue': snapshot['issue'], 'comments': snapshot['comments']}
    return hashlib.sha256(json.dumps(scope, sort_keys=True, ensure_ascii=False).encode()).hexdigest()


def complete_item(identifier, note):
    if not note.strip():
        raise RuntimeError('Record what was implemented or answered')
    record = read('work-items.json', {})
    matching = [item for item in record.get('items', []) if item['id'] == identifier]
    if not matching:
        raise RuntimeError(f'Unknown work item: {identifier}')
    matching[0].update(complete=True, note=note, completedAt=iso())
    write('work-items.json', record)
    # A changed completion record requires fresh full local validation.
    (agent_home() / 'local-verification.json').unlink(missing_ok=True)


def items_complete(record=None):
    items = (record if record is not None else read('work-items.json', {})).get('items', [])
    return bool(items) and all(item.get('complete') and item.get('note') for item in items)


def item_digest(record):
    return hashlib.sha256(json.dumps(record, sort_keys=True, ensure_ascii=False).encode()).hexdigest()


def select_ui():
    # Load the selection from the checked-out HEAD, the same rules the gate's ios.yml run uses.
    # No UI test is a valid selection: the local run then executes only the unit tests.
    root = checkpoints.workspace()
    script = '''import json, sys
sys.path.insert(0, "scripts/ci")
import ui_test_plan
changed = ui_test_plan.changed_files("main")
diff = ui_test_plan.project_diff("main") if changed is not None else None
tests, reasons = ui_test_plan.explain(ui_test_plan.discover(), json.loads(ui_test_plan.PLAN.read_text()), changed, diff)
print(json.dumps({"changedFiles": changed, "unitTests": "all", "uiTests": tests, "reasons": reasons}))
'''
    return json.loads(subprocess.check_output([sys.executable, '-c', script], cwd=root, text=True))


def test_rows(tree):
    rows = []
    def visit(node):
        if isinstance(node, list):
            for child in node:
                visit(child)
        elif isinstance(node, dict):
            if node.get('nodeType') == 'Test Case':
                rows.append({'test': node.get('nodeIdentifier') or node.get('name'),
                             'result': node.get('result'), 'duration': node.get('duration')})
            else:
                visit(node.get('testNodes', node.get('children', [])))
    visit(tree)
    return rows


def local_verify():
    from guard import run_check
    run = read('run.json')
    if not items_complete():
        raise RuntimeError('Finish every work item before final local verification')
    head = clean_pushed(run)
    selection = select_ui()
    home = agent_home()
    logs = home / 'artifacts' / f'local-{head[:12]}-{time.time_ns()}'
    logs.mkdir(parents=True)
    derived = os.environ.get('AGENT_DERIVED_DATA', str(home / 'DerivedData'))
    # Signed like the gate (no CODE_SIGNING_ALLOWED=NO): an unsigned run failed ClaudeAppAttestTests
    # (2026-10-22). One build, then one test run for the unit tests and the selected UI tests together;
    # with no UI test selected only -only-testing:striusTests is passed (an empty filter runs everything).
    common = ['-project', 'strius.xcodeproj', '-scheme', 'strius',
              '-destination', os.environ.get('AGENT_TEST_DESTINATION', 'platform=iOS Simulator,name=iPhone 17'),
              '-derivedDataPath', derived, '-parallel-testing-enabled', 'NO',
              'ARCHS=arm64', 'STRUIS_AUTH_REQUIRED=YES']
    timeout = ['-test-timeouts-enabled', 'YES', '-default-test-execution-time-allowance', '180',
               '-maximum-test-execution-time-allowance', '600']
    commands = [
        ('build-for-testing', ['xcodebuild', 'build-for-testing', *common], 1800),
        ('tests', ['xcodebuild', 'test-without-building', *common, *timeout, '-only-testing:striusTests',
                   *[f'-only-testing:striusUITests/{test}' for test in selection['uiTests']],
                   '-resultBundlePath', str(logs / 'tests.xcresult')], 7200),
    ]
    record = {'schema': 1, 'head': head, 'branch': run['branch'], 'success': False,
              'startedAt': iso(), 'selection': selection, 'checks': [],
              'scopeSha256': scope_digest(read('request-snapshot.json')),
              'itemsSha256': item_digest(read('work-items.json'))}
    write('local-verification.json', record)
    try:
        for name, command, allowance in commands:
            record['currentCheck'] = name
            started = time.monotonic()
            log = logs / f'{name}.log'
            print(f'Local verification: {name} ({log})', flush=True)
            environment = {key: value for key, value in os.environ.items() if not any(
                word in key.upper() for word in ('TOKEN', 'PASSWORD', 'PRIVATE_KEY', 'API_KEY', 'APP_KEY', 'CERTIFICATE', 'PROVISION_PROFILE'))}
            with log.open('w') as stream:
                result = run_check(command, stream, allowance, environment)
            check = {'name': name, 'command': command, 'exitCode': result.returncode,
                     'seconds': round(time.monotonic() - started, 2), 'log': str(log)}
            if result.returncode:
                from prototype import redact
                check['failures'] = [redact(line.strip())[:1500] for line in log.read_text(errors='replace').splitlines()
                                     if re.search(r'error:|\bfailed\b|FAILED|timed out', line, re.I)][-20:]
            if name != 'build-for-testing':
                bundle = logs / f'{name}.xcresult'
                if not bundle.exists():
                    raise RuntimeError(f'Missing test result bundle: {bundle}')
                # xcresult preserves actual test names, skipped outcomes and timing.
                raw = subprocess.check_output(['xcrun', 'xcresulttool', 'get', 'test-results', 'tests',
                                               '--format', 'json', '--path', str(bundle)], text=True)
                check['testResults'] = json.loads(raw)
                (logs / f'{name}.json').write_text(raw)
                check['tests'] = test_rows(check['testResults'])
                if not check['tests'] or any(test['result'] not in ('Passed', 'Skipped') for test in check['tests']):
                    raise RuntimeError(f'Empty, failed or expected-failure test results: {name}')
            record['checks'].append(check)
            write('local-verification.json', record)
            if result.returncode:
                raise RuntimeError(f'Local verification failed: {name}')
        if clean_pushed(run) != head:
            raise RuntimeError('HEAD changed during local verification')
        record['success'] = True
    except BaseException as error:
        record['error'] = str(error)
        raise
    finally:
        record['finishedAt'] = iso()
        write('local-verification.json', record)
        (logs / 'local-verification.json').write_text(json.dumps(record, ensure_ascii=False, indent=2))
    # Inside Claude's session claude-code-action removes the OIDC request variables, so the store
    # cannot be written there. Ready saves the same complete checkpoint from the step after the
    # session (request_ready / agentctl validate); the periodic monitor keeps saving meanwhile.
    if oidc_available() and not checkpoints.save(Store(), run['issue'], run):
        raise RuntimeError('Local verification passed, but its complete checkpoint was not published')
    return record


def verified(record, head, snapshot, items):
    return (isinstance(snapshot, dict) and isinstance(items, dict) and isinstance(record, dict)
            and record.get('schema') == 1 and record.get('head') == head
            and record.get('success') is True and items_complete(items)
            and record.get('scopeSha256') == scope_digest(snapshot)
            and record.get('itemsSha256') == item_digest(items)
            and len(record.get('checks', [])) == 2 and all(check.get('exitCode') == 0 for check in record['checks'])
            and {check['name'] for check in record.get('checks', []) if check.get('exitCode') == 0}
            == {'build-for-testing', 'tests'}
            and all(test_rows(check.get('testResults')) and all(test['result'] in ('Passed', 'Skipped')
                    for test in test_rows(check['testResults']))
                    for check in record['checks'] if check['name'] != 'build-for-testing'))


def waiting(run):
    request = read('gate-request.json', {})
    return request.get('head') == git('rev-parse', 'HEAD') and request.get('branch') == run['branch']


def frozen_evidence(checkpoint, components):
    """Keep small exact-byte proofs independent of the rolling workspace saves."""
    if set(components) != set(EVIDENCE_FILES):
        raise RuntimeError('Incomplete Ready evidence')
    for name, data in components.items():
        if checkpoints.digest(data) != checkpoint['components'].get(name):
            raise RuntimeError(f'Ready evidence differs from checkpoint: {name}')
    return {name: data.decode() for name, data in components.items()}


def request_evidence(store, request):
    evidence = request.get('evidence')
    if evidence is None:  # a previously saved request, before proof copying
        components = checkpoints.load_components(store, request['checkpoint'], EVIDENCE_FILES)
    else:
        if not isinstance(evidence, dict) or any(not isinstance(value, str) for value in evidence.values()):
            raise RuntimeError('Invalid Ready evidence')
        components = {name: value.encode() for name, value in evidence.items()}
    frozen_evidence(request['checkpoint'], components)
    return components


def recover_handoff(store, gh, number, state):
    """A lost runner after clearing Draft is reconciled without a macOS restart."""
    if state.get('workerStatus') != 'ready-pending':
        return False
    request = store.get_json(session_key(number, 'gate-request.json')) or {}
    if (not request.get('request') or request['request'] != state.get('gateRequest')
            or request.get('head') != state.get('gateHead') or request.get('issue') != number):
        return False
    pr = gh.get(f'/repos/{gh.repository}/pulls/{request["pr"]}')
    if (pr['state'] != 'open' or pr['draft'] or pr['head']['sha'] != request['head']
            or pr['head']['ref'] != request['branch']):
        return False
    def accepted(current):
        if current.get('gateRequest') == request['request'] and current.get('workerStatus') == 'ready-pending':
            current['workerStatus'] = 'waiting-gate'
        return current
    store.update_json(session_key(number, 'state.json'), accepted, default={})
    return True


def paused(run):
    record = read('delivery-blocked.json', {})
    return record.get('head') == git('rev-parse', 'HEAD') and record.get('branch') == run['branch']


def pause(run, head, reason):
    (agent_home() / 'gate-request.json').unlink(missing_ok=True)
    write('delivery-blocked.json', {'head': head, 'branch': run['branch'], 'reason': reason, 'at': iso()})
    print(f'Draftのまま指示を待ちます: {reason}。セッションを終了し、Issueの返信で必要な指示を伝えてください。')


def verify_outcome(run):
    if git('status', '--porcelain'):
        raise RuntimeError('Uncommitted work remains')
    head = git('rev-parse', 'HEAD')
    if not run.get('validationRequired') and head == run['headBefore'] and not read('gate-request.json'):
        return  # conversation-only request
    clean_pushed(run)
    if not waiting(run) and not paused(run):
        raise RuntimeError('Implementation must pass local-verify and enter Ready before this turn ends')
    if not verified(read('local-verification.json'), head, read('request-snapshot.json'), read('work-items.json')):
        raise RuntimeError('Ready verification record changed')


def draft(gh, pr, value=True):
    field = 'convertPullRequestToDraft' if value else 'markPullRequestReadyForReview'
    response = gh.request('POST', '/graphql', {'query': f'mutation($id:ID!){{{field}(input:{{pullRequestId:$id}}){{pullRequest{{id isDraft}}}}}}',
                                               'variables': {'id': pr['node_id']}})[0]
    if response.get('errors'):
        raise RuntimeError(f'Could not change PR Draft state: {response["errors"]}')
    if response['data'][field]['pullRequest']['isDraft'] is not value:
        raise RuntimeError('GitHub did not apply the requested Draft state')


def summary(record):
    lines = [SUMMARY_START, '### 完了前の手元検証', '', f'- HEAD: `{record["head"]}`',
             f'- 実行: {record["startedAt"]} → {record["finishedAt"]}',
             '- 単体テスト: striusTests 全件',
             f'- UIテスト: 変更が当たった契約の分、{len(record["selection"]["uiTests"])}メソッド（0件もある）',
             '- 結果: 成功。実行名・skip・所要時間はチェックポイントとActions artifactのxcresultに記録。', '']
    lines += [f'- {check["name"]}: exit {check["exitCode"]}, {check["seconds"]}秒' for check in record['checks']]
    for check in record['checks']:
        if check.get('testResults'):
            lines += ['', f'<details><summary>{check["name"]}：実行名・結果・時間</summary>', '', '| テスト | 結果 | 時間 |', '|---|---|---|']
            lines += [f'| `{test["test"]}` | {test["result"]} | {test["duration"] or "—"} |' for test in test_rows(check['testResults'])]
            lines += ['', '</details>']
    lines += ['', '<details><summary>UIテストの選択</summary>', '',
              *[f'- `{name}`' for name in record['selection']['uiTests']], '', '</details>', SUMMARY_END]
    return '\n'.join(lines)


def oidc_available():
    return bool(os.environ.get('ACTIONS_ID_TOKEN_REQUEST_URL') and os.environ.get('ACTIONS_ID_TOKEN_REQUEST_TOKEN'))


READY_REQUEST = 'ready-request.json'


def request_ready():
    """Record Ready for the step after Claude's session, which has OIDC and runs ready().

    claude-code-action strips ACTIONS_ID_TOKEN_REQUEST_* from the Claude session, so the store
    (and with it the gate request) cannot be written from there. This checks everything ready()
    checks locally and leaves the request in the agent home; `agentctl validate` performs it.
    """
    run, record = read('run.json'), read('local-verification.json')
    head = clean_pushed(run)
    if not verified(record, head, read('request-snapshot.json'), read('work-items.json')):
        raise RuntimeError('Ready requires all work items and successful full local verification of this pushed HEAD')
    gh = GitHub()
    prs = gh.get(f'/repos/{gh.repository}/pulls?head={gh.repository.split("/")[0]}:{run["branch"]}&base=main&state=open')
    if len(prs) != 1:
        raise RuntimeError('Create/update one Draft PR with request-pr first')
    if prs[0]['head']['sha'] != head:
        raise RuntimeError('PR HEAD changed')
    request = {'head': head, 'pr': prs[0]['number'], 'at': iso()}
    write(READY_REQUEST, request)
    print(f'Readyの依頼を記録しました(PR #{request["pr"]}、HEAD {head[:12]})。'
          'このセッションを終えると、作業用ジョブがReadyにして門を起動します。門は待たずにセッションを終えてください。')
    return request


def perform_requested_ready(run):
    """Run ready() for a Ready request recorded in Claude's session on the same HEAD (agentctl validate)."""
    request = read(READY_REQUEST)
    if not request or request.get('head') != git('rev-parse', 'HEAD') or waiting(run):
        return None
    return ready()


def ready():
    run, record = read('run.json'), read('local-verification.json')
    head = clean_pushed(run)
    if not verified(record, head, read('request-snapshot.json'), read('work-items.json')):
        raise RuntimeError('Ready requires all work items and successful full local verification of this pushed HEAD')
    gh, store = GitHub(), Store()
    prs = gh.get(f'/repos/{gh.repository}/pulls?head={gh.repository.split("/")[0]}:{run["branch"]}&base=main&state=open')
    if len(prs) != 1:
        raise RuntimeError('Create/update one Draft PR with request-pr first')
    pr = prs[0]
    if pr['head']['sha'] != head:
        raise RuntimeError('PR HEAD changed')
    previous = store.get_json(f'gates/pr-{pr["number"]}.json') or {}
    counter = store.get_json(f'gates/issue-{run["issue"]}.json') or {}
    pending = store.get_json(session_key(run['issue'], 'gate-request.json')) or {}
    proof = checkpoints.digest(json.dumps(record, ensure_ascii=False, indent=2).encode())
    if (not pr['draft'] and pending.get('head') == head and pending.get('pr') == pr['number']
            and pending.get('checkpoint', {}).get('components', {}).get('local-verification.json') == proof
            and previous.get('request') == pending.get('request') and previous.get('phase') in ('starting', 'waiting')):
        write('gate-request.json', pending)
        print('This HEAD already has a pending gate; end this session without waiting')
        return pending
    limit = gate_config()['gateMaxAttempts']
    if max(int(previous.get('attempts', 0)), int(counter.get('attempts', 0))) >= int(limit):
        if not pr['draft']:
            draft(gh, pr)
        return pause(run, head, '門の起動回数が上限に達しました。次の進め方をIssueで指示してください')
    (agent_home() / 'delivery-blocked.json').unlink(missing_ok=True)
    checkpoint = checkpoints.save(store, run['issue'], run)
    if not checkpoint:
        raise RuntimeError('Could not publish the complete checkpoint')
    if (checkpoint['head'] != head or clean_pushed(run) != head
            or checkpoint['components'].get('local-verification.json') != proof
            or not verified(record, head, read('request-snapshot.json'), read('work-items.json'))):
        raise RuntimeError('Workspace or verification changed while publishing the Ready checkpoint')
    request = {'schema': 1, 'request': secrets.token_hex(12), 'issue': run['issue'], 'pr': pr['number'],
               'head': head, 'branch': run['branch'], 'at': iso(), 'checkpoint': checkpoint,
               'evidence': frozen_evidence(checkpoint, {name: (agent_home() / name).read_bytes() for name in EVIDENCE_FILES}),
               'scope': {'includedComments': run['includedComments'], 'includedIssueBody': run['includedIssueBody']}}
    store.put_json(session_key(run['issue'], 'gate-request.json'), request)
    body = re.sub(re.escape(SUMMARY_START) + r'.*?' + re.escape(SUMMARY_END), '', pr.get('body') or '', flags=re.S).strip()
    gh.request('PATCH', f'/repos/{gh.repository}/pulls/{pr["number"]}', {'body': body + '\n\n' + summary(record)})
    # The Ready mutation can fail or the runner can disappear immediately after
    # it. Only a confirmed Ready PR enters waiting-gate; recovery can reconcile
    # the durable intent on Linux without another macOS session.
    store.update_json(session_key(run['issue'], 'state.json'),
                      lambda state: dict(state, gateRequest=request['request'], gateHead=head, workerStatus='ready-pending'), default={})
    if pr['draft']:
        draft(gh, pr, False)
    fresh = gh.get(f'/repos/{gh.repository}/pulls/{pr["number"]}')
    if fresh['head']['sha'] != head or fresh['draft']:
        if not fresh['draft']:
            draft(gh, fresh)
        raise RuntimeError('PR changed during Ready transition')
    write('gate-request.json', request)
    def accepted(state):
        if state.get('gateRequest') == request['request'] and state.get('processedGate') != request['request']:
            state['workerStatus'] = 'waiting-gate'
        return state
    store.update_json(session_key(run['issue'], 'state.json'), accepted, default={})
    try:
        dispatch(gh, 'agent-gate', {'pr': pr['number'], 'request': request['request']})
    except Exception as error:
        # This dispatch only wakes an idempotent Linux controller. A lost
        # response must not redraft an otherwise valid Ready request: its
        # periodic reconciliation recovers the same intent, without a new Mac.
        print(f'Ready: controller dispatch unconfirmed ({type(error).__name__}); Linux reconciliation will recover this request.')
    else:
        print('Ready: gate controller dispatched.')
    print('End this session now; the result wakes this Issue worker.')
    return request
