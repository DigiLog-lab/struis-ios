"""Update one Issue comment; disclose tool names, never tool inputs or output."""
import json
import os
from pathlib import Path
import sys
import time
import signal
import subprocess
import re

from agentlib import GitHub, REPLY_MARKER, Store, agent_home, gate_config, iso, run_url


def process_name(pid):
    try:
        return Path(subprocess.check_output(['ps', '-o', 'comm=', '-p', str(pid)], text=True).strip()).name
    except subprocess.CalledProcessError:
        return ''


def register_claude():
    pid = os.getppid()
    for _ in range(5):
        name = process_name(pid)
        if name == 'claude' or re.fullmatch(r'\d+\.\d+\.\d+', name):
            (agent_home() / f'claude-process-{pid}.json').write_text(json.dumps({'pid': pid, 'name': name}))
            return
        try:
            pid = int(subprocess.check_output(['ps', '-o', 'ppid=', '-p', str(pid)], text=True).strip())
        except (ValueError, subprocess.CalledProcessError):
            return
        if pid <= 1:
            return


def stop_owned_commands():
    """Freeze an interrupted runner before saving its workspace."""
    for path in agent_home().glob('*-process-*.json'):
        try:
            record = json.loads(path.read_text())
        except (FileNotFoundError, json.JSONDecodeError):
            continue
        pid = record['pid']
        if pid == os.getpid() or process_name(pid) != record['name']:
            continue
        try:
            if record.get('group'):
                if os.getpgid(pid) != pid:
                    continue
                send = lambda sig: os.killpg(pid, sig)
            else:
                send = lambda sig: os.kill(pid, sig)
            send(signal.SIGTERM)
            deadline = time.monotonic() + 2
            while time.monotonic() < deadline and process_name(pid) == record['name']:
                time.sleep(0.1)
            if process_name(pid) == record['name']:
                send(signal.SIGKILL)
        except ProcessLookupError:
            pass
        path.unlink(missing_ok=True)


def hook():
    event = json.load(sys.stdin)
    if event.get('session_id'):
        (agent_home() / 'session-id.json').write_text(json.dumps({'id': event['session_id']}))
    register_claude()
    name = event.get('tool_name', '')
    # Only names from a fixed list may appear in the public comment.
    name = name if name in {'Bash', 'Read', 'Edit', 'Write', 'Grep', 'Glob', 'Agent', 'Task', 'WebFetch', 'WebSearch'} else 'Tool'
    suffix = {'PreToolUse': '実行中', 'PostToolUseFailure': '失敗'}.get(event.get('hook_event_name'), '完了')
    phase = 'Claude開始' if event.get('hook_event_name') == 'SessionStart' else f'{name} {suffix}'
    (agent_home() / 'activity.json').write_text(json.dumps({'phase': phase, 'at': iso()}))


def update(run, phase, finished=False):
    home = agent_home()
    activity_path = home / 'activity.json'
    activity = json.loads(activity_path.read_text()) if activity_path.exists() else {}
    body = '\n\n'.join([
        REPLY_MARKER, f'**エージェント: {phase}**',
        f'- 開始: {run["startedAt"]}\n- 状態更新: {iso()}\n'
        f'- 最後の動作: {activity.get("phase", "Claudeの起動待ち")} ({activity.get("at", run["startedAt"])})',
        f'[実行ログ・キャンセル]({run_url()})',
        '' if finished else '状態更新は監視プロセスの稼働を示します。最後の動作の時刻が進まない場合は、待機や長時間の処理、停止の可能性があります。',
    ])
    gh = GitHub()
    path = home / 'progress-comment.json'
    if path.exists():
        identifier = json.loads(path.read_text())['id']
        gh.request('PATCH', f'/repos/{gh.repository}/issues/comments/{identifier}', {'body': body})
    else:
        comment = gh.comment(run['issue'], body)
        path.write_text(json.dumps({'id': comment['id']}))


def watch():
    home = agent_home()
    run = json.loads((home / 'run.json').read_text())
    next_checkpoint = time.monotonic() + int(gate_config()['checkpointSeconds'])
    while not (home / 'progress-stop').exists():
        try:
            update(run, '実行中')
        except Exception as error:
            print(f'Progress update failed: {type(error).__name__}', flush=True)
        if os.environ.get('AGENT_VALIDATION_MODE') == 'gate' and time.monotonic() >= next_checkpoint:
            try:
                import checkpoints
                checkpoints.save(Store(), run['issue'], run, periodic=True)
            except Exception as error:
                print(f'Periodic checkpoint deferred: {type(error).__name__}', flush=True)
            next_checkpoint = time.monotonic() + int(gate_config()['checkpointSeconds'])
        # Notice finalize's stop promptly, including while waiting for the next tick.
        for _ in range(60):
            if (home / 'progress-stop').exists():
                return
            time.sleep(1)


if __name__ == '__main__':
    hook() if sys.argv[1:] == ['hook'] else watch()
