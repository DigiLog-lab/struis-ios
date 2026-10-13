"""Runner-owned test gate. A passing result belongs to one exact Git tree."""
import json
import os
from pathlib import Path
import subprocess
import sys
import time

from agentlib import agent_home, iso


def git(*args):
    return subprocess.check_output(['git', *args], text=True).strip()


def tree_to_test():
    # Test the staged snapshot only when it also matches the working files.
    if subprocess.call(['git', 'diff', '--quiet']):
        raise RuntimeError('未ステージの変更があります。変更をstageしてから検証してください。')
    if git('ls-files', '--others', '--exclude-standard'):
        raise RuntimeError('未追跡のファイルがあります。変更をstageしてから検証してください。')
    return git('write-tree')


def verify(signed=False):
    home = agent_home()
    report_path = home / 'validation.json'
    report_path.unlink(missing_ok=True)  # A failed attempt must invalidate old success.
    tree = tree_to_test()
    report = {'tree': tree, 'success': False, 'startedAt': iso(), 'checks': []}
    logs = home / 'artifacts' / f'validation-{time.time_ns()}'
    logs.mkdir(parents=True)
    commands = [
        ('agent-tests', [sys.executable, '-m', 'unittest', 'discover', '-s', 'scripts/agent/tests', '-v']),
        ('worker-syntax', ['node', '--check', 'cloudflare/agent/src/index.js']),
        ('simulator-build', ['xcodebuild', 'build', '-project', 'strius.xcodeproj', '-scheme', 'strius',
                             '-destination', 'generic/platform=iOS Simulator', 'ARCHS=arm64', 'CODE_SIGNING_ALLOWED=NO']),
        ('unit-tests', ['xcodebuild', 'test', '-project', 'strius.xcodeproj', '-scheme', 'strius',
                       '-destination', 'platform=iOS Simulator,name=iPhone 17',
                       '-resultBundlePath', str(logs / 'StruisTests.xcresult'),
                       '-collect-test-diagnostics', 'never', '-only-testing:striusTests',
                       '-parallel-testing-enabled', 'NO', 'ARCHS=arm64', 'STRUIS_AUTH_REQUIRED=YES']),
        ('ui-tests', ['xcodebuild', 'test', '-project', 'strius.xcodeproj', '-scheme', 'strius',
                     '-destination', 'platform=iOS Simulator,name=iPhone 17',
                     '-resultBundlePath', str(logs / 'StruisUITests.xcresult'),
                     '-collect-test-diagnostics', 'never', '-only-testing:striusUITests',
                     '-parallel-testing-enabled', 'NO', 'ARCHS=arm64', 'STRUIS_AUTH_REQUIRED=YES']),
        ('release-archive', ['xcodebuild', 'archive', '-project', 'strius.xcodeproj', '-scheme', 'strius',
                             '-configuration', 'Release', '-destination', 'generic/platform=iOS',
                             '-archivePath', str(logs / 'Struis.xcarchive'), 'CODE_SIGNING_ALLOWED=NO']),
    ]
    if signed:
        # ci_archive keeps logs private: xcodebuild may print service credentials.
        private_archive = Path(os.environ['RUNNER_TEMP']) / f'agent-signed-{time.time_ns()}'
        commands.append(('signed-archive', [sys.executable, 'scripts/ci_archive.py', '--output', str(private_archive)]))
    try:
        for name, command in commands:
            (home / 'activity.json').write_text(json.dumps({'phase': f'検証中: {name}', 'at': iso()}))
            print(f'検証中: {name} ({logs / (name + ".log")})', flush=True)
            environment = dict(os.environ)
            if name == 'signed-archive':
                # Issue events identify main in GITHUB_SHA; ci_archive must verify the work commit.
                environment['GITHUB_SHA'] = git('rev-parse', 'HEAD')
            else:
                # Xcode prints exported environment/settings. No credentials in public logs.
                for key in list(environment):
                    if any(word in key.upper() for word in ('TOKEN', 'PASSWORD', 'PRIVATE_KEY', 'API_KEY', 'APP_KEY', 'CERTIFICATE', 'PROVISION_PROFILE')):
                        del environment[key]
            with (logs / f'{name}.log').open('w') as stream:
                result = subprocess.run(command, stdout=stream, stderr=subprocess.STDOUT, timeout=5400, env=environment)
            report['checks'].append({'name': name, 'exitCode': result.returncode})
            if result.returncode:
                raise RuntimeError(f'{name} が失敗しました。ログ: {logs / (name + ".log")}')
        if tree_to_test() != tree:
            raise RuntimeError('検証中にコードが変わりました。再検証してください。')
        report['success'] = True
        report['signedArchiveVerified'] = signed
    finally:
        report['finishedAt'] = iso()
        report_path.write_text(json.dumps(report, indent=2))
    return report


def approved(report, tree):
    return bool(report and report.get('success') and report.get('tree') == tree)


def commit_gate():
    tree = tree_to_test()
    path = agent_home() / 'validation.json'
    report = json.loads(path.read_text()) if path.exists() else None
    if not approved(report, tree):
        verify()


def publication_allowed(run):
    # A conversation without edits needs no iOS build. Any leftover edits block delivery.
    if git('status', '--porcelain'):
        return False
    head = git('rev-parse', 'HEAD')
    if head == run.get('headBefore'):
        return True
    path = agent_home() / 'validation.json'
    report = json.loads(path.read_text()) if path.exists() else None
    return approved(report, git('rev-parse', 'HEAD^{tree}')) and report.get('signedArchiveVerified') is True


def push_gate():
    if git('status', '--porcelain'):
        raise RuntimeError('未コミットの変更があります。pushを止めました。')
    updates = [line.split() for line in sys.stdin if line.strip()]
    head = git('rev-parse', 'HEAD')
    if any(len(parts) != 4 or parts[1] != head or parts[2] == 'refs/heads/main' for parts in updates):
        raise RuntimeError('検証対象のHEAD以外やmainへのpushは許可しません。')
    commit_gate()


if __name__ == '__main__':
    try:
        if sys.argv[1:] == ['commit']:
            commit_gate()
        elif sys.argv[1:] == ['push']:
            push_gate()
        else:
            verify()
    except (RuntimeError, OSError, subprocess.SubprocessError) as error:
        print(f'検証ゲート: {error}', file=sys.stderr)
        sys.exit(1)
