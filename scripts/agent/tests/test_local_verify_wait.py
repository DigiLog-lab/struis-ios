"""local-verify waits in the foreground and can be called again while the verification runs (Issue #44)."""
import argparse
import io
import json
import os
from contextlib import redirect_stdout
from pathlib import Path
import sys
import tempfile
import unittest
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import agentctl  # noqa: E402


class FakeProcess:
    def __init__(self, pid, finish_after):
        self.pid, self.left = pid, finish_after

    def poll(self):
        if self.left <= 0:
            return 0
        self.left -= 1
        return None


class LocalVerifyWaitTests(unittest.TestCase):
    def setUp(self):
        self.home = Path(tempfile.mkdtemp())
        patch = mock.patch.dict(os.environ, {'AGENT_HOME': str(self.home)})
        patch.start()
        self.addCleanup(patch.stop)
        for target, value in (('git', lambda *args: 'a' * 40), ('time', mock.Mock(monotonic=mock.Mock(side_effect=self.clock),
                                                                                   sleep=lambda seconds: None, time_ns=lambda: 1))):
            patcher = mock.patch.object(agentctl, target, value)
            patcher.start()
            self.addCleanup(patcher.stop)
        self.now = 0.0

    def clock(self):
        self.now += 10
        return self.now

    def run_command(self, minutes=9):
        out = io.StringIO()
        code = 0
        with redirect_stdout(out):
            try:
                agentctl.cmd_local_verify(argparse.Namespace(run=False, wait_minutes=minutes))
            except SystemExit as stop:
                code = stop.code
        return code, out.getvalue()

    def record(self, success, head='a' * 40):
        (self.home / 'local-verification.json').write_text(json.dumps(
            {'head': head, 'success': success, 'error': None if success else 'Local verification failed: tests',
             'checks': [{'name': 'tests', 'failures': [] if success else ['Foo.swift:1: error: boom']}]}))

    def test_starts_detached_and_reports_success(self):
        process = FakeProcess(4242, finish_after=3)
        def spawn(command, **kwargs):
            self.assertTrue(kwargs['start_new_session'])
            self.assertEqual(command[-2:], ['local-verify', '--run'])
            self.record(True)
            return process
        with mock.patch.object(agentctl.subprocess, 'Popen', side_effect=spawn):
            code, out = self.run_command()
        self.assertEqual(code, 0)
        self.assertIn('手元検証: 成功', out)
        self.assertEqual(json.loads((self.home / 'local-verify-process.json').read_text())['pid'], 4242)

    def test_still_running_exits_3_and_the_next_call_rejoins_without_restarting(self):
        with mock.patch.object(agentctl.subprocess, 'Popen', return_value=FakeProcess(4242, finish_after=10**6)) as popen:
            code, out = self.run_command(minutes=1)
        self.assertEqual(code, 3)
        self.assertIn('もう一度実行して待ってください', out)
        alive = iter([True, True, False])
        self.record(False)
        with mock.patch.object(agentctl, 'process_alive', side_effect=lambda pid: next(alive)), \
                mock.patch.object(agentctl.subprocess, 'Popen') as again:
            code, out = self.run_command()
        again.assert_not_called()
        self.assertEqual(popen.call_count, 1)
        self.assertEqual(code, 1)
        self.assertIn('手元検証: 失敗', out)
        self.assertIn('error: boom', out)

    def test_a_record_of_another_head_is_not_success(self):
        def spawn(command, **kwargs):
            self.record(True, head='b' * 40)
            return FakeProcess(1, finish_after=0)
        with mock.patch.object(agentctl.subprocess, 'Popen', side_effect=spawn):
            code, _ = self.run_command()
        self.assertEqual(code, 1)

    def test_a_verification_of_an_older_head_is_stopped_before_a_new_one_starts(self):
        (self.home / 'local-verify-process.json').write_text(json.dumps({'pid': 77, 'head': 'b' * 40, 'log': 'x'}))
        alive = iter([True, False])
        def spawn(command, **kwargs):
            self.record(True)
            return FakeProcess(5, finish_after=0)
        with mock.patch.object(agentctl, 'process_alive', side_effect=lambda pid: next(alive, False)), \
                mock.patch.object(agentctl.os, 'killpg') as kill, \
                mock.patch.object(agentctl.subprocess, 'Popen', side_effect=spawn):
            code, _ = self.run_command()
        kill.assert_called_once_with(77, 15)
        self.assertEqual(code, 0)


if __name__ == '__main__':
    unittest.main()
