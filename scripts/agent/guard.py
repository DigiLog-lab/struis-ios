"""Runner-owned test gate. A passing result belongs to one exact Git tree."""
import json
import os
import re
import signal
from pathlib import Path
import subprocess
import sys
import time

from agentlib import agent_home, iso

CHECK_TIMEOUTS = {'agent-tests': 300, 'worker-syntax': 60, 'simulator-build': 1800,
                  'unit-tests': 1800, 'ui-tests': 5400, 'release-archive': 1800, 'signed-archive': 1800}
GATE_VERSION = 2
FAILED_TEST = re.compile(r"^Test Case .* failed \(|^[✘×] Test .* failed", re.MULTILINE)


def run_check(command, stream, timeout, environment):
    """Stop on a known failing test and reap the entire owned process group."""
    process = subprocess.Popen(command, stdout=stream, stderr=subprocess.STDOUT,
                               env=environment, start_new_session=True)
    from progress import process_name
    registration = agent_home() / f'validation-process-{process.pid}.json'
    registration.write_text(json.dumps({'pid': process.pid, 'name': process_name(process.pid), 'group': True}))
    deadline = time.monotonic() + timeout
    old_handlers = {}
    def interrupted(signum, _frame):
        raise InterruptedError(f'検証処理が中断されました (signal {signum})')
    try:
        for signum in (signal.SIGTERM, signal.SIGINT):
            old_handlers[signum] = signal.signal(signum, interrupted)
        with Path(stream.name).open(errors='replace') as reader:
            pending = ''
            while process.poll() is None:
                pending = (pending + reader.read())[-65536:]
                if FAILED_TEST.search(pending):
                    return subprocess.CompletedProcess(command, 1)
                if time.monotonic() >= deadline:
                    raise subprocess.TimeoutExpired(command, timeout)
                time.sleep(0.2)
        return subprocess.CompletedProcess(command, process.returncode)
    finally:
        # SIGINT lets xcodebuild finish its result bundle before forced cleanup.
        if process.poll() is None:
            try:
                os.killpg(process.pid, signal.SIGINT)
                process.wait(timeout=15)
            except (ProcessLookupError, subprocess.TimeoutExpired):
                pass
        try:
            os.killpg(process.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        process.wait()
        registration.unlink(missing_ok=True)
        for signum, handler in old_handlers.items():
            signal.signal(signum, handler)


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
    tree = tree_to_test()
    previous = json.loads(report_path.read_text()) if report_path.exists() else None
    reuse = signed and approved(previous, tree) and previous.get('gateVersion') == GATE_VERSION
    report_path.unlink(missing_ok=True)
    report = {'tree': tree, 'success': False, 'startedAt': iso(), 'checks': [], 'gateVersion': GATE_VERSION}
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
                       '-test-timeouts-enabled', 'YES', '-default-test-execution-time-allowance', '180',
                       '-maximum-test-execution-time-allowance', '300',
                       '-parallel-testing-enabled', 'NO', 'ARCHS=arm64', 'STRUIS_AUTH_REQUIRED=YES']),
        ('ui-tests', ['xcodebuild', 'test', '-project', 'strius.xcodeproj', '-scheme', 'strius',
                     '-destination', 'platform=iOS Simulator,name=iPhone 17',
                     '-resultBundlePath', str(logs / 'StruisUITests.xcresult'),
                     '-collect-test-diagnostics', 'never', '-only-testing:striusUITests',
                     '-test-timeouts-enabled', 'YES', '-default-test-execution-time-allowance', '180',
                     '-maximum-test-execution-time-allowance', '600',
                     '-parallel-testing-enabled', 'NO', 'ARCHS=arm64', 'STRUIS_AUTH_REQUIRED=YES']),
        ('release-archive', ['xcodebuild', 'archive', '-project', 'strius.xcodeproj', '-scheme', 'strius',
                             '-configuration', 'Release', '-destination', 'generic/platform=iOS',
                             '-archivePath', str(logs / 'Struis.xcarchive'), 'CODE_SIGNING_ALLOWED=NO']),
    ]
    if reuse and {name for name, _ in commands} == {check['name'] for check in previous['checks'] if check['exitCode'] == 0}:
        report['checks'] = previous['checks'][:]
        report['reusedStartedAt'] = previous['startedAt']
        commands = []
    if signed:
        # ci_archive keeps logs private: xcodebuild may print service credentials.
        private_archive = Path(os.environ['RUNNER_TEMP']) / f'agent-signed-{time.time_ns()}'
        commands.append(('signed-archive', [sys.executable, 'scripts/ci_archive.py', '--output', str(private_archive)]))
    try:
        for name, command in commands:
            report['currentCheck'] = name
            report_path.write_text(json.dumps(report, indent=2))
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
                result = run_check(command, stream, CHECK_TIMEOUTS[name], environment)
            report['checks'].append({'name': name, 'exitCode': result.returncode})
            if result.returncode:
                raise RuntimeError(f'{name} が失敗しました。ログ: {logs / (name + ".log")}')
        if tree_to_test() != tree:
            raise RuntimeError('検証中にコードが変わりました。再検証してください。')
        report['success'] = True
        report['signedArchiveVerified'] = signed
    except BaseException as error:
        report['error'] = str(error)
        raise
    finally:
        report['finishedAt'] = iso()
        report_path.write_text(json.dumps(report, indent=2))
        (logs / 'validation.json').write_text(json.dumps(report, indent=2))
        (home / 'activity.json').write_text(json.dumps({'phase': '検証成功' if report['success'] else f'検証失敗: {report.get("currentCheck", "code")}', 'at': iso()}))
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
    if head == run.get('headBefore') and not run.get('validationRequired'):
        return True
    path = agent_home() / 'validation.json'
    report = json.loads(path.read_text()) if path.exists() else None
    return approved(report, git('rev-parse', 'HEAD^{tree}')) and report.get('signedArchiveVerified') is True


def push_gate():
    if git('status', '--porcelain'):
        raise RuntimeError('未コミットの変更があります。pushを止めました。')
    updates = [line.split() for line in sys.stdin if line.strip()]
    head = git('rev-parse', 'HEAD')
    if any(len(parts) != 4 or parts[1] != head or parts[2] == 'refs/heads/main'
           or parts[2].startswith('refs/heads/release/')
           or not parts[2].startswith('refs/heads/') for parts in updates):
        raise RuntimeError('現在のHEAD以外や、main・リリースブランチ(release/*)へのpushは許可しません。')
    # PR CI performs tests; this hook only checks the push destination and HEAD.


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
