#!/usr/bin/env python3
"""Issue agent control for .github/workflows/agent.yml.

Workflow commands: route, prepare, finalize.
Commands for Claude inside a session: attach, shot, applog, decision, request-pr,
local-verify, ready, prototype-build, prototype-status, prototypes.

Every run is a new Claude session that is shown the Issue thread. Nothing is
checkpointed and nothing restarts on its own: a run that stops halfway leaves
its pushed commits, and the next comment on the Issue starts again from them.
"""
import argparse
import datetime
import hashlib
import io
import json
import os
from pathlib import Path
import re
import secrets
import shlex
import shutil
import signal
import subprocess
import sys
import tarfile
import time

sys.path.insert(0, str(Path(__file__).resolve().parent))
from agentlib import (  # noqa: E402
    GitHub, JST, PROTOTYPE_MARKER, PROTOTYPE_STATES, REPLY_MARKER, STORE_URL, Store, agent_home,
    allowed_author, append_summary, dispatch, has_label, iso, is_bot, issue_is_pending, pending_comments,
    redact_tree, run_url, session_key, utc_now, write_output)

MAX_COMMENT = 60000
CLAUDE_DIR = Path.home() / '.claude'
PR_MARKER = '<!-- struis-agent:issue={issue} -->'
VERIFY_START = '<!-- struis-agent:local-verification -->'
VERIFY_END = '<!-- /struis-agent:local-verification -->'
APP_LOG_PREDICATE = 'subsystem BEGINSWITH "com.digiloglab"'


def issue_number():
    return int(os.environ['ISSUE_NUMBER'])


def workspace():
    return os.environ.get('GITHUB_WORKSPACE', os.getcwd())


def git(*args, check=True):
    result = subprocess.run(['git', '-C', workspace(), *args], capture_output=True, text=True)
    if check and result.returncode:
        raise RuntimeError(f'git {" ".join(args)} failed: {result.stderr.strip()}')
    return result.stdout.strip()


def read_json(path, default=None):
    path = Path(path)
    return json.loads(path.read_text()) if path.exists() else default


def outbox_append(entry):
    with (agent_home() / 'outbox.jsonl').open('a') as stream:
        stream.write(json.dumps(entry, ensure_ascii=False) + '\n')


def read_outbox(home):
    entries = []
    outbox = home / 'outbox.jsonl'
    if outbox.exists():
        for line in outbox.read_text().splitlines():
            try:
                entries.append(json.loads(line))
            except json.JSONDecodeError:
                pass
    return entries


# ------------------------------------------------------------------ route ---

def has_work(issue, comments, state):
    """Pending human requests, the unprocessed Issue body, or a red verification to fix."""
    pending = pending_comments(comments, state)
    return pending, issue_is_pending(issue, state), state.get('verifyFailure')


def cmd_route(_args):
    """Decide on a cheap runner whether the macOS worker has anything to do."""
    number = issue_number()
    gh = GitHub()
    issue = gh.issue(number)
    label = os.environ.get('AGENT_LABEL', 'agent')
    if issue.get('pull_request') or not has_label(issue, label) or issue.get('state') != 'open':
        write_output('run', 'false')
        print(f'Issue #{number} is not an open agent issue')
        return
    state = Store().get_json(session_key(number, 'state.json')) or {}
    pending, body, failure = has_work(issue, gh.comments(number), state)
    run = bool(pending or body or failure)
    write_output('run', 'true' if run else 'false')
    print(json.dumps({'issue': number, 'pendingComments': [c['id'] for c in pending],
                      'issueBodyPending': body, 'verifyFailure': bool(failure), 'run': run}))


# ---------------------------------------------------------------- prepare ---

PREREQUISITE = re.compile(r'前提[:：]\s*#([1-9]\d*)')


def prerequisite_branch(body):
    """The prerequisite's work branch when the Issue declares `前提: #<n>` and that branch still exists (Issue #81).

    A new work branch starts from it, so the dependent work builds on the prerequisite's PR before it is
    merged. Once the prerequisite is merged its branch is deleted (cleanup) and the work starts from main.
    """
    match = PREREQUISITE.search(body or '')
    if not match:
        return None
    branch = f'agent/issue-{match[1]}'
    return branch if git('ls-remote', '--heads', 'origin', branch) else None


def checkout_branch(branch, start=None):
    git('fetch', '--prune', '--no-tags', 'origin')
    if git('ls-remote', '--heads', 'origin', branch):
        git('checkout', '-B', branch, f'origin/{branch}')
        return True
    git('checkout', '-B', branch, f'origin/{start}' if start else 'origin/main')
    return False


def merge_main():
    """Bring the work branch up to date with main before Claude starts (it is tested as it will merge)."""
    behind = int(git('rev-list', '--count', 'HEAD..origin/main') or 0)
    if not behind:
        return {'status': 'up-to-date'}
    result = subprocess.run(['git', '-C', workspace(), 'merge', '--no-edit', 'origin/main'], capture_output=True, text=True)
    if result.returncode:
        files = git('diff', '--name-only', '--diff-filter=U', check=False).split()
        git('merge', '--abort', check=False)
        return {'status': 'conflict', 'behind': behind, 'files': files}
    return {'status': 'merged', 'behind': behind, 'head': git('rev-parse', 'HEAD')}


def fetch_handoff(number, home):
    """Files the web Claude left for this Issue on handoff/issue-<n> (an orphan branch), unpacked locally."""
    branch = f'handoff/issue-{number}'
    destination = home / 'handoff'
    shutil.rmtree(destination, ignore_errors=True)
    if not git('ls-remote', '--heads', 'origin', branch):
        return None
    git('fetch', '--no-tags', 'origin', f'+refs/heads/{branch}:refs/remotes/origin/{branch}')
    archive = subprocess.run(['git', '-C', workspace(), 'archive', f'origin/{branch}'], capture_output=True, check=True).stdout
    destination.mkdir(parents=True)
    with tarfile.open(fileobj=io.BytesIO(archive)) as tar:
        tar.extractall(destination, filter='data')
    return destination


def prototype_summary(store, number):
    """Current prototypes of the issue, with the status from the latest event."""
    variants = {}
    for entry in store.list(f'prototypes/{number}/'):
        parts = entry['key'].split('/')
        if len(parts) == 4 and parts[3] == 'meta.json':
            variants.setdefault(parts[2], {})['meta'] = entry['key']
        elif len(parts) == 5 and parts[3] == 'events':
            variants.setdefault(parts[2], {}).setdefault('events', []).append(entry['key'])
    summary = []
    for variant, keys in sorted(variants.items()):
        meta = store.get_json(keys['meta']) if 'meta' in keys else {'variant': variant}
        status = store.get_json(sorted(keys['events'])[-1]) if keys.get('events') else None
        meta['status'] = (status or {}).get('status', meta.get('status', 'draft'))
        meta['statusNote'] = (status or {}).get('note')
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


def strip_reply(body):
    return (body or '').split('<details><summary>セッション情報')[0].replace(REPLY_MARKER, '').strip()


def build_prompt(context, issue, history, pending, state, failure):
    """The turn input: environment, the thread so far, the new requests, and what to fix."""
    blocks = [context]
    if state.get('decisions'):
        blocks.append('<decisions>\n' + '\n'.join(f"- {item['at']}: {item['text']}" for item in state['decisions'])
                      + '\n</decisions>')
    if not state.get('issueBodyProcessed'):
        blocks.append(f'<issue-body author="{issue["user"]["login"]}" created="{issue["created_at"]}">\n'
                      f'{issue.get("body") or ""}\n</issue-body>')
    else:
        thread = [f'<issue-body author="{issue["user"]["login"]}" created="{issue["created_at"]}">\n'
                  f'{issue.get("body") or ""}\n</issue-body>']
        for comment in history:
            role = 'agent' if is_bot(comment.get('user')) else 'user'
            thread.append(f'<history-comment role="{role}" author="{comment["user"]["login"]}" '
                          f'created="{comment["created_at"]}">\n{strip_reply(comment.get("body"))}\n</history-comment>')
        blocks.append('<thread>\nこのIssueのこれまでのやり取りです(処理済み)。毎回新しいセッションで始まるため、'
                      'ここから文脈を引き継いでください。\n' + '\n'.join(thread) + '\n</thread>')
    blocks.extend(f'<comment id="{c["id"]}" author="{c["user"]["login"]}" created="{c["created_at"]}">\n'
                  f'{c.get("body") or ""}\n</comment>' for c in pending)
    if failure and failure.get('conflict'):
        blocks.append('<verify-failure>\nmainが進み、レビュー待ちのPRへ取り込むと衝突しました。`main:` の行の指示に従って衝突を解消し、'
                      'commit・push後に local-verify → ready をやり直してください。\n'
                      + json.dumps(failure, ensure_ascii=False) + '\n</verify-failure>')
    elif failure:
        blocks.append('<verify-failure>\nReadyにしたHEADの検証(ios.yml)が赤でした。原因を調べて直し、'
                      'local-verify → ready をやり直してください。テストのskip・期待失敗化・判定の緩和・再実行だけで通すことはしません。\n'
                      + json.dumps(failure, ensure_ascii=False) + '\n</verify-failure>')
    return '\n\n'.join(blocks)


def describe_merge(merge):
    if merge['status'] == 'up-to-date':
        return '最新のmainを含んでいます'
    if merge['status'] == 'merged':
        return f"最新のmain({merge['behind']}コミット)を取り込みました(未push)"
    return (f"最新のmainとの取り込みが衝突したため中止しました。まず `git merge origin/main` で衝突"
            f"({', '.join(merge['files']) or '不明'})を解消し、commit・pushしてから作業してください")


def cmd_prepare(_args):
    number = issue_number()
    home = agent_home()
    gh = GitHub()
    store = Store()
    issue = gh.issue(number)
    state = store.get_json(session_key(number, 'state.json')) or {}
    comments = gh.comments(number)
    pending, body_pending, failure = has_work(issue, comments, state)
    if not (pending or body_pending or failure):
        (home / 'run.json').write_text(json.dumps({'skip': True}))
        write_output('skip', 'true')
        print('Nothing new to process')
        return

    if not git('config', 'user.email', check=False):
        git('config', 'user.name', 'github-actions[bot]')
        git('config', 'user.email', '41898282+github-actions[bot]@users.noreply.github.com')
    branch = state.get('branch') or f'agent/issue-{number}'
    on_origin = checkout_branch(branch, prerequisite_branch(issue.get('body')))
    merge = merge_main()
    handoff = fetch_handoff(number, home)
    history = [c for c in comments if c not in pending and (
        is_bot(c.get('user')) or allowed_author(c['user']['login'], c.get('author_association')))]
    model = state.get('model') or os.environ.get('AGENT_MODEL') or 'opus'
    prototypes = prototype_summary(store, number)
    (home / 'prototypes.json').write_text(json.dumps(prototypes, ensure_ascii=False, indent=2))
    for name in ('attachments', 'artifacts'):
        (home / name).mkdir(exist_ok=True)

    # Push restrictions only (current HEAD, never main); neither commit nor push runs tests.
    tools = Path(__file__).resolve().parent
    hooks = home / 'git-hooks'
    hooks.mkdir(exist_ok=True)
    hook = hooks / 'pre-push'
    hook.write_text(f'#!/bin/sh\nexec {shlex.quote(sys.executable)} {shlex.quote(str(tools / "guard.py"))} push\n')
    hook.chmod(0o755)
    git('config', '--local', 'core.hooksPath', str(hooks))
    hook_command = f'{shlex.quote(sys.executable)} {shlex.quote(str(tools / "progress.py"))} hook'
    settings = home / 'claude-settings.json'
    settings.write_text(json.dumps({'hooks': {
        event: [{'matcher': '', 'hooks': [{'type': 'command', 'command': hook_command, 'timeout': 10}]}]
        for event in ('SessionStart', 'PreToolUse', 'PostToolUse', 'PostToolUseFailure')}}))

    now = utc_now()
    native = ('cacheから復元済み' if os.environ.get('NATIVE_CACHE_HIT') == 'true'
              else f"部分復元 ({os.environ['NATIVE_CACHE_KEY']})" if os.environ.get('NATIVE_CACHE_KEY')
              else '未生成 (ビルドには bootstrap が必要)')
    context = '\n'.join([
        '<github-issue-event>',
        f'Repository: {os.environ.get("GITHUB_REPOSITORY")}',
        f'Issue: #{number} {issue["title"]}',
        f'Issue URL: {issue["html_url"]}',
        f'Time: {iso(now)} (JST {now.astimezone(JST).strftime("%Y-%m-%d %H:%M")})',
        f'Run: {run_url()}',
        f'Working branch: {branch} (HEAD {git("rev-parse", "--short", "HEAD")}; '
        f'{"origin上に既存" if on_origin else "originにはまだ無い。push時に作成"})',
        f'main: {describe_merge(merge)}',
        f'Handoff files: {handoff if handoff else "なし"}',
        f'Native runtime artifacts: {native}',
        f'Prototypes ({home / "prototypes.json"}):',
        describe_prototypes(prototypes),
        '</github-issue-event>',
    ])
    prompt = build_prompt(context, issue, history, pending, state, failure)
    claude_args = ['--model', model, '--exclude-dynamic-system-prompt-sections',
                   '--permission-mode', 'bypassPermissions', '--allow-dangerously-skip-permissions',
                   '--settings', str(settings)]
    if os.environ.get('AGENT_EFFORT'):
        claude_args += ['--effort', os.environ['AGENT_EFFORT']]
    run = {'issue': number, 'branch': branch, 'model': model, 'startedAt': iso(now),
           'includedComments': [c['id'] for c in pending], 'includedIssueBody': body_pending,
           'verifyFailure': failure, 'merge': merge, 'headBefore': git('rev-parse', 'HEAD')}
    (home / 'run.json').write_text(json.dumps(run, ensure_ascii=False, indent=2))
    (home / 'prompt.txt').write_text(prompt)
    # Only this worker's fields: a verification report may have recorded a failure since `state` was read,
    # and it must survive for the next run (this run's prompt was built without it).
    def running(current):
        current.update({'issue': number, 'branch': branch, 'workerStatus': 'running', 'workerRun': run_url(),
                        'workerStartedAt': iso(now)})
        return current
    store.update_json(session_key(number, 'state.json'), running, default={})

    import progress
    progress.update(run, '起動中')
    write_output('derived_cache_prefix', 'agent-derived-v1-' + hashlib.sha256(branch.encode()).hexdigest()[:16] + '-')
    xcode = subprocess.run(['xcodebuild', '-version'], capture_output=True, text=True).stdout if shutil.which('xcodebuild') else ''
    write_output('xcode_cache_id', hashlib.sha256(xcode.encode()).hexdigest()[:12])
    write_output('skip', 'false')
    write_output('prompt', prompt)
    write_output('claude_args', shlex.join(claude_args))
    write_output('system_prompt', (tools / 'system-prompt.md').read_text())
    print(json.dumps(run, ensure_ascii=False, indent=2))


# --------------------------------------------------------------- finalize ---

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
    total = numbers['input'] + numbers['cacheRead'] + numbers['cacheCreation']
    numbers['cacheHitRate'] = round(numbers['cacheRead'] / total, 4) if total else None
    return numbers


def analyze(messages):
    init = next((m for m in messages if m.get('type') == 'system' and m.get('subtype') == 'init'), {})
    result = next((m for m in reversed(messages) if m.get('type') == 'result'), None)
    requests, seen, last_text = [], set(), ''
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
        'result': result,
        'sessionId': (result or {}).get('session_id') or init.get('session_id'),
        'model': init.get('model'),
        'claudeCodeVersion': init.get('claude_code_version'),
        'requests': len(requests),
        'firstRequest': usage_numbers(requests[0]) if requests else None,
        'turnUsage': usage_numbers((result or {}).get('usage')),
        'lastText': last_text,
    }


def claude_succeeded(report):
    result = report.get('result') or {}
    return (bool(report.get('result')) and result.get('subtype') == 'success' and not result.get('is_error')
            and not (result.get('num_turns') == 0 and report.get('requests') == 0))


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


def record_prototype_events(store, number, entries, gh):
    for entry in entries:
        if entry['status'] == 'archived':
            # agent-prototype.yml's archive job frees the slot after any build of it finishes, and records the event.
            dispatch(gh, 'agent-prototype', {'operation': 'archive', 'issue': number, 'variant': entry['variant'],
                                             'summary': entry.get('note') or ''})
            continue
        event = {'status': entry['status'], 'note': entry.get('note'), 'at': iso(), 'source': 'agent'}
        stamp = utc_now().strftime('%Y%m%dT%H%M%S%fZ')
        store.put_json(f'prototypes/{number}/{entry["variant"]}/events/{stamp}-agent.json', event)


def keep_transcript(home, session_id):
    """Copy Claude's own session log next to the run's other records (redacted with them before upload)."""
    if not session_id:
        return None
    for path in (CLAUDE_DIR / 'projects').glob(f'*/{session_id}.jsonl'):
        destination = home / 'artifacts' / f'claude-session-{session_id}.jsonl'
        shutil.copyfile(path, destination)
        return destination
    return None


def fmt(value):
    return f'{value:,}' if isinstance(value, int) else '-' if value is None else str(value)


def usage_table(report, run, result):
    first = report['firstRequest'] or {}
    turn = report['turnUsage']
    rate = turn.get('cacheHitRate')
    duration = round(result['duration_ms'] / 1000) if 'duration_ms' in result else None
    rows = [
        ('セッション', f"`{report['sessionId'] or '-'}`"),
        ('モデル', f"`{report['model'] or run['model']}`"),
        ('ブランチ', f"`{run['branch']}`"),
        ('入力 / キャッシュ読取 / キャッシュ作成 / 出力',
         f"{fmt(turn['input'])} / {fmt(turn['cacheRead'])} / {fmt(turn['cacheCreation'])} / {fmt(turn['output'])}"),
        ('キャッシュヒット率', '-' if rate is None else f'{rate:.1%}'),
        ('最初の要求', f"読取 {fmt(first.get('cacheRead'))} / 作成 {fmt(first.get('cacheCreation'))} / 入力 {fmt(first.get('input'))}"),
        ('API要求数', fmt(report['requests'])),
        ('実行', f"[Actions]({run_url()}) · {fmt(result.get('num_turns'))} turns · {fmt(duration)} s"),
    ]
    lines = ['<details><summary>セッション情報</summary>', '', '| 項目 | 値 |', '|---|---|']
    lines += [f'| {name} | {value} |' for name, value in rows]
    return '\n'.join(lines + ['', '</details>'])


def cmd_finalize(_args):
    """Reply, record, and always redact the run's records before they are uploaded as a public artifact."""
    home = agent_home()
    try:
        finalize(home)
    finally:
        changed = redact_tree(home / 'artifacts') if (home / 'artifacts').is_dir() else 0
        append_summary(f'- artifact files redacted: {changed}')


def finalize(home):
    run = read_json(home / 'run.json')
    if not run or run.get('skip'):
        print('Nothing to finalize')
        return
    number = run['issue']
    gh = GitHub()
    store = Store()
    report = analyze(load_execution(os.environ.get('CLAUDE_EXECUTION_FILE')))
    result = report['result'] or {}
    success = claude_succeeded(report)
    (home / 'progress-stop').touch()
    import progress
    progress.stop_owned_commands()  # a background Simulator log stream, a verification left running
    try:
        progress.update(run, '完了' if success else '失敗', finished=True)
    except Exception as error:
        print(f'Progress final update failed: {type(error).__name__}')

    outbox = read_outbox(home)
    pull_requests = list(dict.fromkeys(f'Pull Request: {entry["url"]}' for entry in outbox if entry.get('type') == 'pull-request'))
    decisions = [{'at': iso(), 'text': entry['text']} for entry in outbox if entry.get('type') == 'decision']
    attachments = upload_attachments(store, [entry for entry in outbox if entry.get('type') == 'attach'])
    record_prototype_events(store, number, [entry for entry in outbox if entry.get('type') == 'prototype-status'], gh)
    keep_transcript(home, report['sessionId'])

    usage = {'issue': number, 'run': run_url(), 'startedAt': run['startedAt'], 'finishedAt': iso(),
             'success': success, 'sessionId': report['sessionId'], 'model': report['model'],
             'claudeCodeVersion': report['claudeCodeVersion'], 'requests': report['requests'],
             'numTurns': result.get('num_turns'), 'totalCostUsd': result.get('total_cost_usd'),
             'turnUsage': report['turnUsage'], 'firstRequest': report['firstRequest'],
             'modelUsage': result.get('modelUsage'), 'includedComments': run['includedComments']}
    stamp = f"{os.environ.get('GITHUB_RUN_ID', 'local')}-{os.environ.get('GITHUB_RUN_ATTEMPT', '1')}"
    store.put_json(f'usage/{number}/{stamp}.json', usage)

    def change(state):
        state.update({'issue': number, 'branch': run['branch'], 'workerStatus': 'idle', 'workerRun': run_url(),
                      'workerFinishedAt': iso(), 'runs': int(state.get('runs') or 0) + 1,
                      'decisions': (state.get('decisions') or []) + decisions})
        if success:
            # A failed run leaves its requests pending: the next comment runs them again.
            if run['includedComments']:
                state['lastCommentId'] = max([int(state.get('lastCommentId') or 0), *run['includedComments']])
            if run['includedIssueBody']:
                state['issueBodyProcessed'] = True
            if run.get('verifyFailure') and state.get('verifyFailure') == run['verifyFailure']:
                state.pop('verifyFailure')
            if report['model']:
                state['model'] = report['model']
        return state
    store.update_json(session_key(number, 'state.json'), change, default={})

    table = usage_table(report, run, result)
    if success:
        text = (result.get('result') or report['lastText'] or '(応答本文がありません)').strip()
        if len(text) > MAX_COMMENT:
            text = text[:MAX_COMMENT] + '\n\n…(長いため省略しました。全文はActionsの実行ログを参照してください)'
        parts = [REPLY_MARKER, text, *pull_requests]
    else:
        reason = (result.get('api_error_status') or result.get('subtype')
                  or f"Claude Codeが中断・失敗しました ({os.environ.get('CLAUDE_OUTCOME') or 'not run'})")
        parts = [REPLY_MARKER, '⚠️ エージェントの実行が途中で止まりました。', '',
                 f'- 原因: `{reason}`', f'- 実行ログ: {run_url()}',
                 '- pushしたcommitは作業ブランチに残っています。このIssueへコメントすると、未処理の依頼と合わせて新しく始めます。',
                 *pull_requests]
    if attachments:
        parts.append('\n'.join(attachments))
    parts.append(table)
    gh.comment(number, '\n\n'.join(parts))

    turn = report['turnUsage']
    append_summary('\n'.join([
        f'### Issue #{number}',
        f"- success: `{success}` / session: `{report['sessionId']}` / model: `{report['model']}`",
        f"- tokens: input {fmt(turn['input'])}, cache read {fmt(turn['cacheRead'])}, "
        f"cache write {fmt(turn['cacheCreation'])}, output {fmt(turn['output'])}",
    ]))
    if not success:
        sys.exit(1)


# ------------------------------------------------- commands for Claude ---

def cmd_attach(args):
    source = Path(args.path).resolve()
    if not source.is_file():
        sys.exit(f'{source} がありません')
    destination = agent_home() / 'attachments' / f'{int(time.time() * 1000)}-{source.name}'
    destination.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(source, destination)
    outbox_append({'type': 'attach', 'path': str(destination), 'caption': args.caption})
    print('添付します。ターン終了時の返信に表示されます。')


def safe_name(name):
    return re.sub(r'[^A-Za-z0-9._-]+', '-', name).strip('-') or 'screen'


def cmd_shot(args):
    """Screenshot the Simulator, list it in screens.json (which state, which commit) and attach it."""
    home = agent_home()
    directory = home / 'artifacts' / 'screens'
    directory.mkdir(parents=True, exist_ok=True)
    path = directory / f'{safe_name(args.name)}.png'
    result = subprocess.run(['xcrun', 'simctl', 'io', args.device, 'screenshot', str(path)], capture_output=True, text=True)
    if result.returncode:
        sys.exit(f'スクリーンショットを撮れませんでした: {result.stderr.strip()}')
    index = home / 'artifacts' / 'screens.json'
    screens = read_json(index, [])
    screens = [entry for entry in screens if entry.get('name') != args.name]
    screens.append({'name': args.name, 'file': f'screens/{path.name}', 'launchArgs': args.launch_args or '',
                    'note': args.caption or '', 'commit': git('rev-parse', 'HEAD'),
                    'uncommittedChanges': bool(git('status', '--porcelain')), 'at': iso()})
    index.write_text(json.dumps(screens, ensure_ascii=False, indent=2))
    if not args.no_attach:
        outbox_append({'type': 'attach', 'path': str(path), 'caption': args.caption or args.name})
    print(f'{path} を撮り、screens.json に記録しました。')


def cmd_applog(args):
    """Stream the app's unified log from the Simulator into the run's records, in the background."""
    home = agent_home()
    record_path = home / 'applog.json'
    record = read_json(record_path, {})
    pid = record.get('pid')
    alive = bool(pid) and process_alive(pid)
    if args.action == 'start':
        if alive:
            print(f'すでに記録中です: {record["log"]}')
            return
        log = home / 'artifacts' / f'app-log-{utc_now().strftime("%Y%m%dT%H%M%S")}.log'
        with log.open('w') as stream:
            process = subprocess.Popen(['xcrun', 'simctl', 'spawn', args.device, 'log', 'stream', '--style', 'compact',
                                        '--level', 'debug', '--predicate', args.predicate],
                                       stdout=stream, stderr=subprocess.STDOUT, start_new_session=True)
        from progress import process_name
        (home / f'applog-process-{process.pid}.json').write_text(
            json.dumps({'pid': process.pid, 'name': process_name(process.pid), 'group': True}))
        record_path.write_text(json.dumps({'pid': process.pid, 'log': str(log)}))
        print(f'アプリのログを記録しています: {log}')
        return
    if alive:
        try:
            os.killpg(int(pid), signal.SIGTERM)
        except (ProcessLookupError, PermissionError):
            pass
    record_path.unlink(missing_ok=True)
    if record.get('log'):
        tail = Path(record['log']).read_text(errors='replace').splitlines()[-40:]
        print('\n'.join(tail))
        print(f'記録を止めました: {record["log"]}')


def cmd_decision(args):
    outbox_append({'type': 'decision', 'text': args.text})
    print('記録しました。次の実行からプロンプトに含まれます。')


def find_pr(gh, branch):
    owner = gh.repository.split('/')[0]
    prs = gh.get(f'/repos/{gh.repository}/pulls?head={owner}:{branch}&base=main&state=open')
    return prs[0] if prs else None


def cmd_request_pr(args):
    """Create or update this Issue's one Draft PR."""
    run = read_json(agent_home() / 'run.json')
    body = Path(args.body_file).read_text()
    marker = PR_MARKER.format(issue=run['issue'])
    if marker not in body:
        body += '\n\n' + marker
    if git('status', '--porcelain'):
        sys.exit('変更をcommit・pushしてからPRを作成してください。')
    if git('rev-parse', 'HEAD') != git('ls-remote', '--heads', 'origin', run['branch']).split('\t')[0]:
        sys.exit('push済みブランチとHEADが一致しません。pushしてください。')
    gh = GitHub()
    existing = find_pr(gh, run['branch'])
    if existing:
        old = existing.get('body') or ''
        if VERIFY_START in old and VERIFY_START not in body:
            body += '\n\n' + old[old.index(VERIFY_START):]
        pr = gh.request('PATCH', f'/repos/{gh.repository}/pulls/{existing["number"]}', {'title': args.title, 'body': body})[0]
    else:
        pr = gh.request('POST', f'/repos/{gh.repository}/pulls', {
            'title': args.title, 'body': body, 'head': run['branch'], 'base': 'main', 'draft': True})[0]
    outbox_append({'type': 'pull-request', 'url': pr['html_url']})
    print(f'Pull Request: {pr["html_url"]}')


def process_alive(pid):
    if not pid:
        return False
    try:
        os.kill(int(pid), 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    return True


def select_ui():
    script = '''import json, sys
sys.path.insert(0, "scripts/ci")
import ui_test_plan
changed = ui_test_plan.changed_files("main")
diff = ui_test_plan.project_diff("main") if changed is not None else None
tests, reasons = ui_test_plan.explain(ui_test_plan.discover(), json.loads(ui_test_plan.PLAN.read_text()), changed, diff)
print(json.dumps({"changedFiles": changed, "uiTests": tests, "reasons": reasons}))
'''
    return json.loads(subprocess.check_output([sys.executable, '-c', script], cwd=workspace(), text=True))


def test_rows(tree):
    rows = []
    def visit(node):
        if isinstance(node, list):
            for child in node:
                visit(child)
        elif isinstance(node, dict):
            if node.get('nodeType') == 'Test Case':
                rows.append({'test': node.get('nodeIdentifier') or node.get('name'), 'result': node.get('result'),
                             'duration': node.get('duration')})
            else:
                visit(node.get('testNodes', node.get('children', [])))
    visit(tree)
    return rows


def failure_details(tree):
    """Failed test cases with their failure messages, from `xcresulttool get test-results tests`."""
    failures = []
    def visit(node, case=None):
        if isinstance(node, list):
            for child in node:
                visit(child, case)
        elif isinstance(node, dict):
            if node.get('nodeType') == 'Test Case':
                if node.get('result') not in ('Passed', 'Skipped'):
                    entry = {'test': node.get('nodeIdentifier') or node.get('name'), 'result': node.get('result'), 'messages': []}
                    failures.append(entry)
                    visit(node.get('children', []), entry)
            elif node.get('nodeType') == 'Failure Message' and case is not None:
                case['messages'].append(node.get('name'))
            else:
                visit(node.get('testNodes', node.get('children', [])), case)
    visit(tree)
    return failures


def pushed_head(branch):
    if git('status', '--porcelain'):
        raise RuntimeError('未コミットの変更があります。commit・pushしてください。')
    head = git('rev-parse', 'HEAD')
    if head != git('ls-remote', '--heads', 'origin', branch).split('\t')[0]:
        raise RuntimeError('HEADがpush済みのブランチと一致しません。pushしてください。')
    return head


def local_verify():
    """Every unit test and the UI tests of the contracts the change touches, on this runner, for the pushed HEAD."""
    from guard import run_check
    from agentlib import redact
    run = read_json(agent_home() / 'run.json')
    head = pushed_head(run['branch'])
    selection = select_ui()
    home = agent_home()
    logs = home / 'artifacts' / f'local-{head[:12]}-{time.time_ns()}'
    logs.mkdir(parents=True)
    derived = os.environ.get('AGENT_DERIVED_DATA', str(home / 'DerivedData'))
    common = ['-project', 'strius.xcodeproj', '-scheme', 'strius',
              '-destination', os.environ.get('AGENT_TEST_DESTINATION', 'platform=iOS Simulator,name=iPhone 17'),
              '-derivedDataPath', derived, '-parallel-testing-enabled', 'NO', 'ARCHS=arm64', 'STRUIS_AUTH_REQUIRED=YES']
    allowance = ['-test-timeouts-enabled', 'YES', '-default-test-execution-time-allowance', '180',
                 '-maximum-test-execution-time-allowance', '600']
    commands = [
        ('build-for-testing', ['xcodebuild', 'build-for-testing', *common], 1800),
        ('tests', ['xcodebuild', 'test-without-building', *common, *allowance, '-only-testing:striusTests',
                   *[f'-only-testing:striusUITests/{test}' for test in selection['uiTests']],
                   '-resultBundlePath', str(logs / 'tests.xcresult')], 7200),
    ]
    record = {'head': head, 'branch': run['branch'], 'success': False, 'startedAt': iso(),
              'selection': selection, 'checks': []}
    environment = {key: value for key, value in os.environ.items() if not any(
        word in key.upper() for word in ('TOKEN', 'PASSWORD', 'PRIVATE_KEY', 'API_KEY', 'APP_KEY', 'CERTIFICATE', 'PROVISION_PROFILE'))}
    try:
        for name, command, seconds in commands:
            record['currentCheck'] = name
            started = time.monotonic()
            log = logs / f'{name}.log'
            print(f'Local verification: {name} ({log})', flush=True)
            with log.open('w') as stream:
                result = run_check(command, stream, seconds, environment)
            check = {'name': name, 'exitCode': result.returncode, 'seconds': round(time.monotonic() - started, 2), 'log': str(log)}
            if result.returncode:
                check['errors'] = [redact(line.strip())[:1500] for line in log.read_text(errors='replace').splitlines()
                                   if re.search(r'error:|\bfailed\b|FAILED|timed out', line, re.I)][-20:]
            bundle = logs / 'tests.xcresult'
            if name == 'tests' and bundle.exists():
                raw = subprocess.check_output(['xcrun', 'xcresulttool', 'get', 'test-results', 'tests',
                                               '--format', 'json', '--path', str(bundle)], text=True)
                (logs / 'tests.json').write_text(raw)
                tree = json.loads(raw)
                check['tests'] = test_rows(tree)
                check['failures'] = failure_details(tree)
                (logs / 'failures.json').write_text(json.dumps(check['failures'], ensure_ascii=False, indent=2))
                if not check['tests'] or check['failures']:
                    record['checks'].append(check)
                    raise RuntimeError('失敗したテスト、または結果が空です')
            record['checks'].append(check)
            if result.returncode:
                raise RuntimeError(f'{name} が失敗しました')
        if pushed_head(run['branch']) != head:
            raise RuntimeError('検証中にHEADが変わりました')
        record['success'] = True
    except BaseException as error:
        record['error'] = str(error)
        raise
    finally:
        record.pop('currentCheck', None)
        record['finishedAt'] = iso()
        (home / 'local-verification.json').write_text(json.dumps(record, ensure_ascii=False, indent=2))
        (logs / 'local-verification.json').write_text(json.dumps(record, ensure_ascii=False, indent=2))


def cmd_local_verify(args):
    """Start (or rejoin) the local verification of the pushed HEAD and wait for it in the foreground.

    Claude Code ends this session when its turn ends, so a verification left in a background Bash task
    loses its result (Issue #44). The verification is its own process group; this command waits at most
    --wait-minutes (below the Bash tool's 10-minute limit) and is called again while it is still running.
    """
    if args.run:
        local_verify()
        return
    home = agent_home()
    state_path = home / 'local-verify-process.json'
    head = git('rev-parse', 'HEAD')
    state = read_json(state_path, {})
    own = None
    if state.get('head') != head and process_alive(state.get('pid')):
        try:
            os.killpg(int(state['pid']), signal.SIGTERM)
        except (ProcessLookupError, PermissionError):
            pass
        for _ in range(30):
            if not process_alive(state['pid']):
                break
            time.sleep(1)
    if state.get('head') == head and process_alive(state.get('pid')):
        print(f'実行中の手元検証(HEAD {head[:12]})の終わりを待ちます。ログ: {state["log"]}', flush=True)
    else:
        log = home / 'artifacts' / f'local-verify-{head[:12]}-{time.time_ns()}.log'
        with log.open('w') as stream:
            own = subprocess.Popen([sys.executable, str(Path(__file__).resolve()), 'local-verify', '--run'],
                                   stdout=stream, stderr=subprocess.STDOUT, start_new_session=True)
        from progress import process_name
        (home / f'verify-process-{own.pid}.json').write_text(
            json.dumps({'pid': own.pid, 'name': process_name(own.pid), 'group': True}))
        state = {'pid': own.pid, 'head': head, 'log': str(log), 'startedAt': iso()}
        state_path.write_text(json.dumps(state))
        print(f'手元検証を開始しました(HEAD {head[:12]})。ログ: {log}', flush=True)

    def running():
        return own.poll() is None if own else process_alive(state['pid'])
    deadline = time.monotonic() + args.wait_minutes * 60
    while running():
        if time.monotonic() >= deadline:
            print('まだ実行中です。ターンを終えずに、同じコマンド `python3 "$AGENT_CTL" local-verify` を'
                  'もう一度実行して待ってください(検証は止まらずに続いています)。', flush=True)
            sys.exit(3)
        time.sleep(10)
    print('\n'.join(Path(state['log']).read_text(errors='replace').splitlines()[-25:]))
    record = read_json(home / 'local-verification.json', {})
    if record.get('head') == head and record.get('success') is True:
        print(f'手元検証: 成功(HEAD {head[:12]})。PRを出すなら `python3 "$AGENT_CTL" ready` を実行してください。')
        return
    print(f'手元検証: 失敗(HEAD {head[:12]})。{record.get("error") or ""}')
    for check in record.get('checks', []):
        for failure in check.get('failures', []):
            print(f"- {failure['test']}: {' / '.join(m for m in failure['messages'] if m)[:600]}")
        for line in check.get('errors', []):
            print(line)
    sys.exit(1)


def verification_summary(record):
    lines = [VERIFY_START, '### 手元検証(エージェントのrunner)', '', f'- HEAD: `{record["head"]}`',
             f'- 実行: {record["startedAt"]} → {record["finishedAt"]}', '- 単体テスト: striusTests 全件',
             f'- UIテスト: 変更が当たった契約の分 {len(record["selection"]["uiTests"])}件']
    for check in record['checks']:
        lines.append(f'- {check["name"]}: exit {check["exitCode"]}, {check["seconds"]}秒')
    lines += ['', '<details><summary>UIテストの選択</summary>', '',
              *[f'- `{name}`' for name in record['selection']['uiTests']], '', '</details>', VERIFY_END]
    return '\n'.join(lines)


def set_draft(gh, pr, value):
    field = 'convertPullRequestToDraft' if value else 'markPullRequestReadyForReview'
    response = gh.request('POST', '/graphql', {
        'query': f'mutation($id:ID!){{{field}(input:{{pullRequestId:$id}}){{pullRequest{{id isDraft}}}}}}',
        'variables': {'id': pr['node_id']}})[0]
    if response.get('errors'):
        raise RuntimeError(f'PRのDraft状態を変えられませんでした: {response["errors"]}')


def cmd_ready(_args):
    """Hand the locally verified HEAD to review: PR out of Draft. The owner enables auto-merge on it, and the
    merge queue (scripts/ci/merge_queue.py) verifies it on the latest main; nothing is verified before that."""
    home = agent_home()
    run = read_json(home / 'run.json')
    head = pushed_head(run['branch'])
    git('fetch', '--no-tags', 'origin', 'main')
    if subprocess.run(['git', '-C', workspace(), 'merge-base', '--is-ancestor', 'FETCH_HEAD', 'HEAD']).returncode:
        sys.exit('最新のmainを含んでいません。`git merge origin/main` で取り込み、push・local-verifyをやり直してください。')
    record = read_json(home / 'local-verification.json', {})
    if record.get('head') != head or record.get('success') is not True:
        sys.exit(f'HEAD {head[:12]} の手元検証が成功していません。`python3 "$AGENT_CTL" local-verify` を先に実行してください。')
    gh = GitHub()
    pr = find_pr(gh, run['branch'])
    if not pr:
        sys.exit('PRがありません。`python3 "$AGENT_CTL" request-pr` で作ってください。')
    body = pr.get('body') or ''
    if VERIFY_START in body and VERIFY_END in body:
        body = body[:body.index(VERIFY_START)] + body[body.index(VERIFY_END) + len(VERIFY_END):]
    body = body.rstrip() + '\n\n' + verification_summary(record)
    gh.request('PATCH', f'/repos/{gh.repository}/pulls/{pr["number"]}', {'body': body})
    if pr.get('draft'):
        set_draft(gh, pr, False)
    outbox_append({'type': 'pull-request', 'url': pr['html_url']})
    print(f'PR #{pr["number"]} をレビュー待ちにしました(HEAD {head[:12]})。持ち主が自動マージを有効にすると、'
          'マージキューが最新の main の上で検証します。結果は待たずにターンを終えてください。'
          '赤ならこのIssueでエージェントが起こされます。')


def cmd_prototype_status(args):
    outbox_append({'type': 'prototype-status', 'variant': args.variant, 'status': args.status, 'note': args.note})
    released = '。枠を解放します' if args.status == 'archived' else ''
    print(f'Prototype {args.variant} を {args.status} にします(ターン終了時に保存{released})。')


def cmd_prototypes(_args):
    path = agent_home() / 'prototypes.json'
    print(path.read_text() if path.exists() else '[]')


def cmd_prototype_build(args):
    number = issue_number()
    gh = GitHub()
    branch = args.ref or f'prototype/{number}/{args.variant}'
    if not git('ls-remote', '--heads', 'origin', branch):
        sys.exit(f'origin に {branch} がありません。先に commit して push してください。')
    started = utc_now() - datetime.timedelta(seconds=5)
    dispatch(gh, 'agent-prototype', {'operation': 'build', 'issue': number, 'variant': args.variant, 'ref': branch,
                                     'title': args.title, 'summary': args.summary or ''})
    run = None
    for _ in range(30):
        runs = gh.get(f'/repos/{gh.repository}/actions/workflows/agent-prototype.yml/runs?event=repository_dispatch&per_page=20')
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
        run = gh.get(f"/repos/{gh.repository}/actions/runs/{run['id']}")
    print(f"conclusion: {run.get('conclusion')}")
    comments = [c for c in gh.comments(number) if PROTOTYPE_MARKER in (c.get('body') or '')
                and f'prototype={args.variant}' in (c.get('body') or '')]
    if comments:
        print(comments[-1]['body'])
    if run.get('conclusion') != 'success':
        print(f"失敗ログ: gh run view {run['id']} --log-failed")
        sys.exit(1)


def join_option_values(argv, names):
    """`--launch-args -skip-onboarding` → `--launch-args=-skip-onboarding`: argparse would read a value that starts
    with `-` as another option (Issue #68)."""
    joined, index = [], 0
    while index < len(argv):
        if argv[index] in names and index + 1 < len(argv):
            joined.append(f'{argv[index]}={argv[index + 1]}')
            index += 2
        else:
            joined.append(argv[index])
            index += 1
    return joined


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest='command', required=True)
    commands.add_parser('route').set_defaults(func=cmd_route)
    commands.add_parser('prepare').set_defaults(func=cmd_prepare)
    commands.add_parser('finalize').set_defaults(func=cmd_finalize)
    attach = commands.add_parser('attach', help='スクリーンショット等を返信へ添付する')
    attach.add_argument('path')
    attach.add_argument('--caption')
    attach.set_defaults(func=cmd_attach)
    shot = commands.add_parser('shot', help='Simulatorの画面を撮り、screens.jsonに記録して返信へ添付する')
    shot.add_argument('name', help='画面の名前(例 timeline-card)。同じ名前は上書き')
    shot.add_argument('--launch-args', help='その画面を出すのに使った起動引数')
    shot.add_argument('--caption')
    shot.add_argument('--device', default='booted')
    shot.add_argument('--no-attach', action='store_true')
    shot.set_defaults(func=cmd_shot)
    applog = commands.add_parser('applog', help='Simulatorのアプリのログを記録に残す')
    applog.add_argument('action', choices=['start', 'stop'])
    applog.add_argument('--device', default='booted')
    applog.add_argument('--predicate', default=APP_LOG_PREDICATE)
    applog.set_defaults(func=cmd_applog)
    decision = commands.add_parser('decision', help='重要な設計判断を記録する')
    decision.add_argument('text')
    decision.set_defaults(func=cmd_decision)
    request_pr = commands.add_parser('request-pr', help='このIssueのDraft PRを作成・更新する')
    request_pr.add_argument('--title', required=True)
    request_pr.add_argument('--body-file', required=True)
    request_pr.set_defaults(func=cmd_request_pr)
    verify = commands.add_parser('local-verify', help='push済みHEADで全単体＋契約に当たったUIテストを流し、最大9分待つ')
    verify.add_argument('--run', action='store_true', help=argparse.SUPPRESS)
    verify.add_argument('--wait-minutes', type=float, default=9)
    verify.set_defaults(func=cmd_local_verify)
    commands.add_parser('ready', help='手元検証済みのHEADのPRをレビュー待ちにし、ios.ymlの検証を起動する').set_defaults(func=cmd_ready)
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
    build.add_argument('--ref', help='ビルドするブランチ(既定 prototype/{Issue}/{ID})。作業ブランチをそのまま渡せる')
    build.add_argument('--wait', action='store_true')
    build.add_argument('--wait-minutes', type=float, default=9)
    build.set_defaults(func=cmd_prototype_build)
    args = parser.parse_args(join_option_values(sys.argv[1:], ('--launch-args',)))
    args.func(args)


if __name__ == '__main__':
    main()
