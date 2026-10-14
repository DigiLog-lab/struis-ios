#!/usr/bin/env python3
"""Issue agent control for .github/workflows/agent.yml.

Workflow commands: route, prepare, finalize.
Commands for Claude inside a session: decision, attach, prototype-status,
prototype-build, prototypes.
"""
import argparse
import datetime
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
    issue = gh.issue(number)
    label = os.environ.get('AGENT_LABEL', 'agent')
    if issue.get('pull_request') or not has_label(issue, label):
        write_output('run', 'false')
        print(f'Issue #{number} is not an agent issue')
        return
    state = Store().get_json(session_key(number, 'state.json')) or {}
    pending = pending_comments(gh.comments(number), state)
    body_pending = issue_is_pending(issue, state)
    run = bool(pending) or body_pending
    write_output('run', 'true' if run else 'false')
    print(json.dumps({'issue': number, 'pendingComments': [c['id'] for c in pending],
                      'issueBodyPending': body_pending, 'run': run}))


# ---------------------------------------------------------------- prepare ---

def checkout_branch(branch):
    git('fetch', '--prune', 'origin')
    remote = git('ls-remote', '--heads', 'origin', branch)
    if remote:
        git('checkout', '-B', branch, f'origin/{branch}')
        return True
    git('checkout', '-B', branch, 'origin/main')
    return False


def restore_session(store, number, session_id):
    if not session_id:
        return False
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


def restart_interrupted(gh, state, outcome):
    if outcome not in {'cancelled', 'failure'}:
        return None
    count = int(state.get('autoRestarts') or 0)
    if count >= 3:
        return '連続3回の自動再開後も失敗したため、自動再開を停止しました。作業とセッションは保存しています。'
    gh.request('POST', f'/repos/{gh.repository}/actions/workflows/agent.yml/dispatches', {
        'ref': 'main', 'inputs': {'issue': str(state['issue']), 'automatic_retry': 'true'},
    })
    state['autoRestarts'] = count + 1
    state['restartFromRun'] = os.environ.get('RECOVER_RUN_ID') or os.environ.get('GITHUB_RUN_ID')
    return f'保存した作業とセッションから自動再開を予約しました ({count + 1}/3)。'


def session_needs_recovery(state):
    last = state.get('lastRun') or {}
    usage = last.get('turnUsage') or {}
    # Also recognize the zero-work failure recorded by older controller versions.
    return bool(last.get('noOp') or (last.get('success') is False and usage
                and all(usage.get(key) == 0 for key in ('input', 'output', 'cacheRead', 'cacheCreation'))))


def execution_is_noop(report):
    return (report.get('result') or {}).get('num_turns') == 0 and report.get('requests') == 0


def validation_feedback(home):
    """Carry actionable failures to the next runner, without copying command environments."""
    path = home / 'validation.json'
    if not path.exists():
        return None
    report = json.loads(path.read_text())
    if report.get('success'):
        return None
    name = report.get('currentCheck', 'code')
    lines = []
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
    source = os.environ['RECOVER_RUN_ID']
    expected = f'{os.environ.get("GITHUB_SERVER_URL", "https://github.com")}/{gh.repository}/actions/runs/{source}'
    if (state.get('workerRun') != expected or state.get('finalizedRun') == source
            or state.get('restartFromRun') == source
            or str(state.get('workerRunAttempt', '1')) != os.environ.get('RECOVER_RUN_ATTEMPT', '1')):
        print('終了処理済み、再開予約済み、または後続実行が開始済みです。')
        return
    note = restart_interrupted(gh, state, 'cancelled')
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


def recovery_context(gh, number, issue, comments, state):
    """History used when the saved session cannot be restored (spec 4.4)."""
    parts = ['<session-recovery>',
             '保存済みのClaudeセッションを復元できなかったため、新しいセッションで再開しています。',
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


def cmd_prepare(_args):
    number = issue_number()
    home = agent_home()
    gh = GitHub()
    store = Store()
    issue = gh.issue(number)
    state = store.get_json(session_key(number, 'state.json')) or {}
    comments = gh.comments(number)
    pending = pending_comments(comments, state)
    if not pending and not issue_is_pending(issue, state):
        (home / 'run.json').write_text(json.dumps({'skip': True}))
        write_output('skip', 'true')
        print('Nothing new to process')
        return

    branch = state.get('branch') or f'agent/issue-{number}'
    branch_on_origin = checkout_branch(branch)
    checkpoint_restored = restore_workspace(store, number, branch)
    if os.environ.get('AUTOMATIC_RETRY') != 'true':
        state['autoRestarts'] = 0
    state.pop('restartFromRun', None)
    state.pop('finalizedRun', None)
    session_id = state.get('sessionId')
    restored = not session_needs_recovery(state) and restore_session(store, number, session_id)
    recovery = bool(session_id) and not restored
    model = state.get('model') or os.environ.get('AGENT_MODEL') or 'opus'
    prototypes = prototype_summary(store, number)
    (home / 'prototypes.json').write_text(json.dumps(prototypes, ensure_ascii=False, indent=2))
    (home / 'attachments').mkdir(exist_ok=True)
    (home / 'artifacts').mkdir(exist_ok=True)

    # Commits and pushes do not run tests. CI runs after PR creation.
    git('config', '--local', '--unset-all', 'core.hooksPath', check=False)
    tools_dir = Path(__file__).resolve().parent
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
        blocks.append(recovery_context(gh, number, issue, [c for c in comments if c not in pending], state))
    elif not state.get('issueBodyProcessed'):
        blocks.append(f'<issue-body author="{issue["user"]["login"]}" created="{issue["created_at"]}">\n'
                      f'{issue.get("body") or ""}\n</issue-body>')
    blocks.extend(format_comment(comment) for comment in pending)
    if state.get('validationFailure'):
        blocks.append('<validation-failure>\n前回の検証失敗を修正してから、検証と成果提示へ進んでください。\n'
                      + json.dumps(state['validationFailure'], ensure_ascii=False) + '\n</validation-failure>')
    if session_needs_recovery(state):
        blocks.append('前回の復元セッションは0ターンで終了しました。保存済みの作業と上記履歴を引き継ぎ、新規セッションで未処理の依頼を実行してください。')
    prompt = '\n\n'.join(blocks)

    claude_args = ['--model', model, '--exclude-dynamic-system-prompt-sections',
                   '--permission-mode', 'bypassPermissions', '--allow-dangerously-skip-permissions',
                   '--settings', str(settings_path)]
    if os.environ.get('AGENT_EFFORT'):
        claude_args += ['--effort', os.environ['AGENT_EFFORT']]
    if restored:
        claude_args += ['--resume', session_id]

    run = {
        'issue': number, 'branch': branch, 'model': model, 'sessionIdBefore': session_id,
        'restored': restored, 'recovery': recovery, 'includedComments': [c['id'] for c in pending],
        'includedIssueBody': not state.get('issueBodyProcessed'), 'startedAt': iso(now),
        'headBefore': git('rev-parse', 'HEAD'),
        'validationRequired': (git('rev-parse', 'HEAD') != state.get('validatedHead')
                               and git('rev-parse', 'HEAD') != git('rev-parse', 'origin/main')),
    }
    (home / 'run.json').write_text(json.dumps(run, indent=2))
    (home / 'prompt.txt').write_text(prompt)
    state.update({'issue': number, 'branch': branch, 'workerStatus': 'running',
                  'workerRun': run_url(), 'workerStartedAt': iso(now),
                  'workerRunAttempt': os.environ.get('GITHUB_RUN_ATTEMPT', '1')})
    store.put_json(session_key(number, 'state.json'), state)

    import progress
    progress.update(run, '起動中')

    system_prompt = (Path(__file__).resolve().parent / 'system-prompt.md').read_text()
    write_output('skip', 'false')
    write_output('prompt', prompt)
    write_output('claude_args', shlex.join(claude_args))
    write_output('system_prompt', system_prompt)
    print(json.dumps(run, indent=2))


# --------------------------------------------------------------- finalize ---

def cmd_validate(_args):
    report = analyze(load_execution(os.environ.get('CLAUDE_EXECUTION_FILE')))
    if execution_is_noop(report):
        sys.exit('Claude Codeが0ターンで終了しました。作業を実行していないため成果検証を開始しません。')
    run = json.loads((agent_home() / 'run.json').read_text())
    if git('status', '--porcelain'):
        sys.exit('未コミットの変更があります。成果を提示できません。')
    if run.get('validationRequired') or git('rev-parse', 'HEAD') != run['headBefore']:
        git('fetch', 'origin', run['branch'])
        if git('rev-parse', 'FETCH_HEAD') != git('rev-parse', 'HEAD'):
            sys.exit('push済みブランチとHEADが一致しません。成果を提示できません。')
        # Test execution belongs to PR CI, not this session finalizer.


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
        return '検証が失敗・未完了、または検証対象と成果のコードが一致しません'
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
    claude_success = bool(report['result']) and result.get('subtype') == 'success' and not result.get('is_error') and not no_op
    validation_ok = os.environ.get('VALIDATION_OUTCOME') == 'success'
    success = claude_success and validation_ok
    (home / 'progress-stop').touch()
    if not success:
        import progress
        progress.stop_owned_commands()
    try:
        import progress
        progress.update(run, '完了' if success else '失敗・成果提示を停止', finished=True)
    except Exception as error:
        print(f'Progress final update failed: {type(error).__name__}')
    session_bytes = save_session(store, number)
    save_workspace(store, number, run)

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

    state = store.get_json(session_key(number, 'state.json')) or {}
    state.update({'issue': number, 'branch': run['branch'], 'workerStatus': 'idle', 'workerRun': run_url(),
                  'workerFinishedAt': iso(), 'runs': int(state.get('runs') or 0) + 1})
    if report['sessionId']:
        state['sessionId'] = report['sessionId']
    if report['model'] and success:
        state['model'] = report['model']
    if success:
        state['autoRestarts'] = 0
        state.pop('validationFailure', None)
        state.pop('validatedHead', None)
        if run['includedComments']:
            state['lastCommentId'] = max([int(state.get('lastCommentId') or 0), *run['includedComments']])
        if run['includedIssueBody']:
            state['issueBodyProcessed'] = True
    state['decisions'] = (state.get('decisions') or []) + decisions
    state['lastRun'] = {key: usage[key] for key in ('run', 'success', 'restored', 'recovery', 'turnUsage', 'firstRequest')}
    state['lastRun']['noOp'] = no_op
    if not success:
        feedback = validation_feedback(home)
        if feedback:
            state['validationFailure'] = feedback
    store.put_json(session_key(number, 'state.json'), state)

    table = usage_table(report, run, usage)
    try:
        outcome = 'cancelled' if 'cancelled' in (os.environ.get('CLAUDE_OUTCOME'), os.environ.get('VALIDATION_OUTCOME')) else 'failure'
        restart_note = restart_interrupted(gh, state, outcome) if not success else None
    except Exception as error:
        restart_note = f'作業は保存しましたが、自動再開の予約に失敗しました: {type(error).__name__}'
    if restart_note:
        store.put_json(session_key(number, 'state.json'), state)
    if success:
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


def cmd_request_pr(args):
    """Create the PR now so Claude can observe and repair CI in this session."""
    run = json.loads((agent_home() / 'run.json').read_text())
    if git('status', '--porcelain'):
        sys.exit('変更をcommit・pushしてからPRを作成してください。')
    git('fetch', 'origin', run['branch'])
    if git('rev-parse', 'FETCH_HEAD') != git('rev-parse', 'HEAD'):
        sys.exit('push済みブランチとHEADが一致しません。')
    gh = GitHub()
    existing = gh.get(f'/repos/{gh.repository}/pulls?head={gh.repository.split("/")[0]}:{run["branch"]}&base=main&state=open')
    body = Path(args.body_file).read_text()
    if existing:
        pr = gh.request('PATCH', f'/repos/{gh.repository}/pulls/{existing[0]["number"]}',
                        {'title': args.title, 'body': body})[0]
    else:
        pr = gh.request('POST', f'/repos/{gh.repository}/pulls', {
            'title': args.title, 'body': body, 'head': run['branch'], 'base': 'main',
        })[0]
    outbox_append({'type': 'pull-request', 'url': pr['html_url']})
    print(f'Pull Request: {pr["html_url"]}', flush=True)
    # GITHUB_TOKEN-created PRs/pushes do not trigger pull_request workflows.
    # Explicit dispatch works with that token and also covers subsequent repairs.
    for workflow in ('ios.yml', 'agent-tests.yml'):
        gh.request('POST', f'/repos/{gh.repository}/actions/workflows/{workflow}/dispatches',
                   {'ref': run['branch']})
    print('PRのHEADでiOS・Agent tests CIを起動しました。gh run list / gh run watchで結果を確認し、失敗時は修正・push後にrequest-prを再実行してください。')


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
    request_pr = commands.add_parser('request-pr', help='PRを作成・更新してCIを起動する')
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
