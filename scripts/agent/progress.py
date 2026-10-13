"""Update one Issue comment; disclose tool names, never tool inputs or output."""
import json
import os
from pathlib import Path
import sys
import time

from agentlib import GitHub, REPLY_MARKER, agent_home, iso, run_url


def hook():
    event = json.load(sys.stdin)
    name = event.get('tool_name', '')
    # Only names from a fixed list may appear in the public comment.
    name = name if name in {'Bash', 'Read', 'Edit', 'Write', 'Grep', 'Glob', 'Agent', 'Task', 'WebFetch', 'WebSearch'} else 'Tool'
    suffix = {'PreToolUse': '実行中', 'PostToolUseFailure': '失敗'}.get(event.get('hook_event_name'), '完了')
    phase = f'{name} {suffix}'
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
    while not (home / 'progress-stop').exists():
        try:
            update(run, '実行中')
        except Exception as error:
            print(f'Progress update failed: {type(error).__name__}', flush=True)
        time.sleep(60)


if __name__ == '__main__':
    hook() if sys.argv[1:] == ['hook'] else watch()
