"""Add filtered live display to the pinned Action's SDK output formatter only."""
import hashlib
import os
from pathlib import Path
import shutil

ACTION_SHA = '1d6de8cb0c237e7c15e9e1bdf973826ebae490cc'
SOURCE_SHA256 = '5890e7a00af10eb7b891f513081c972a6691a948dfa87fe62f3a7eeaa13ec892'
MARKER = 'function sanitizeSdkOutput(\n  message: SDKMessage,\n  showFullOutput: boolean,\n): string | null {\n'


def configure(action_root):
    source = action_root / 'base-action/src/run-claude-sdk.ts'
    data = source.read_bytes()
    if hashlib.sha256(data).hexdigest() != SOURCE_SHA256:
        raise RuntimeError('Claude Actionの固定ソースが一致しません。ログ設定を見直してください。')
    text = data.decode()
    if text.count(MARKER) != 1:
        raise RuntimeError('Claude SDKの表示処理を特定できません。')
    insertion = ('  const live = require("./struis-live-log.cjs").formatLiveMessage(message);\n'
                 '  if (live) return live;\n')
    shutil.copyfile(Path(__file__).with_name('live-log.cjs'), source.with_name('struis-live-log.cjs'))
    source.write_text(text.replace(MARKER, MARKER + insertion))


if __name__ == '__main__':
    root = Path(os.environ['RUNNER_WORKSPACE']).parent / '_actions/anthropics/claude-code-action' / ACTION_SHA
    configure(root)
    print('Claudeの説明・ツール呼出し・結果を認証情報の除去後に逐次表示します。')
