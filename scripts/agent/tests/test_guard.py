import io
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time
import unittest
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import guard  # noqa: E402
import progress  # noqa: E402


class GuardTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.home = Path(self.temp.name)
        patch = mock.patch.dict(os.environ, {'AGENT_HOME': str(self.home), 'RUNNER_TEMP': str(self.home)})
        patch.start()
        self.addCleanup(patch.stop)

    def test_push_of_main_or_another_commit_is_blocked(self):
        for update in ['refs/heads/topic head refs/heads/main old', 'refs/heads/topic other refs/heads/topic old']:
            with mock.patch.object(guard, 'git', side_effect=['', 'head']), \
                    mock.patch.object(sys, 'stdin', io.StringIO(update)), self.assertRaises(RuntimeError):
                guard.push_gate()

    def test_push_of_the_current_head_is_allowed(self):
        update = 'refs/heads/topic head refs/heads/topic old\nrefs/heads/topic head refs/heads/prototype/4/a old'
        with mock.patch.object(guard, 'git', side_effect=['', 'head']), mock.patch.object(sys, 'stdin', io.StringIO(update)):
            guard.push_gate()

    def test_uncommitted_work_is_not_pushed(self):
        with mock.patch.object(guard, 'git', return_value=' M a.swift'), self.assertRaises(RuntimeError):
            guard.push_gate()

    def test_failed_test_stops_running_command_immediately(self):
        start = time.monotonic()
        command = [sys.executable, '-u', '-c', 'import time; print("Test Case example failed (1 seconds)."); time.sleep(60)']
        with (self.home / 'failed.log').open('w') as stream:
            result = guard.run_check(command, stream, 60, dict(os.environ))
        self.assertEqual(result.returncode, 1)
        self.assertLess(time.monotonic() - start, 5)

    def test_real_timeout_terminates_command(self):
        start = time.monotonic()
        with (self.home / 'timeout.log').open('w') as stream, self.assertRaises(subprocess.TimeoutExpired):
            guard.run_check([sys.executable, '-c', 'import time; time.sleep(60)'], stream, 0.05, dict(os.environ))
        self.assertLess(time.monotonic() - start, 5)

    def test_stop_does_not_kill_a_reused_pid(self):
        (self.home / 'applog-process-123.json').write_text(json.dumps({'pid': 123, 'name': 'log'}))
        with mock.patch.object(progress, 'process_name', return_value='different'), mock.patch.object(progress.os, 'kill') as kill:
            progress.stop_owned_commands()
        kill.assert_not_called()

    def test_stop_terminates_only_the_registered_process(self):
        (self.home / 'claude-process-123.json').write_text(json.dumps({'pid': 123, 'name': 'claude'}))
        with mock.patch.object(progress, 'process_name', side_effect=['claude', '', '']), mock.patch.object(progress.os, 'kill') as kill:
            progress.stop_owned_commands()
        kill.assert_called_once_with(123, progress.signal.SIGTERM)


if __name__ == '__main__':
    unittest.main()
