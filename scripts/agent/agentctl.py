#!/usr/bin/env python3
"""Issue agent control for .github/workflows/agent.yml.

Workflow commands: route, prepare, finalize.
Commands for Claude inside a session: decision, attach, prototype-status,
prototype-build, prototypes.
"""
import argparse
import datetime
import hashlib
import io
import json
import os
from pathlib import Path
import secrets
import shlex
import re
import shutil
import subprocess
import sys
import tarfile
import time
import urllib.parse

import checkpoints
import delivery

sys.path.insert(0, str(Path(__file__).resolve().parent))
from agentlib import (  # noqa: E402
    GitHub, JST, PROTOTYPE_MARKER, PROTOTYPE_STATES, REPLY_MARKER, STORE_URL, Store, agent_home,
    allowed_author, append_summary, has_label, iso, is_bot, issue_is_pending, pending_comments,
    run_url, session_key, utc_now, write_output)

MAX_COMMENT = 60000
CLAUDE_DIR = Path.home() / '.claude'


def issue_number():
    return int(os.environ['ISSUE_NUMBER'])


def git(*args, check=True):
    workspace = os.environ.get('GITHUB_WORKSPACE', os.getcwd())
    result = subprocess.run(['git', '-C', workspace, *args], capture_output=True, text=True)
    if check and result.returncode:
        raise RuntimeError(f'git {" ".join(args)} failed: {result.stderr.strip()}')
    return result.stdout.strip()


# ------------------------------------------------------------------ route ---

def cmd_route(_args):
    """Decide on a cheap runner whether the macOS worker has anything to do."""
    number = issue_number()
    gh = GitHub()
    if delivery.enabled() and os.environ.get('GATE_RESULT'):
        from gate import consume_result
        run = consume_result(number, os.environ['GATE_RESULT'], gh)
        write_output('run', 'true' if run else 'false')
        return
    issue = gh.issue(number)
    label = os.environ.get('AGENT_LABEL', 'agent')
    if issue.get('pull_request') or not has_label(issue, label):
        write_output('run', 'false')
        print(f'Issue #{number} is not an agent issue')
        return
    store = Store()
    state = store.get_json(session_key(number, 'state.json')) or {}
    if delivery.enabled() and automatic_retry() and delivery.recover_handoff(store, gh, number, state):
        write_output('run', 'false')
        return
    if delivery.enabled() and state.get('workerStatus') in ('waiting-gate', 'waiting-instructions'):
        # New human instructions may supersede a waiting request. An automatic
        # interruption watchdog must never restart merely to wait for the gate.
        if automatic_retry():
            write_output('run', 'false')
            return
    pending = pending_comments(gh.comments(number), state)
    body_pending = issue_is_pending(issue, state)
    # A persisted validation repair is work in itself: the automatic restart must
    # run even when the comment that started the failed run was deleted since.
    repair_pending = automatic_retry() and bool(state.get('repair'))
    checkpoint = store.get_json(session_key(number, 'workspace.json')) if delivery.enabled() and automatic_retry() else None
    checkpoint_pending = bool(checkpoint and checkpoint.get('prefix') and not checkpoint.get('closed'))
    run = bool(pending) or body_pending or repair_pending or checkpoint_pending
    write_output('run', 'true' if run else 'false')
    print(json.dumps({'issue': number, 'pendingComments': [c['id'] for c in pending],
                      'issueBodyPending': body_pending, 'repairPending': repair_pending, 'run': run}))


def automatic_retry():
    return os.environ.get('AUTOMATIC_RETRY') == 'true'


# ---------------------------------------------------------------- prepare ---

def checkout_branch(branch):
    git('fetch', '--prune', 'origin')
    remote = git('ls-remote', '--heads', 'origin', branch)
    if remote:
        git('checkout', '-B', branch, f'origin/{branch}')
        return True
    git('checkout', '-B', branch, 'origin/main')
    return False


def head_descends_from(sha):
    """True when HEAD is `sha` or one of its descendants."""
    workspace = os.environ.get('GITHUB_WORKSPACE', os.getcwd())
    result = subprocess.run(['git', '-C', workspace, 'merge-base', '--is-ancestor', sha, 'HEAD'],
                            capture_output=True, text=True)
    return result.returncode == 0


def repair_scope(run):
    """What a validation repair may touch: the failed run's requests and its pushed HEAD."""
    return {'includedComments': run['includedComments'], 'includedIssueBody': run['includedIssueBody'],
            'head': git('rev-parse', 'HEAD')}


# Written by prepare: the Issue body and the comments the prompt was built from.
# A validation repair replays this text instead of the live Issue, so a request
# edited in place after the failed run cannot change what the repair sees.
REQUEST_SNAPSHOT_FILE = 'request-snapshot.json'
REPAIR_REQUEST_OBJECT = 'repair-request.json'
# The request text as it was supplied to the runs so far (the Issue body and
# every comment, in the version the run that processed it was given). A run
# that resumes its session is not shown the earlier text again - it sits in
# the transcript - so its snapshot takes the earlier text from here, and only
# this run's own requests from the live Issue.
REQUEST_HISTORY_OBJECT = 'request-history.json'


def request_snapshot(issue, comments, run_started):
    """Normalize the request text of a run for the snapshot (spec: repair sees the failed run's text).

    Every Issue field the prompt shows is captured, the title included: a repair
    built from the snapshot must not read a title edited after the failed run.
    """
    return {
        'capturedAt': run_started, 'run': run_url(),
        'issue': {'number': issue.get('number'), 'title': issue.get('title') or '',
                  'author': issue['user']['login'], 'created': issue.get('created_at'), 'body': issue.get('body') or ''},
        'comments': [{'id': c['id'], 'author': c['user']['login'], 'created': c['created_at'],
                      'bot': is_bot(c.get('user')), 'body': c.get('body') or ''} for c in comments],
    }


def resumed_request_snapshot(store, number, issue, live, included_comments, included_issue_body, run_started):
    """Snapshot of a run that resumed its session: earlier text as earlier runs were given it.

    `live` is the current text of the thread up to this run's newest request.
    Entries this run was shown (its own requests, and the Issue body when it is
    processed by this run) come from `live`; the rest comes from the recorded
    history. Text with no record (state older than the record, or a comment
    posted by the agent since) stays live.
    """
    snapshot = request_snapshot(issue, live, run_started)
    record = store.get_json(session_key(number, REQUEST_HISTORY_OBJECT))
    if not snapshot_is_valid(record):
        return snapshot
    earlier = {c['id']: c for c in record['comments'] if isinstance(c, dict) and 'id' in c}
    fresh = set(included_comments)
    # Recorded entries stay even when deleted from GitHub since: the transcript
    # still holds them. Live entries add this run's requests and anything the
    # record does not know (an agent reply posted since).
    merged = {identifier: entry for identifier, entry in earlier.items() if identifier not in fresh}
    merged.update({c['id']: c for c in snapshot['comments'] if c['id'] in fresh or c['id'] not in earlier})
    snapshot['comments'] = [merged[identifier] for identifier in sorted(merged)]
    if not included_issue_body and 'body' in record['issue']:
        snapshot['issue']['body'] = record['issue']['body']
    return snapshot


def record_request_history(store, number, snapshot):
    """Called by finalize once Claude has received the prompt built from `snapshot`.

    Best effort: a lost record makes the next resumed run fall back to the live text.
    """
    try:
        store.put_json(session_key(number, REQUEST_HISTORY_OBJECT), snapshot)
    except Exception as error:
        print(f'依頼本文の履歴の保存に失敗しました(次回は現在の本文を使います): {type(error).__name__}', file=sys.stderr)


def snapshot_digest(snapshot):
    """Hash of the bytes Store.put_json writes, so a loaded object can be checked against the pointer."""
    return hashlib.sha256(json.dumps(snapshot, ensure_ascii=False, indent=2).encode()).hexdigest()


def snapshot_is_valid(snapshot, digest=None):
    return (isinstance(snapshot, dict) and isinstance(snapshot.get('issue'), dict)
            and isinstance(snapshot.get('comments'), list) and not snapshot.get('cleared')
            and (digest is None or snapshot_digest(snapshot) == digest))


def snapshot_comments(snapshot):
    """Snapshot entries in the shape recovery_context expects from the GitHub API."""
    return [{'id': c['id'], 'user': {'login': c['author'], 'type': 'Bot' if c.get('bot') else 'User'},
             'created_at': c['created'], 'body': c['body']} for c in snapshot['comments']]


def attach_request_snapshot(store, number, repair, previous=None):
    """Store prepare's request snapshot next to the repair and point to it from state['repair']."""
    path = agent_home() / REQUEST_SNAPSHOT_FILE
    if not path.exists():
        return repair
    snapshot = json.loads(path.read_text())
    digest = snapshot_digest(snapshot)
    # finalize rewrites the repair validate recorded: the same text is not uploaded twice.
    if not (previous and previous.get('requestSha256') == digest):
        store.put_json(session_key(number, REPAIR_REQUEST_OBJECT), snapshot)
    repair.update({'requestSnapshot': True, 'requestSha256': digest})
    return repair


def load_request_snapshot(store, number, repair):
    """The failed run's request text, or None when the state predates snapshots or the object is gone."""
    if not repair.get('requestSnapshot'):
        return None
    snapshot = store.get_json(session_key(number, REPAIR_REQUEST_OBJECT))
    return snapshot if snapshot_is_valid(snapshot, repair.get('requestSha256')) else None


def clear_request_snapshot(store, number, repair):
    """The store has no delete: an object that is no longer a repair's input is overwritten.

    Called only after state.json without the `repair` pointer is persisted, so a
    run that dies in between leaves a repair that still has its text. Clearing
    is best effort: a lost overwrite keeps a dead object, never breaks state.
    """
    if not (repair and repair.get('requestSnapshot')):
        return
    try:
        store.put_json(session_key(number, REPAIR_REQUEST_OBJECT), {'cleared': True, 'at': iso()})
    except Exception as error:
        print(f'依頼本文の記録の無効化に失敗しました(次回上書きされます): {type(error).__name__}', file=sys.stderr)


def restore_session(store, number, session_id):
    if not session_id:
        return False
    if delivery.enabled():
        return any((CLAUDE_DIR / 'projects').glob(f'*/{session_id}.jsonl'))
    data = store.get(session_key(number, 'claude-projects.tar.gz'))
    if data:
        CLAUDE_DIR.mkdir(parents=True, exist_ok=True)
        with tarfile.open(fileobj=io.BytesIO(data), mode='r:gz') as archive:
            archive.extractall(CLAUDE_DIR, filter='data')
    return any((CLAUDE_DIR / 'projects').glob(f'*/{session_id}.jsonl'))


def save_session(store, number):
    projects = CLAUDE_DIR / 'projects'
    if not projects.is_dir():
        return None
    buffer = io.BytesIO()
    with tarfile.open(fileobj=buffer, mode='w:gz') as archive:
        archive.add(projects, arcname='projects')
    data = buffer.getvalue()
    store.put(session_key(number, 'claude-projects.tar.gz'), data, 'application/gzip')
    return len(data)


def save_workspace(store, number, run):
    """Save unfinished work without publishing an unverified commit."""
    if delivery.enabled():
        return checkpoints.save(store, number, run)
    workspace = Path(os.environ.get('GITHUB_WORKSPACE', os.getcwd()))
    patch = subprocess.check_output(['git', 'diff', '--binary', 'HEAD'], cwd=workspace)
    untracked = subprocess.check_output(['git', 'ls-files', '--others', '--exclude-standard', '-z'], cwd=workspace).split(b'\0')
    head = git('rev-parse', 'HEAD')
    remote_head = git('ls-remote', '--heads', 'origin', run['branch']).split('\t')[0]
    unpublished = remote_head != head and git('rev-list', '--count', 'HEAD', '--not', '--remotes') != '0'
    if not patch and not any(untracked) and not unpublished:
        store.put_json(session_key(number, 'workspace.json'), {'empty': True})
        return
    prefix = session_key(number, f'checkpoints/{os.environ.get("GITHUB_RUN_ID", "local")}-{os.environ.get("GITHUB_RUN_ATTEMPT", "1")}')
    store.put(prefix + '/changes.patch', patch, 'application/octet-stream')
    buffer = io.BytesIO()
    with tarfile.open(fileobj=buffer, mode='w:gz') as archive:
        for name in untracked:
            if name:
                path = Path(os.fsdecode(name))
                archive.add(workspace / path, arcname=str(path), recursive=False)
    store.put(prefix + '/untracked.tar.gz', buffer.getvalue(), 'application/gzip')
    if unpublished:
        bundle = agent_home() / 'workspace.bundle'
        subprocess.run(['git', 'bundle', 'create', str(bundle), 'HEAD'], cwd=workspace, check=True)
        store.upload_file(prefix + '/commits.bundle', bundle, 'application/octet-stream')
    store.put_json(session_key(number, 'workspace.json'), {'head': head, 'remoteHead': remote_head, 'branch': run['branch'], 'prefix': prefix, 'bundle': unpublished})


def restore_workspace(store, number, branch):
    record = store.get_json(session_key(number, 'workspace.json')) or {}
    if delivery.enabled() and record.get('schema') == 2:
        return checkpoints.restore(store, number, branch, restore_session=automatic_retry())
    if record.get('empty') or not record.get('prefix'):
        return
    if record['branch'] != branch:
        raise RuntimeError('保存された作業ブランチが一致しません。チェックポイントを保持して停止します。')
    if record.get('bundle'):
        if git('ls-remote', '--heads', 'origin', branch).split('\t')[0] != record['remoteHead']:
            raise RuntimeError('保存後にremoteが更新されています。チェックポイントを保持して停止します。')
        bundle = agent_home() / 'restore.bundle'
        bundle.write_bytes(store.get(record['prefix'] + '/commits.bundle'))
        git('fetch', str(bundle), 'HEAD')
        git('checkout', '-B', branch, record['head'])
    if git('rev-parse', 'HEAD') != record['head']:
        raise RuntimeError('保存後にブランチが更新されています。チェックポイントを保持して停止します。')
    patch = store.get(record['prefix'] + '/changes.patch')
    if patch:
        subprocess.run(['git', 'apply', '--index', '--binary', '-'], input=patch, check=True,
                       cwd=os.environ.get('GITHUB_WORKSPACE', os.getcwd()))
    archive_bytes = store.get(record['prefix'] + '/untracked.tar.gz')
    if archive_bytes:
        with tarfile.open(fileobj=io.BytesIO(archive_bytes), mode='r:gz') as archive:
            archive.extractall(os.environ.get('GITHUB_WORKSPACE', os.getcwd()), filter='data')
    return True


def restart_interrupted(gh, state, outcome, kind='interrupted'):
    """Schedule an automatic restart.

    kind: 'interrupted' (Claude was cancelled, failed or did nothing; the saved
    session is resumed) or 'validation' (Claude finished normally but the PR CI
    on the pushed HEAD is not green; a new session repairs only that HEAD).
    """
    if outcome not in {'cancelled', 'failure'}:
        return None
    count = int(state.get('autoRestarts') or 0)
    if count >= 3:
        return '連続3回の自動再開後も失敗したため、自動再開を停止しました。作業とセッションは保存しています。'
    gh.request('POST', f'/repos/{gh.repository}/actions/workflows/agent.yml/dispatches', {
        'ref': 'main', 'inputs': {'issue': str(state['issue']), 'automatic_retry': 'true'},
    })
    state['autoRestarts'] = count + 1
    state['restartKind'] = kind
    state.pop('pendingRestartKind', None)  # carried by restartKind from here on
    state['restartFromRun'] = os.environ.get('RECOVER_RUN_ID') or os.environ.get('GITHUB_RUN_ID')
    if kind == 'validation':
        return (f'現在のHEADのPR CIを修正する自動再開を予約しました ({count + 1}/3)。'
                '次の実行は新しいセッションでCIの失敗だけを直し、Issueの次の項目や新しいコメントには着手しません。')
    return f'保存した作業とセッションから自動再開を予約しました ({count + 1}/3)。'


def fallback_restart_kind(state):
    """Kind of an automatic restart whose state names none.

    Restarts dispatched by older controller versions carry no kind and resume
    the saved session, as does a repair whose own session has been saved. A
    repair whose session was never saved (finalize lost the write after the
    dispatch, or the runner was lost before finalize) must not resume the
    pre-repair session: it starts a new session that repairs the HEAD.
    """
    if state.get('repair') and not state.get('sessionRepair'):
        return 'validation'
    return 'interrupted'


def session_needs_recovery(state):
    last = state.get('lastRun') or {}
    usage = last.get('turnUsage') or {}
    # Also recognize the zero-work failure recorded by older controller versions.
    return bool(last.get('noOp') or (last.get('success') is False and usage
                and all(usage.get(key) == 0 for key in ('input', 'output', 'cacheRead', 'cacheCreation'))))


def execution_is_noop(report):
    return (report.get('result') or {}).get('num_turns') == 0 and report.get('requests') == 0


def claude_succeeded(report):
    """Claude Code finished its turn normally (shared by validate and finalize)."""
    result = report.get('result') or {}
    return (bool(report.get('result')) and result.get('subtype') == 'success'
            and not result.get('is_error') and not execution_is_noop(report))


def validation_feedback(home):
    """Carry actionable failures to the next runner, without copying command environments."""
    if delivery.enabled():
        local = delivery.read('local-verification.json')
        if local and not local.get('success'):
            return {'check': local.get('currentCheck'), 'error': local.get('error'), 'run': run_url(),
                    'failures': [line for check in local.get('checks', []) for line in check.get('failures', [])]}
    path = home / 'validation.json'
    if not path.exists():
        return None
    report = json.loads(path.read_text())
    if report.get('success'):
        return None
    name = report.get('currentCheck', 'code')
    lines = [report['error']] if report.get('error') else []
    from prototype import redact
    for log in sorted((home / 'artifacts').glob(f'validation-*/{name}.log'))[-1:]:
        with log.open(errors='replace') as stream:
            for line in stream:
                if re.search(r'\berror:|^Test Case .* failed|^[✘×] Test .* failed|^\*\* .*FAILED', line):
                    lines.append(redact(line.strip())[:1500])
                    lines = lines[-20:]
    return {'check': name, 'failures': lines, 'run': run_url()}


def cmd_recover(_args):
    match = re.fullmatch(r'Issue agent #(\d+)', os.environ.get('RECOVER_TITLE', ''))
    if not match:
        return
    number = int(match[1])
    gh = GitHub()
    store = Store()
    state = store.get_json(session_key(number, 'state.json')) or {}
    if delivery.enabled() and delivery.recover_handoff(store, gh, number, state):
        print('Ready handoff recovered on Linux; no macOS restart is needed')
        return
    if delivery.enabled() and state.get('workerStatus') in ('waiting-gate', 'waiting-instructions'):
        print('External gate is pending; no macOS restart is needed')
        return
    source = os.environ['RECOVER_RUN_ID']
    expected = f'{os.environ.get("GITHUB_SERVER_URL", "https://github.com")}/{gh.repository}/actions/runs/{source}'
    if (state.get('workerRun') != expected or state.get('finalizedRun') == source
            or state.get('restartFromRun') == source
            or str(state.get('workerRunAttempt', '1')) != os.environ.get('RECOVER_RUN_ATTEMPT', '1')):
        print('終了処理済み、再開予約済み、または後続実行が開始済みです。')
        return
    # A validation failure recorded before the runner was lost restarts as a
    # repair of that HEAD, not as a resumed session that could advance the Issue.
    kind = state.pop('pendingRestartKind', None) or fallback_restart_kind(state)
    note = restart_interrupted(gh, state, 'cancelled', kind)
    store.put_json(session_key(number, 'state.json'), state)
    print(note)


def prototype_summary(store, number):
    """Current prototypes of the issue, with the status from the latest event."""
    objects = store.list(f'prototypes/{number}/')
    variants = {}
    for entry in objects:
        parts = entry['key'].split('/')
        if len(parts) == 4 and parts[3] == 'meta.json':
            variants.setdefault(parts[2], {})['meta'] = entry['key']
        elif len(parts) == 5 and parts[3] == 'events':
            variants.setdefault(parts[2], {}).setdefault('events', []).append(entry['key'])
    summary = []
    for variant, keys in sorted(variants.items()):
        meta = store.get_json(keys['meta']) if 'meta' in keys else {'variant': variant}
        status = None
        if keys.get('events'):
            status = store.get_json(sorted(keys['events'])[-1])
        meta['status'] = (status or {}).get('status', meta.get('status', 'draft'))
        meta['statusNote'] = (status or {}).get('note')
        meta['statusAt'] = (status or {}).get('at')
        summary.append(meta)
    return summary


def describe_prototypes(prototypes):
    if not prototypes:
        return 'なし'
    lines = []
    for item in prototypes:
        latest = (item.get('builds') or [{}])[-1]
        lines.append(f"- {item.get('variant')}: {item.get('title', '')} / status={item.get('status')} / "
                     f"bundle={item.get('bundleId', '-')} / branch={item.get('branch', '-')} / "
                     f"latest build={latest.get('buildNumber', '-')} ({latest.get('result', '-')})")
    return '\n'.join(lines)


def format_comment(comment):
    user = comment['user']['login']
    created = comment['created_at']
    return f'<comment id="{comment["id"]}" author="{user}" created="{created}">\n{comment.get("body") or ""}\n</comment>'


SESSION_RECOVERY_REASONS = {
    'unrestorable': '保存済みのClaudeセッションを復元できなかったため、新しいセッションで再開しています。',
    'validation': '前回の実行は正常に終了しましたが、PR CIの検証に失敗したため、新しいセッションで修正作業を行います。',
    'rerun': '前回の実行が失敗した後の再実行のため、新しいセッションで再開しています。',
}


def recovery_context(gh, number, issue, comments, state, reason='unrestorable'):
    """History used when a run starts a new session instead of resuming (spec 4.4)."""
    parts = ['<session-recovery>',
             SESSION_RECOVERY_REASONS[reason],
             '以下はIssueの履歴、記録済みの設計判断、作業ブランチの状態です。これを前提に会話を継続してください。']
    if state.get('decisions'):
        parts.append('記録済みの設計判断:')
        parts.extend(f"- {item['at']}: {item['text']}" for item in state['decisions'])
    parts.append(f'<issue-body author="{issue["user"]["login"]}">\n{issue.get("body") or ""}\n</issue-body>')
    for comment in comments:
        body = (comment.get('body') or '').split('<details><summary>セッション情報')[0]
        role = 'agent' if is_bot(comment.get('user')) else 'user'
        parts.append(f'<history-comment role="{role}" author="{comment["user"]["login"]}" created="{comment["created_at"]}">\n'
                     f'{body.replace(REPLY_MARKER, "").strip()}\n</history-comment>')
    log = git('log', '--oneline', '-20', check=False)
    status = git('status', '--short', check=False)
    parts.append(f'<branch-log>\n{log}\n</branch-log>')
    if status:
        parts.append(f'<branch-status>\n{status}\n</branch-status>')
    parts.append('</session-recovery>')
    return '\n'.join(parts)


def repair_instructions(head, failure, note=None):
    """Prompt for a restart after a validation failure: fix the pushed HEAD's CI, nothing else."""
    if delivery.enabled():
        return '\n'.join(['<gate-repair>',
            f'ReadyのHEAD ({head}) の門が赤でした。元の全項目の実装は済んでいます。この実行では記録された失敗の原因だけを調べ、必要な箇所を修正してください。',
            json.dumps(failure, ensure_ascii=False), *([note] if note else []),
            '追加コメントや未着手の項目には進みません。テストのskip・期待失敗化・判定緩和・修正なしの再実行はしません。',
            '修正をcommit・pushしたら、local-verifyで全単体＋必須E2E＋差分UIを手元でやり直し、readyで門を起動して待たずに終了してください。',
            '</gate-repair>'])
    detail = (json.dumps(failure, ensure_ascii=False) if failure
              else '終了処理の検証(保存状態の確認、またはPR CI)に失敗しました。`git status` と `gh run list --branch <作業ブランチ>` で現在の状態を確認してください。')
    return '\n'.join([
        '<validation-repair>',
        f'前回の実行は正常に終了しましたが、push済みHEAD ({head}) のPR CIが成功していません。この実行の目的は、現在のHEADのPR CIを成功させることだけです。',
        '失敗の記録:',
        detail,
        *([note] if note else []),
        '行うこと:',
        '- 記録と `gh run view <run-id> --log-failed` で失敗したテスト・ビルドの原因を確かめ、このブランチの該当箇所を修正してcommit・pushし、request-prを再実行してCIを起動する。CIが成功するまで確認を続ける。',
        '- 失敗が不安定なテスト(flaky)に見える場合も、原因を確かめて安定させる修正を行う。',
        '禁止すること:',
        '- Issueの次の項目や未着手の作業に進むこと。未処理のコメントがあっても、この実行では扱わない(次の人間による実行に残す)。',
        '- テストをskip・無効化・期待失敗(XCTExpectFailure等)にすること、アサーションを緩めること、修正なしでCIを再実行(Re-run)して通そうとすること。',
        '- CI修正に不要なリファクタリングや機能変更など、作業範囲を広げること。',
        '</validation-repair>',
    ])


def requires_pr_ci(head, state, main_head):
    return head != state.get('validatedHead') and head != main_head


def save_pr_ci(number, record, store):
    """Checkpoint dispatch metadata before finalization or runner termination."""
    (agent_home() / 'pr-ci.json').write_text(json.dumps(record))
    key = session_key(number, 'state.json')
    state = store.get_json(key) or {}
    state['prCI'] = record
    store.put_json(key, state)


def restore_pr_ci(state, branch, head):
    path = agent_home() / 'pr-ci.json'
    record = state.get('prCI')
    if record and record.get('branch') == branch and record.get('head') == head:
        path.write_text(json.dumps(record))
        return record
    path.unlink(missing_ok=True)
    return None


def cmd_prepare(_args):
    number = issue_number()
    home = agent_home()
    gh = GitHub()
    store = Store()
    issue = gh.issue(number)
    state = store.get_json(session_key(number, 'state.json')) or {}
    comments = gh.comments(number)
    pending = pending_comments(comments, state)
    automatic = automatic_retry()
    # Claude finished but the PR CI on the pushed HEAD was not green: repair that
    # HEAD only, also when the repair run itself is interrupted and resumed. The
    # failed run's requests stay in scope so they become processed once CI is
    # green; newer comments are left for the next human-triggered run. The
    # repair is work on its own, even if its comment has been deleted since.
    repair = state.get('repair') if automatic else None
    checkpoint = store.get_json(session_key(number, 'workspace.json')) if delivery.enabled() and automatic else None
    checkpoint_pending = bool(checkpoint and checkpoint.get('prefix') and not checkpoint.get('closed'))
    if not pending and not issue_is_pending(issue, state) and not repair and not checkpoint_pending:
        (home / 'run.json').write_text(json.dumps({'skip': True}))
        write_output('skip', 'true')
        print('Nothing new to process')
        return

    branch = state.get('branch') or f'agent/issue-{number}'
    branch_on_origin = checkout_branch(branch)
    checkpoint_restored = restore_workspace(store, number, branch)
    frozen = delivery.read(REQUEST_SNAPSHOT_FILE) if delivery.enabled() and automatic and checkpoint_restored else None
    if delivery.enabled() and not automatic:
        old_request = store.get_json(session_key(number, 'gate-request.json')) or {}
        if old_request.get('pr'):
            old_pr = gh.get(f'/repos/{gh.repository}/pulls/{old_request["pr"]}')
            if old_pr['state'] == 'open' and not old_pr['draft']:
                delivery.draft(gh, old_pr)
    if delivery.enabled() and checkpoint_restored and automatic:
        pointer = store.get_json(session_key(number, 'workspace.json')) or {}
        if pointer.get('sessionId'):
            if pointer['sessionId'] != state.get('sessionId'):
                state.pop('sessionStale', None)
            state['sessionId'] = pointer['sessionId']
    if repair and repair.get('head') and not head_descends_from(repair['head']):
        # Like a diverged checkpoint: stop before Claude runs and keep the
        # state untouched, so the next human comment starts a normal run.
        message = (f'修正対象のHEAD {repair["head"][:12]} が作業ブランチ {branch} の履歴にありません'
                   f'(現在のHEAD {git("rev-parse", "HEAD")[:12]})。ブランチが書き換えられたため、'
                   'CI修正の自動再開を停止します。状態は保持しています。Issueへコメントすると通常の実行として再開します。')
        gh.comment(number, f'{REPLY_MARKER}\n\n⚠️ {message}\n\n- 実行ログ: {run_url()}')
        raise RuntimeError(message)
    restored_ci = None if delivery.enabled() else restore_pr_ci(state, branch, git('rev-parse', 'HEAD'))
    # A kind recorded by validate but never finalized counts as well; without
    # any kind, fallback_restart_kind decides from the repair and its session.
    pending_kind = state.pop('pendingRestartKind', None)
    restart_kind = (state.pop('restartKind', None) or pending_kind or fallback_restart_kind(state)) if automatic else None
    # A validation failure that validate recorded but finalize never processed
    # (or a repair left behind) is a failed previous run, even though lastRun
    # still describes the earlier turn that finished normally.
    last_failed = ((state.get('lastRun') or {}).get('success') is False
                   or pending_kind == 'validation' or bool(state.get('repair')))
    dropped_repair = None
    if not automatic:
        state['autoRestarts'] = 0
        state.pop('restartKind', None)
        dropped_repair = state.pop('repair', None)  # its snapshot is cleared once this state is saved
    state.pop('restartFromRun', None)
    state.pop('finalizedRun', None)
    session_id = state.get('sessionId')
    # Only an interrupted run resumes its session. A validation repair and a
    # human-triggered rerun after a failure start a new session with the Issue
    # thread as context.
    # A saved session that a previous run deliberately replaced (a repair or a
    # rerun that started a new session, then was lost before finalize saved
    # the replacement) is stale: resuming it would redo or advance work the
    # replacement was meant to start over.
    stale = bool(state.get('sessionStale'))
    resumable = (restart_kind == 'interrupted' if automatic else not last_failed and not delivery.enabled()) and not stale
    restored = resumable and not session_needs_recovery(state) and restore_session(store, number, session_id)
    recovery = not restored and (bool(session_id) or bool(repair))
    if restored:
        state.pop('sessionStale', None)
    elif session_id:
        state['sessionStale'] = True  # cleared by finalize once this run's own session is saved
    snapshot = snapshot_note = None
    if repair:
        # History is the text the failed run saw: its request snapshot when one
        # was stored, so an Issue body or comment edited in place since does
        # not reach the repair. Older state without a snapshot falls back to
        # the live comments up to the failed run's last request, filtered to
        # agent replies and authorized authors.
        carried = set(repair.get('includedComments') or [])
        snapshot = load_request_snapshot(store, number, repair)
        if snapshot:
            issue = dict(issue, body=snapshot['issue']['body'],
                         user={'login': snapshot['issue']['author']}, created_at=snapshot['issue'].get('created'))
            if 'title' in snapshot['issue']:  # absent from snapshots written before the title was captured
                issue['title'] = snapshot['issue']['title']
            history = snapshot_comments(snapshot)
        else:
            newest = max(carried, default=int(state.get('lastCommentId') or 0))
            history = [c for c in comments if c['id'] <= newest and (
                is_bot(c.get('user')) or allowed_author(c['user']['login'], c.get('author_association')))]
            snapshot_note = ('失敗したrun時点の依頼本文の記録がないため、Issue本文とコメントは現在のGitHub上の内容です。'
                             '失敗run以降に編集されている可能性があります。依頼内容の解釈を広げず、CI修正だけを行ってください。')
        pending = []
        included_comments = sorted(carried)
        included_issue_body = bool(repair.get('includedIssueBody'))
    elif frozen:
        issue = dict(issue, body=frozen['issue']['body'], title=frozen['issue']['title'],
                     user={'login': frozen['issue']['author']}, created_at=frozen['issue'].get('created'))
        pending = []
        history = snapshot_comments(frozen)
        saved_run = delivery.read('checkpoint-run.json', {})
        included_comments = saved_run.get('includedComments', [c['id'] for c in history if not is_bot(c.get('user'))])
        included_issue_body = saved_run.get('includedIssueBody', not state.get('issueBodyProcessed'))
    else:
        # History shown to a new session: agent replies and authorized authors
        # only, like the pending requests. An outsider's comment never reaches
        # the prompt, as history or as a request.
        history = [c for c in comments if c not in pending and (
            is_bot(c.get('user')) or allowed_author(c['user']['login'], c.get('author_association')))]
        included_comments = [c['id'] for c in pending]
        included_issue_body = not state.get('issueBodyProcessed')
    reason = 'validation' if repair else 'rerun' if (not automatic and last_failed) or stale else 'unrestorable'
    model = state.get('model') or os.environ.get('AGENT_MODEL') or 'opus'
    prototypes = prototype_summary(store, number)
    (home / 'prototypes.json').write_text(json.dumps(prototypes, ensure_ascii=False, indent=2))
    (home / 'attachments').mkdir(exist_ok=True)
    (home / 'artifacts').mkdir(exist_ok=True)

    # Push restrictions only: neither commit nor push runs tests.
    tools_dir = Path(__file__).resolve().parent
    hooks_dir = home / 'git-hooks'
    hooks_dir.mkdir(exist_ok=True)
    (hooks_dir / 'pre-commit').unlink(missing_ok=True)
    push_hook = hooks_dir / 'pre-push'
    push_hook.write_text(f'#!/bin/sh\nexec {shlex.quote(sys.executable)} {shlex.quote(str(tools_dir / "guard.py"))} push\n')
    push_hook.chmod(0o755)
    git('config', '--local', 'core.hooksPath', str(hooks_dir))
    hook_command = f'{shlex.quote(sys.executable)} {shlex.quote(str(tools_dir / "progress.py"))} hook'
    settings_path = home / 'claude-settings.json'
    settings_path.write_text(json.dumps({'hooks': {
        event: [{'matcher': '', 'hooks': [{'type': 'command', 'command': hook_command, 'timeout': 10}]}]
        for event in ('SessionStart', 'PreToolUse', 'PostToolUse', 'PostToolUseFailure')
    }}))

    now = utc_now()
    native = ('cacheから復元済み' if os.environ.get('NATIVE_CACHE_HIT') == 'true'
              else f"部分復元 ({os.environ['NATIVE_CACHE_KEY']})" if os.environ.get('NATIVE_CACHE_KEY')
              else '未生成 (ビルドには bootstrap が必要)')
    head = git('rev-parse', '--short', 'HEAD')
    environment = [
        '<github-issue-event>',
        f'Repository: {os.environ.get("GITHUB_REPOSITORY")}',
        f'Issue: #{number} {issue["title"]}',
        f'Issue URL: {issue["html_url"]}',
        f'Time: {iso(now)} (JST {now.astimezone(JST).strftime("%Y-%m-%d %H:%M")})',
        f'Run: {run_url()}',
        f'Working branch: {branch} (HEAD {head}; {"origin上に既存" if branch_on_origin else "originにはまだ無い。push時に作成"})',
        f'Native runtime artifacts: {native}',
        f'Session: {"復元 " + session_id if restored else "履歴から再構成した新規セッション" if recovery else "新規"}',
        f'Workspace checkpoint: {"中断時の作業を復元済み。前runnerのバックグラウンド処理は終了しています。" if checkpoint_restored else "なし"}',
        f'Prototypes ({home / "prototypes.json"}):',
        describe_prototypes(prototypes),
        '</github-issue-event>',
    ]
    blocks = ['\n'.join(environment)]
    if recovery:
        blocks.append(recovery_context(gh, number, issue, history, state, reason))
    elif not state.get('issueBodyProcessed'):
        blocks.append(f'<issue-body author="{issue["user"]["login"]}" created="{issue["created_at"]}">\n'
                      f'{issue.get("body") or ""}\n</issue-body>')
    blocks.extend(format_comment(comment) for comment in pending)
    if restored_ci:
        blocks.append('<pending-pr-ci>\n前runnerが起動したPR CIの記録を復元しました。まずworkflowごとの要求識別子（requestsに指定がなければrequest）の実行結果を確認してください。実行中なら待ち、同じHEADのCIを重複起動しないでください。\n'
                      + json.dumps(restored_ci, ensure_ascii=False) + '\n</pending-pr-ci>')
    if repair:
        blocks.append(repair_instructions(head, state.get('validationFailure'), snapshot_note))
    elif state.get('validationFailure'):
        blocks.append('<validation-failure>\n前回の検証失敗を修正してから、検証と成果提示へ進んでください。\n'
                      + json.dumps(state['validationFailure'], ensure_ascii=False) + '\n</validation-failure>')
    if session_needs_recovery(state):
        blocks.append('前回の復元セッションは0ターンで終了しました。保存済みの作業と上記履歴を引き継ぎ、新規セッションで未処理の依頼を実行してください。')
    prompt = '\n\n'.join(blocks)
    # The request text this run was given, for a repair if its CI fails: the
    # Issue body and, up to the newest request in scope, the agent replies and
    # authorized comments (the history a repair shows, plus this run's requests).
    if frozen and not repair:
        captured = frozen
    elif repair and snapshot:
        captured = snapshot  # replayed verbatim: a repair that fails again keeps the same record
    else:
        newest_request = max(included_comments, default=int(state.get('lastCommentId') or 0))
        source = sorted((c for c in (history + pending) if c['id'] <= newest_request and (
            is_bot(c.get('user')) or allowed_author(c['user']['login'], c.get('author_association')))),
                        key=lambda c: c['id'])
        if restored:
            # The resumed transcript holds the earlier text as it was given;
            # this run reads only its own requests from the live Issue.
            captured = resumed_request_snapshot(store, number, issue, source, included_comments,
                                                included_issue_body, iso(now))
        else:
            captured = request_snapshot(issue, source, iso(now))  # the live history is what this run is shown
    (home / REQUEST_SNAPSHOT_FILE).write_text(json.dumps(captured, ensure_ascii=False, indent=2))
    if delivery.enabled():
        items = delivery.initialize_items(captured)
        prompt += '\n\n<work-items>\n全項目を終えてから local-verify → ready の順に実行してください。門は待たずにセッションを終えます。\n' + json.dumps(items, ensure_ascii=False) + '\n</work-items>'

    claude_args = ['--model', model, '--exclude-dynamic-system-prompt-sections',
                   '--permission-mode', 'bypassPermissions', '--allow-dangerously-skip-permissions',
                   '--settings', str(settings_path)]
    if os.environ.get('AGENT_EFFORT'):
        claude_args += ['--effort', os.environ['AGENT_EFFORT']]
    if restored:
        claude_args += ['--resume', session_id]

    run = {
        'issue': number, 'branch': branch, 'model': model, 'sessionIdBefore': session_id,
        'restored': restored, 'recovery': recovery, 'repair': bool(repair),
        'includedComments': included_comments, 'includedIssueBody': included_issue_body, 'startedAt': iso(now),
        # finalize records the snapshot as supplied text once Claude has received
        # it; a replayed repair snapshot is already recorded.
        'recordRequest': not (repair and snapshot),
        'headBefore': git('rev-parse', 'HEAD'),
        'validationRequired': requires_pr_ci(git('rev-parse', 'HEAD'), state, git('rev-parse', 'origin/main')),
    }
    (home / 'run.json').write_text(json.dumps(run, indent=2))
    (home / 'prompt.txt').write_text(prompt)
    state.update({'issue': number, 'branch': branch, 'workerStatus': 'running',
                  'workerRun': run_url(), 'workerStartedAt': iso(now),
                  'workerRunAttempt': os.environ.get('GITHUB_RUN_ATTEMPT', '1')})
    store.put_json(session_key(number, 'state.json'), state)
    if delivery.enabled():
        # A new human instruction deliberately starts a new session/save series.
        pointer, etag = store.get_json_with_etag(session_key(number, 'workspace.json'))
        if pointer and pointer.get('closed'):
            store.put_json(session_key(number, 'workspace.json'), {'schema': 2, 'empty': True}, if_match=etag)
        write_output('derived_cache_prefix', 'agent-derived-v1-' + hashlib.sha256(branch.encode()).hexdigest()[:16] + '-')
        xcode_version = subprocess.check_output(['xcodebuild', '-version'], text=True)
        write_output('xcode_cache_id', hashlib.sha256(xcode_version.encode()).hexdigest()[:12])
    clear_request_snapshot(store, number, dropped_repair)

    import progress
    progress.update(run, '起動中')

    system_prompt = (Path(__file__).resolve().parent / 'system-prompt.md').read_text()
    write_output('skip', 'false')
    write_output('prompt', prompt)
    write_output('claude_args', shlex.join(claude_args))
    write_output('system_prompt', system_prompt)
    print(json.dumps(run, indent=2))


# --------------------------------------------------------------- finalize ---

class CIVerificationFailed(RuntimeError):
    """The pushed HEAD is clean and published, but its PR CI is not green."""


# Written by validate for finalize on the same runner: the failure was the CI
# of a clean, pushed HEAD, so the restart is a repair of that HEAD.
CI_FAILURE_FILE = 'ci-failure.json'


def cmd_validate(_args):
    report = analyze(load_execution(os.environ.get('CLAUDE_EXECUTION_FILE')))
    if execution_is_noop(report):
        sys.exit('Claude Codeが0ターンで終了しました。作業を実行していないため成果検証を開始しません。')
    run = json.loads((agent_home() / 'run.json').read_text())
    try:
        verify_outcome(run)
    except CIVerificationFailed:
        # Claude finished normally and its HEAD is committed and pushed, so only
        # that HEAD's CI is wrong. Record it now: if the runner is lost before
        # finalize, the watchdog must restart as a repair of this HEAD, not
        # resume the session. Unfinished work (uncommitted or unpushed) or a
        # failed Claude execution restarts as interrupted with the original
        # scope instead: a CI-only repair would discard it.
        if claude_succeeded(report):
            (agent_home() / CI_FAILURE_FILE).write_text(json.dumps({'head': git('rev-parse', 'HEAD')}))
            try:
                record_validation_failure(run)
            except Exception as error:
                print(f'検証失敗の記録に失敗しました: {type(error).__name__}', file=sys.stderr)
        raise


def verify_outcome(run):
    if delivery.enabled():
        return delivery.verify_outcome(run)
    if git('status', '--porcelain'):
        sys.exit('未コミットの変更があります。成果を提示できません。')
    if run.get('validationRequired') or git('rev-parse', 'HEAD') != run['headBefore']:
        git('fetch', 'origin', run['branch'])
        if git('rev-parse', 'FETCH_HEAD') != git('rev-parse', 'HEAD'):
            sys.exit('push済みブランチとHEADが一致しません。成果を提示できません。')
    elif not (agent_home() / 'pr-ci.json').exists():
        return
    # Only an explicit CI result raises CIVerificationFailed; an error while
    # asking GitHub for it propagates as an ordinary failure (interrupted restart).
    verify_pr_ci(run, git('rev-parse', 'HEAD'))


def record_validation_failure(run):
    """Persist the repair scope before finalize, which rewrites it with the same values."""
    store = Store()
    key = session_key(run['issue'], 'state.json')
    state = store.get_json(key) or {}
    state['repair'] = attach_request_snapshot(store, run['issue'], repair_scope(run), state.get('repair'))
    state['pendingRestartKind'] = 'validation'
    feedback = validation_feedback(agent_home())
    if feedback:
        state['validationFailure'] = feedback
    # The repair goes first: a runner lost between the two writes then
    # restarts as a repair, which restore_workspace stops on the stale
    # checkpoint, instead of resuming the session against the failing HEAD
    # with the checkpoint already gone.
    store.put_json(key, state)
    # verify_outcome found the tree clean and HEAD pushed: there is nothing to
    # checkpoint. A checkpoint this run restored still describes the pre-run
    # HEAD and would stop the repair in restore_workspace if the runner is lost
    # before finalize saves the workspace.
    store.put_json(session_key(run['issue'], 'workspace.json'), {'empty': True})


PR_CI_WORKFLOWS = {'ios.yml': 'iOS', 'agent-tests.yml': 'Agent tests'}


def ci_request_id(record, workflow):
    return record.get('requests', {}).get(workflow, record['request'])


def find_pr_ci_run(gh, workflow, record):
    """Find this exact request, including a run accepted before checkpointing failed."""
    page = 1
    label = PR_CI_WORKFLOWS[workflow]
    title = f'{label} CI {ci_request_id(record, workflow)}'
    while True:
        query = urllib.parse.urlencode({'event': 'workflow_dispatch', 'branch': record['branch'],
                                        'head_sha': record['head'], 'per_page': 100, 'page': page})
        runs = gh.get(f'/repos/{gh.repository}/actions/workflows/{workflow}/runs?{query}')['workflow_runs']
        matches = [item for item in runs if item['head_sha'] == record['head']
                   and item['head_branch'] == record['branch'] and item['display_title'] == title]
        if matches:
            latest = max(matches, key=lambda item: item['id'])
            current = gh.get(f'/repos/{gh.repository}/actions/runs/{latest["id"]}')
            if (current['head_sha'] != record['head'] or current['head_branch'] != record['branch']
                    or current['display_title'] != title):
                raise RuntimeError('取得したCI実行の要求識別子・ブランチ・HEADが一致しません。')
            return current
        if len(runs) < 100:
            return None
        page += 1


def verify_pr_ci(run, head):
    """Read GitHub conclusions only; never execute or wait for tests here.

    CIVerificationFailed means an explicit result: no dispatch record for this
    HEAD, no run for the expected request, or a run that is not a completed
    success. An error while querying GitHub propagates as it is, so that an
    unreachable API never turns the next run into a CI repair.
    """
    home = agent_home()
    result = {'success': False, 'currentCheck': 'pr-ci', 'checks': []}
    try:
        record_path = home / 'pr-ci.json'
        if not record_path.exists():
            raise CIVerificationFailed('PR CIの起動記録がありません。request-prを実行してください。')
        record = json.loads(record_path.read_text())
        if record['head'] != head or record['branch'] != run['branch']:
            raise CIVerificationFailed('PR CIの対象HEADと成果が一致しません。request-prを再実行してください。')
        gh = GitHub()
        problems = []
        for workflow in PR_CI_WORKFLOWS:
            current = find_pr_ci_run(gh, workflow, record)  # a query failure is not a CI result
            if not current:
                detail = '起動未完了' if workflow not in record.get('dispatched', []) else '起動した実行がまだ見つかりません'
                problems.append(f'{workflow}: {detail}')
                continue
            result['checks'].append({'workflow': workflow, 'id': current['id'],
                                     'attempt': current['run_attempt'], 'url': current['html_url'],
                                     'status': current['status'], 'conclusion': current['conclusion']})
            if (current['head_sha'] != head or current['status'] != 'completed'
                    or current['conclusion'] != 'success'):
                problems.append(f'{workflow}: {current["status"]}/{current["conclusion"]} {current["html_url"]}')
        if problems:
            raise CIVerificationFailed('PR CI未成功: ' + '; '.join(problems))
        result['success'] = True
    except Exception as error:
        result['error'] = str(error)
        raise
    finally:
        (home / 'validation.json').write_text(json.dumps(result, ensure_ascii=False, indent=2))


def load_execution(path):
    if not path or not Path(path).exists():
        return []
    try:
        data = json.loads(Path(path).read_text())
    except json.JSONDecodeError:
        return []
    return data if isinstance(data, list) else []


def usage_numbers(usage):
    usage = usage or {}
    creation = usage.get('cache_creation') or {}
    numbers = {
        'input': usage.get('input_tokens') or 0,
        'output': usage.get('output_tokens') or 0,
        'cacheRead': usage.get('cache_read_input_tokens') or 0,
        'cacheCreation': usage.get('cache_creation_input_tokens') or 0,
        'cacheCreation1h': creation.get('ephemeral_1h_input_tokens') or 0,
        'cacheCreation5m': creation.get('ephemeral_5m_input_tokens') or 0,
    }
    prompt_total = numbers['input'] + numbers['cacheRead'] + numbers['cacheCreation']
    numbers['cacheHitRate'] = round(numbers['cacheRead'] / prompt_total, 4) if prompt_total else None
    return numbers


def analyze(messages):
    init = next((m for m in messages if m.get('type') == 'system' and m.get('subtype') == 'init'), {})
    result = next((m for m in reversed(messages) if m.get('type') == 'result'), None)
    requests = []
    seen = set()
    last_text = ''
    for message in messages:
        if message.get('type') != 'assistant' or message.get('parent_tool_use_id'):
            continue
        body = message.get('message') or {}
        texts = [block.get('text', '') for block in body.get('content') or [] if block.get('type') == 'text']
        if any(text.strip() for text in texts):
            last_text = '\n'.join(texts)
        identifier = body.get('id')
        if identifier and identifier not in seen:
            seen.add(identifier)
            requests.append(body.get('usage') or {})
    return {
        'init': init,
        'result': result,
        'sessionId': (result or {}).get('session_id') or init.get('session_id'),
        'model': init.get('model'),
        'claudeCodeVersion': init.get('claude_code_version'),
        'tools': len(init.get('tools') or []),
        'mcpServers': [server.get('name') for server in init.get('mcp_servers') or []],
        'requests': len(requests),
        'firstRequest': usage_numbers(requests[0]) if requests else None,
        'turnUsage': usage_numbers((result or {}).get('usage')),
        'lastText': last_text,
    }


def read_outbox(home):
    entries = []
    outbox = home / 'outbox.jsonl'
    if outbox.exists():
        for line in outbox.read_text().splitlines():
            if line.strip():
                try:
                    entries.append(json.loads(line))
                except json.JSONDecodeError:
                    pass
    return entries


def upload_attachments(store, entries):
    links = []
    for entry in entries:
        path = Path(entry['path'])
        if not path.is_file():
            continue
        token = secrets.token_urlsafe(24)
        name = ''.join(ch if ch.isalnum() or ch in '._-' else '-' for ch in path.name)
        content_type = {'.png': 'image/png', '.jpg': 'image/jpeg', '.jpeg': 'image/jpeg', '.gif': 'image/gif',
                        '.mp4': 'video/mp4', '.txt': 'text/plain; charset=utf-8', '.log': 'text/plain; charset=utf-8',
                        }.get(path.suffix.lower(), 'application/octet-stream')
        store.upload_file(f'media/{token}/{name}', path, content_type)
        url = f'{STORE_URL}/media/{token}/{name}'
        caption = entry.get('caption') or path.name
        links.append(f'![{caption}]({url})' if content_type.startswith('image/') else f'[{caption}]({url})')
    return links


def record_prototype_events(store, number, entries, source):
    for entry in entries:
        variant = entry['variant']
        event = {'status': entry['status'], 'note': entry.get('note'), 'at': iso(), 'source': source}
        stamp = utc_now().strftime('%Y%m%dT%H%M%S%fZ')
        store.put_json(f'prototypes/{number}/{variant}/events/{stamp}-{source}.json', event)


def fmt(value):
    return f'{value:,}' if isinstance(value, int) else '-' if value is None else str(value)


def usage_table(report, run, usage):
    first = report['firstRequest'] or {}
    turn = report['turnUsage']
    rate = turn.get('cacheHitRate')
    first_rate = first.get('cacheHitRate')
    session_mode = ('復元' if run['restored'] else '履歴から再構成' if run['recovery'] else '新規')
    rows = [
        ('セッション', f"`{report['sessionId'] or '-'}` ({session_mode})"),
        ('モデル', f"`{report['model'] or run['model']}`"),
        ('ブランチ', f"`{run['branch']}`"),
        ('入力トークン', fmt(turn['input'])),
        ('キャッシュ読取', fmt(turn['cacheRead'])),
        ('キャッシュ作成', f"{fmt(turn['cacheCreation'])} (1h: {fmt(turn['cacheCreation1h'])}, 5m: {fmt(turn['cacheCreation5m'])})"),
        ('出力トークン', fmt(turn['output'])),
        ('キャッシュヒット率', '-' if rate is None else f'{rate:.1%}'),
        ('最初の要求', f"読取 {fmt(first.get('cacheRead'))} / 作成 {fmt(first.get('cacheCreation'))} / 入力 {fmt(first.get('input'))}"
                     + ('' if first_rate is None else f' (ヒット率 {first_rate:.1%})')),
        ('API要求数', fmt(report['requests'])),
        ('実行', f"[Actions]({run_url()}) · {fmt(usage.get('numTurns'))} turns · {fmt(usage.get('durationSeconds'))} s"),
    ]
    lines = ['<details><summary>セッション情報</summary>', '', '| 項目 | 値 |', '|---|---|']
    lines.extend(f'| {name} | {value} |' for name, value in rows)
    lines.extend(['', '</details>'])
    return '\n'.join(lines)


def failure_reason(result, claude_success, validation_ok, outcome):
    if result.get('num_turns') == 0:
        return 'Claude Codeが0ターンで終了し、未処理の依頼を実行していません。新規セッションで履歴と作業を引き継ぎます。'
    if not claude_success:
        return (result.get('api_error_status') or result.get('subtype')
                or f'Claude Codeが中断・失敗しました ({outcome or "not run"})。終了後の検証は実行されていません。')
    if not validation_ok:
        return '保存状態の確認、またはPR CIが失敗・未完了です。未処理の依頼は保持して再開します。'
    return 'エージェントの実行に失敗しました'


def cmd_finalize(_args):
    home = agent_home()
    run_file = home / 'run.json'
    if not run_file.exists():
        print('prepare did not run; nothing to finalize')
        return
    run = json.loads(run_file.read_text())
    if run.get('skip'):
        return
    number = run['issue']
    gh = GitHub()
    store = Store()
    messages = load_execution(os.environ.get('CLAUDE_EXECUTION_FILE'))
    report = analyze(messages)
    if not messages:
        started = datetime.datetime.fromisoformat(run['startedAt'].replace('Z', '+00:00')).timestamp()
        sessions = [p for p in (CLAUDE_DIR / 'projects').glob('*/*.jsonl') if p.stat().st_mtime >= started]
        report['sessionId'] = max(sessions, key=lambda p: p.stat().st_mtime).stem if sessions else run.get('sessionIdBefore')
        report['requests'] = None
        report['turnUsage'] = {key: None for key in report['turnUsage']}
    result = report['result'] or {}
    no_op = execution_is_noop(report)
    claude_success = claude_succeeded(report)
    validation_ok = os.environ.get('VALIDATION_OUTCOME') == 'success'
    success = claude_success and validation_ok
    (home / 'progress-stop').touch()
    if not success:
        import progress
        progress.stop_owned_commands()
    try:
        import progress
        progress.update(run, '門を起動して終了' if delivery.enabled() and delivery.waiting(run) else '完了' if success else '失敗・成果提示を停止', finished=True)
    except Exception as error:
        print(f'Progress final update failed: {type(error).__name__}')
    session_bytes = None if delivery.enabled() else save_session(store, number)
    save_workspace(store, number, run)
    # The request text became supplied text only if Claude received the prompt:
    # a run cancelled before that leaves the record as it was.
    if run.get('recordRequest') and messages and (home / REQUEST_SNAPSHOT_FILE).exists():
        record_request_history(store, number, json.loads((home / REQUEST_SNAPSHOT_FILE).read_text()))

    outbox = read_outbox(home)
    pull_requests = [f'Pull Request (CI結果はActionsで確認): {entry["url"]}'
                     for entry in outbox if entry.get('type') == 'pull-request']
    decisions = [{'at': iso(), 'text': entry['text']} for entry in outbox if entry.get('type') == 'decision']
    attachments = upload_attachments(store, [entry for entry in outbox if entry.get('type') == 'attach']) if success else []
    record_prototype_events(store, number, [entry for entry in outbox if entry.get('type') == 'prototype-status'], 'agent')

    usage = {
        'issue': number, 'run': run_url(), 'runAttempt': os.environ.get('GITHUB_RUN_ATTEMPT'),
        'startedAt': run['startedAt'], 'finishedAt': iso(), 'success': success,
        'sessionId': report['sessionId'], 'restored': run['restored'], 'recovery': run['recovery'],
        'model': report['model'], 'claudeCodeVersion': report['claudeCodeVersion'],
        'tools': report['tools'], 'mcpServers': report['mcpServers'], 'requests': report['requests'],
        'numTurns': result.get('num_turns'), 'durationSeconds': round(result['duration_ms'] / 1000) if 'duration_ms' in result else None,
        'totalCostUsd': result.get('total_cost_usd'), 'turnUsage': report['turnUsage'],
        'firstRequest': report['firstRequest'], 'modelUsage': result.get('modelUsage'),
        'sessionArchiveBytes': session_bytes, 'includedComments': run['includedComments'],
    }
    stamp = f"{os.environ.get('GITHUB_RUN_ID', 'local')}-{os.environ.get('GITHUB_RUN_ATTEMPT', '1')}"
    store.put_json(f'usage/{number}/{stamp}.json', usage)

    if delivery.enabled() and delivery.waiting(run):
        # The gate may already have completed while this worker was exiting.
        # CAS only worker bookkeeping; never rewrite the controller's outcome,
        # consumed scope, repair or next-worker state with this old runner.
        request_id = delivery.read('gate-request.json', {}).get('request')
        def handed_off(current):
            if request_id and current.get('gateRequest') != request_id:
                return current
            current.update(workerFinishedAt=iso(), finalizedRun=os.environ.get('GITHUB_RUN_ID'),
                           runs=int(current.get('runs') or 0) + 1,
                           lastRun={**{key: usage[key] for key in ('run', 'success', 'restored', 'recovery', 'turnUsage', 'firstRequest')},
                                    'noOp': no_op})
            current['decisions'] = (current.get('decisions') or []) + decisions
            if not request_id or current.get('processedGate') != request_id:
                current.update(issue=number, branch=run['branch'], workerStatus='waiting-gate', workerRun=run_url())
                if report['sessionId']:
                    current['sessionId'] = report['sessionId']
            return current
        store.update_json(session_key(number, 'state.json'), handed_off, default={})
        gh.comment(number, '\n\n'.join([REPLY_MARKER,
                   'Readyの依頼をLinuxへ引き渡しました。門の結果と完了状態はLinux側で管理し、このmacOS workerは終了します。',
                   *pull_requests, usage_table(report, run, usage)]))
        append_summary(f'Issue #{number}: Ready handed off to Linux; macOS worker released.')
        if not success:
            sys.exit(1)
        return

    state = store.get_json(session_key(number, 'state.json')) or {}
    waiting = delivery.enabled() and delivery.waiting(run)
    paused = delivery.enabled() and delivery.paused(run)
    state.update({'issue': number, 'branch': run['branch'], 'workerStatus': 'waiting-instructions' if paused else 'waiting-gate' if waiting else 'idle', 'workerRun': run_url(),
                  'workerFinishedAt': iso(), 'runs': int(state.get('runs') or 0) + 1})
    if report['sessionId']:
        state['sessionId'] = report['sessionId']
    if report['sessionId'] != run.get('sessionIdBefore'):
        state.pop('sessionStale', None)  # the saved session is this run's own replacement
    # Whether the saved session is the repair's own: an interrupted repair
    # resumes it, a repair whose session was never saved starts a new one.
    state['sessionRepair'] = bool(run.get('repair')) and (
        report['sessionId'] != run.get('sessionIdBefore') or bool(state.get('sessionRepair')))
    if report['model'] and success:
        state['model'] = report['model']
    dropped_repair = None  # its snapshot object is cleared only after the state without it is saved
    if success and not waiting and not paused:
        state['autoRestarts'] = 0
        state.pop('validationFailure', None)
        state.pop('restartKind', None)
        state.pop('pendingRestartKind', None)
        state.pop('sessionStale', None)  # the saved session is the one that just succeeded
        dropped_repair = state.pop('repair', None)
        state['validatedHead'] = git('rev-parse', 'HEAD')
        completed_ci = state.pop('prCI', None)
        if (completed_ci and completed_ci.get('head') == state['validatedHead']
                and completed_ci.get('branch') == run['branch']):
            state['validatedCI'] = completed_ci
        if run['includedComments']:
            state['lastCommentId'] = max([int(state.get('lastCommentId') or 0), *run['includedComments']])
        if run['includedIssueBody']:
            state['issueBodyProcessed'] = True
        if delivery.enabled():
            try:
                checkpoints.clear(store, number, 'conversation-completed')
            except Exception as error:
                print(f'Checkpoint completion cleanup deferred: {type(error).__name__}')
    state['decisions'] = (state.get('decisions') or []) + decisions
    state['lastRun'] = {key: usage[key] for key in ('run', 'success', 'restored', 'recovery', 'turnUsage', 'firstRequest')}
    state['lastRun']['noOp'] = no_op
    if not success:
        feedback = validation_feedback(home)
        if feedback:
            state['validationFailure'] = feedback
    # Claude finished normally but the pushed HEAD did not pass its CI: the next
    # run only repairs that HEAD, keeping the scope of this run until its CI is
    # green. validate already recorded the same scope; rewriting it is harmless.
    # Any other failure (Claude failed, or it left uncommitted or unpushed work)
    # restarts as interrupted with the original scope, so a repair recorded for
    # this run is dropped; one carried into a repair run that got interrupted
    # stays, because that run resumes the repair.
    pending_kind = state.pop('pendingRestartKind', None)
    validation_failed = claude_success and not success and (
        (home / CI_FAILURE_FILE).exists() or pending_kind == 'validation')
    if validation_failed:
        state['repair'] = attach_request_snapshot(store, number, repair_scope(run), state.get('repair'))
        # Saved before the restart is dispatched: if the write that records
        # restartKind after the dispatch is lost, the queued run still finds
        # the kind next to the repair and does not resume the session.
        state['pendingRestartKind'] = 'validation'
    elif not success and not run.get('repair'):
        dropped_repair = state.pop('repair', None)
    store.put_json(session_key(number, 'state.json'), state)
    clear_request_snapshot(store, number, dropped_repair)

    table = usage_table(report, run, usage)
    try:
        outcome = 'cancelled' if 'cancelled' in (os.environ.get('CLAUDE_OUTCOME'), os.environ.get('VALIDATION_OUTCOME')) else 'failure'
        # A repair interrupted before it had a session of its own restarts as a
        # repair too: resuming would load the pre-repair session.
        repair_without_session = bool(state.get('repair')) and not state.get('sessionRepair')
        kind = 'validation' if validation_failed or repair_without_session else 'interrupted'
        restart_note = restart_interrupted(gh, state, outcome, kind) if not success and not waiting and not paused else None
    except Exception as error:
        restart_note = f'作業は保存しましたが、自動再開の予約に失敗しました: {type(error).__name__}'
    if restart_note:
        store.put_json(session_key(number, 'state.json'), state)
    if paused:
        parts = [REPLY_MARKER, '実装と手元検証の記録を保持してDraftのまま停止しました。',
                 delivery.read('delivery-blocked.json')['reason'], *pull_requests, table]
    elif waiting and success:
        parts = [REPLY_MARKER, '全項目の実装と完了前の手元検証が済み、ReadyのHEADで門を起動しました。結果待ちはLinux側で行い、このmacOS workerは終了します。', *pull_requests, table]
    elif success:
        text = (result.get('result') or report['lastText'] or '(応答本文がありません)').strip()
        if len(text) > MAX_COMMENT:
            text = text[:MAX_COMMENT] + '\n\n…(長いため省略しました。全文はActionsの実行ログを参照してください)'
        parts = [REPLY_MARKER, text]
        parts.extend(pull_requests)
        if attachments:
            parts.append('\n'.join(attachments))
        parts.append(table)
    else:
        reason = failure_reason(result, claude_success, validation_ok, os.environ.get('CLAUDE_OUTCOME'))
        detail = (result.get('result') or report['lastText'] or '').strip()[:2000] if validation_ok and not no_op else ''
        parts = [REPLY_MARKER, '⚠️ エージェントの実行に失敗しました。', '',
                 f'- 原因: `{reason}`',
                 f'- 実行ログ: {run_url()}',
                 '- 再実行: このIssueへコメントすると、未処理のコメントと合わせて再実行します。Actionsの「Re-run jobs」でも同じ入力で再実行できます。']
        if detail:
            parts.append(f'\n```\n{detail}\n```')
        if restart_note:
            parts.append(restart_note)
        parts.append(table)
    gh.comment(number, '\n\n'.join(parts))
    state['finalizedRun'] = os.environ.get('GITHUB_RUN_ID')
    store.put_json(session_key(number, 'state.json'), state)

    turn = report['turnUsage']
    append_summary('\n'.join([
        f'### Issue #{number}',
        f"- success: `{success}` / session: `{report['sessionId']}` ({'restored' if run['restored'] else 'recovery' if run['recovery'] else 'new'})",
        f"- model: `{report['model']}` / Claude Code `{report['claudeCodeVersion']}` / tools: {report['tools']}",
        f"- tokens: input {fmt(turn['input'])}, cache read {fmt(turn['cacheRead'])}, cache write {fmt(turn['cacheCreation'])} "
        f"(1h {fmt(turn['cacheCreation1h'])}, 5m {fmt(turn['cacheCreation5m'])}), output {fmt(turn['output'])}",
        f"- cache hit rate: {turn['cacheHitRate']} / first request: {json.dumps(report['firstRequest'])}",
    ]))
    if not success:
        sys.exit(1)


# ------------------------------------------------- commands for Claude ---

def outbox_append(entry):
    with (agent_home() / 'outbox.jsonl').open('a') as stream:
        stream.write(json.dumps(entry, ensure_ascii=False) + '\n')


def cmd_decision(args):
    outbox_append({'type': 'decision', 'text': args.text})
    print('記録しました。ターン終了時にIssueのセッション状態へ保存されます。')


def read_pr_body(path):
    """Preserve an untracked PR draft outside the checkout before cleanliness checks."""
    source = Path(path).resolve()
    body = source.read_text()
    workspace = Path(os.environ.get('GITHUB_WORKSPACE', os.getcwd())).resolve()
    if source.is_relative_to(workspace):
        relative = str(source.relative_to(workspace))
        if not git('ls-files', '--', relative):
            directory = agent_home() / 'pr-bodies'
            directory.mkdir(exist_ok=True)
            destination = directory / f'{secrets.token_hex(8)}.md'
            shutil.move(str(source), destination)
            print(f'PR本文の一時ファイルを保存しました: {destination}', flush=True)
    return body


def cmd_request_pr(args):
    """Create the PR now so Claude can observe and repair CI in this session."""
    run = json.loads((agent_home() / 'run.json').read_text())
    body = read_pr_body(args.body_file)
    if delivery.enabled():
        body += '\n\n' + delivery.MARKER.format(issue=run['issue'])
    if git('status', '--porcelain'):
        sys.exit('変更をcommit・pushしてからPRを作成してください。')
    git('fetch', 'origin', run['branch'])
    if git('rev-parse', 'FETCH_HEAD') != git('rev-parse', 'HEAD'):
        sys.exit('push済みブランチとHEADが一致しません。')
    gh = GitHub()
    existing = gh.get(f'/repos/{gh.repository}/pulls?head={gh.repository.split("/")[0]}:{run["branch"]}&base=main&state=open')
    if existing:
        pr = gh.request('PATCH', f'/repos/{gh.repository}/pulls/{existing[0]["number"]}',
                        {'title': args.title, 'body': body})[0]
    else:
        pr = gh.request('POST', f'/repos/{gh.repository}/pulls', {
            'title': args.title, 'body': body, 'head': run['branch'], 'base': 'main',
            **({'draft': True} if delivery.enabled() else {}),
        })[0]
    outbox_append({'type': 'pull-request', 'url': pr['html_url']})
    print(f'Pull Request: {pr["html_url"]}', flush=True)
    if delivery.enabled():
        if not pr['draft']:
            delivery.draft(gh, pr)
        print('Draft PRを保存しました。全項目完了後に local-verify と ready を実行してください。')
        return
    # GITHUB_TOKEN-created PRs/pushes do not trigger pull_request workflows.
    # Explicit dispatch works with that token and also covers subsequent repairs.
    head = git('rev-parse', 'HEAD')
    store = Store()
    state = store.get_json(session_key(run['issue'], 'state.json')) or {}
    previous = next((record for record in (state.get('prCI'), state.get('validatedCI'))
                     if record and record.get('head') == head and record.get('branch') == run['branch']), None)
    reused = previous is not None
    record = previous if reused else {'head': head, 'branch': run['branch'],
                                     'request': secrets.token_hex(12), 'dispatched': []}
    save_pr_ci(run['issue'], record, store)
    for workflow in PR_CI_WORKFLOWS:
        current = find_pr_ci_run(gh, workflow, record) if reused else None
        if current and (current['status'] != 'completed' or current['conclusion'] == 'success'):
            if workflow not in record['dispatched']:
                record['dispatched'].append(workflow)
            save_pr_ci(run['issue'], record, store)
            print(f'既存CIを使用: {workflow} {current["status"]}/{current["conclusion"]} {current["html_url"]}', flush=True)
            continue
        if not current and workflow in record['dispatched']:
            # GitHub accepted it; an eventually consistent listing is not a reason to dispatch again.
            print(f'既に起動予約済み: {workflow}。GitHubへの反映を待ちます。', flush=True)
            continue
        if current:
            # Retry only the failed/cancelled workflow, preserving the other workflow's request.
            record.setdefault('requests', {})[workflow] = secrets.token_hex(12)
            record['dispatched'] = [name for name in record['dispatched'] if name != workflow]
            save_pr_ci(run['issue'], record, store)
        gh.request('POST', f'/repos/{gh.repository}/actions/workflows/{workflow}/dispatches',
                   {'ref': run['branch'], 'inputs': {'ci_request': ci_request_id(record, workflow)}})
        record['dispatched'].append(workflow)
        save_pr_ci(run['issue'], record, store)
        print(f'CI起動: {workflow} / request={ci_request_id(record, workflow)}', flush=True)
    print('PRのHEADでiOS・Agent tests CIを起動・再利用しました。gh run list / gh run watchで結果を確認し、失敗時は修正・push後にrequest-prを再実行してください。')


def cmd_attach(args):
    source = Path(args.path).resolve()
    if not source.is_file():
        sys.exit(f'{source} がありません')
    destination = agent_home() / 'attachments' / f'{int(time.time() * 1000)}-{source.name}'
    destination.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(source, destination)
    outbox_append({'type': 'attach', 'path': str(destination), 'caption': args.caption})
    print('添付します。ターン終了時の返信に表示されます。')


def cmd_prototype_status(args):
    outbox_append({'type': 'prototype-status', 'variant': args.variant, 'status': args.status, 'note': args.note})
    print(f'Prototype {args.variant} を {args.status} にします(ターン終了時に保存)。')


def cmd_prototypes(_args):
    path = agent_home() / 'prototypes.json'
    print(path.read_text() if path.exists() else '[]')


def cmd_prototype_build(args):
    number = issue_number()
    gh = GitHub()
    repository = os.environ['GITHUB_REPOSITORY']
    branch = args.ref or f'prototype/{number}/{args.variant}'
    if not git('ls-remote', '--heads', 'origin', branch):
        sys.exit(f'origin に {branch} がありません。先に commit して push してください。')
    started = utc_now() - datetime.timedelta(seconds=5)
    gh.request('POST', f'/repos/{repository}/actions/workflows/agent-prototype.yml/dispatches', {
        'ref': 'main',
        'inputs': {'issue': str(number), 'variant': args.variant, 'ref': branch,
                   'title': args.title, 'summary': args.summary or ''},
    })
    run = None
    for _ in range(30):
        runs = gh.get(f'/repos/{repository}/actions/workflows/agent-prototype.yml/runs?event=workflow_dispatch&per_page=20')
        for candidate in runs.get('workflow_runs', []):
            created = datetime.datetime.fromisoformat(candidate['created_at'].replace('Z', '+00:00'))
            if created >= started and candidate.get('display_title') == f'Prototype #{number} {args.variant}':
                run = candidate
                break
        if run:
            break
        time.sleep(5)
    if not run:
        sys.exit('ビルドを起動しましたが、実行を特定できませんでした。gh run list --workflow agent-prototype.yml で確認してください。')
    print(f"Prototype build: {run['html_url']} (run id {run['id']})")
    if not args.wait:
        return
    deadline = time.time() + args.wait_minutes * 60
    while run.get('status') != 'completed':
        if time.time() > deadline:
            print(f"まだビルド中です。完了すると workflow が Issue へ結果を投稿します。"
                  f"続けて待つ場合は `gh run watch {run['id']} --exit-status` をバックグラウンドで実行してください。")
            return
        time.sleep(20)
        run = gh.get(f"/repos/{repository}/actions/runs/{run['id']}")
    print(f"conclusion: {run.get('conclusion')}")
    comments = [c for c in gh.comments(number) if PROTOTYPE_MARKER in (c.get('body') or '')
                and f'prototype={args.variant}' in (c.get('body') or '')]
    if comments:
        print(comments[-1]['body'])
    if run.get('conclusion') != 'success':
        print(f"失敗ログ: gh run view {run['id']} --log-failed")
        sys.exit(1)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest='command', required=True)
    commands.add_parser('route').set_defaults(func=cmd_route)
    commands.add_parser('recover').set_defaults(func=cmd_recover)
    commands.add_parser('prepare').set_defaults(func=cmd_prepare)
    commands.add_parser('finalize').set_defaults(func=cmd_finalize)
    commands.add_parser('validate').set_defaults(func=cmd_validate)
    commands.add_parser('items', help='作業項目と完了記録').set_defaults(func=lambda args: print(json.dumps(delivery.read('work-items.json'), ensure_ascii=False, indent=2)))
    item = commands.add_parser('item-complete', help='項目の完了内容を記録')
    item.add_argument('id')
    item.add_argument('--note', required=True)
    item.set_defaults(func=lambda args: delivery.complete_item(args.id, args.note))
    commands.add_parser('local-verify', help='push済みHEADで全単体＋必須E2E＋差分UIを検証').set_defaults(func=lambda args: delivery.local_verify())
    commands.add_parser('ready', help='手元検証済みHEADをReadyにして門を起動').set_defaults(func=lambda args: delivery.ready())
    request_pr = commands.add_parser('request-pr', help='1つのDraft PRを作成・更新する')
    request_pr.add_argument('--title', required=True)
    request_pr.add_argument('--body-file', required=True)
    request_pr.set_defaults(func=cmd_request_pr)
    decision = commands.add_parser('decision', help='重要な設計判断を記録する')
    decision.add_argument('text')
    decision.set_defaults(func=cmd_decision)
    attach = commands.add_parser('attach', help='スクリーンショット等を返信へ添付する')
    attach.add_argument('path')
    attach.add_argument('--caption')
    attach.set_defaults(func=cmd_attach)
    status = commands.add_parser('prototype-status', help='プロトタイプの状態を変更する')
    status.add_argument('variant')
    status.add_argument('status', choices=PROTOTYPE_STATES)
    status.add_argument('--note')
    status.set_defaults(func=cmd_prototype_status)
    commands.add_parser('prototypes', help='このIssueのプロトタイプ一覧').set_defaults(func=cmd_prototypes)
    build = commands.add_parser('prototype-build', help='Ad Hoc配布用にプロトタイプをビルドする')
    build.add_argument('variant')
    build.add_argument('--title', required=True)
    build.add_argument('--summary')
    build.add_argument('--ref')
    build.add_argument('--wait', action='store_true')
    build.add_argument('--wait-minutes', type=float, default=9,
                       help='Bash ツールの上限(10分)より短く待つ')
    build.set_defaults(func=cmd_prototype_build)
    args = parser.parse_args()
    args.func(args)


if __name__ == '__main__':
    main()
