"""The Dev Box round trip on Linux: serve.sh and mac.py against a local bare repository.

    python3 -m unittest discover -s scripts/devbox -p 'test_*.py' -v
"""
from __future__ import annotations

import gzip
import os
import pathlib
import subprocess
import sys
import tempfile
import time
import unittest

HERE: pathlib.Path = pathlib.Path(__file__).resolve().parent
SERVE: pathlib.Path = HERE / "serve.sh"
MAC: pathlib.Path = HERE / "mac.py"


def sh(*args: str, cwd: pathlib.Path) -> None:
    subprocess.run(args, cwd=cwd, check=True, capture_output=True, text=True)


class DevBoxRoundTripTests(unittest.TestCase):
    root: pathlib.Path
    client: pathlib.Path
    server: subprocess.Popen[str]
    _tmp: tempfile.TemporaryDirectory[str]

    @classmethod
    def setUpClass(cls) -> None:
        cls._tmp = tempfile.TemporaryDirectory()
        cls.root = pathlib.Path(cls._tmp.name)
        origin: pathlib.Path = cls.root / "origin.git"
        sh("git", "init", "-q", "--bare", str(origin), cwd=cls.root)
        work: pathlib.Path = cls.root / "server"
        sh("git", "clone", "-q", str(origin), str(work), cwd=cls.root)
        for key, value in (("user.name", "test"), ("user.email", "test@example.com")):
            sh("git", "config", key, value, cwd=work)
        (work / "hello.txt").write_text("v1\n")
        sh("git", "add", "hello.txt", cwd=work)
        sh("git", "commit", "-q", "-m", "v1", cwd=work)
        sh("git", "push", "-q", "origin", "HEAD:refs/heads/work", cwd=work)
        cls.client = cls.root / "client"
        sh("git", "clone", "-q", "--branch", "work", str(origin), str(cls.client), cwd=cls.root)
        env: dict[str, str] = dict(
            os.environ,
            RUNNER_TEMP=str(cls.root / "runner-temp"),
            DEVBOX_WORK_BRANCH="work",
            DEVBOX_IDLE_SECONDS="120",
            DEVBOX_POLL_SECONDS="1",
            DEVBOX_PROGRESS_SECONDS="2",
            DEVBOX_COMMAND_SECONDS="15",
            DEVBOX_KEEP_RESULTS_SECONDS="5",
        )
        cls.server = subprocess.Popen(
            ["bash", str(SERVE)], cwd=work, env=env, text=True,
            stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
        )
        cls.mac("ready", "--timeout", "30")

    @classmethod
    def tearDownClass(cls) -> None:
        if cls.server.poll() is None:
            cls.mac("stop")
            try:
                cls.server.wait(timeout=30)
            except subprocess.TimeoutExpired:
                cls.server.kill()
        cls._tmp.cleanup()

    @classmethod
    def mac(cls, *args: str, check: bool = True) -> subprocess.CompletedProcess[str]:
        completed: subprocess.CompletedProcess[str] = subprocess.run(
            [sys.executable, str(MAC), *args], cwd=cls.client, capture_output=True, text=True, timeout=120
        )
        if check and completed.returncode != 0:
            raise AssertionError(f"mac {args}: {completed.returncode}\n{completed.stdout}\n{completed.stderr}")
        return completed

    def test_output_exit_code_and_files_come_back(self) -> None:
        result = self.mac("run", "--", 'echo out; echo err >&2; echo shot > "$DEVBOX_FILES/a.png"; exit 3', check=False)
        self.assertEqual(result.returncode, 3)
        self.assertIn("out", result.stdout)
        self.assertIn("err", result.stdout)
        files: list[pathlib.Path] = list((self.client / "devbox-out").glob("*/a.png"))
        self.assertEqual(len(files), 1)
        self.assertEqual(files[0].read_text(), "shot\n")

    def test_a_file_with_a_japanese_name_comes_back(self) -> None:
        result = self.mac("run", "--", 'echo shot > "$DEVBOX_FILES/画面.png"')
        self.assertEqual(result.returncode, 0)
        files: list[pathlib.Path] = list((self.client / "devbox-out").glob("*/画面.png"))
        self.assertEqual(len(files), 1)

    def test_a_command_is_not_run_when_the_work_branch_cannot_be_had(self) -> None:
        origin: pathlib.Path = self.root / "origin.git"
        head: str = subprocess.run(["git", "rev-parse", "refs/heads/work"], cwd=origin,
                                   capture_output=True, text=True, check=True).stdout.strip()
        sh("git", "update-ref", "-d", "refs/heads/work", cwd=origin)
        try:
            marker: pathlib.Path = self.root / "ran.txt"
            result = self.mac("run", "--", f"touch {marker}", check=False)
            self.assertEqual(result.returncode, 125)
            self.assertIn("the command was not run", result.stdout)
            self.assertFalse(marker.exists())
        finally:
            sh("git", "update-ref", "refs/heads/work", head, cwd=origin)

    def test_kill_ends_jobs_the_command_started(self) -> None:
        pid_file: pathlib.Path = self.root / "child.pid"
        command_id: str = self.mac(
            "run", "--async", "--", f"sleep 120 & echo $! > {pid_file}; wait"
        ).stdout.strip()
        for _ in range(30):
            if pid_file.exists() and pid_file.read_text().strip():
                break
            time.sleep(1)
        self.mac("kill")
        self.mac("wait", command_id, "--timeout", "40", check=False)
        child: int = int(pid_file.read_text().strip())
        alive: bool = subprocess.run(["kill", "-0", str(child)], capture_output=True).returncode == 0
        self.assertFalse(alive, "the job started inside the command is still running")

    def test_ready_waits_for_the_requested_branch(self) -> None:
        self.mac("ready", "--branch", "work", "--timeout", "15")
        other = self.mac("ready", "--branch", "another-branch", "--timeout", "5", check=False)
        self.assertNotEqual(other.returncode, 0)

    def test_the_whole_log_comes_back(self) -> None:
        command_id: str = self.mac("run", "--async", "--", "seq 1 500").stdout.strip()
        result = self.mac("wait", command_id, "--timeout", "40")
        self.assertNotIn("\n1\n", "\n" + result.stdout)
        full: str = gzip.decompress((self.client / "devbox-out" / command_id / "log.txt.gz").read_bytes()).decode()
        self.assertEqual(full.split(), [str(n) for n in range(1, 501)])

    def test_a_restarted_box_keeps_results_by_their_finish_time(self) -> None:
        # A result sent two hours ago that finished just now survives an earlier box's cleanup.
        script: str = (
            f"source <(sed -n '/^cleanup_old_results()/,/^}}/p;/^delete_ref()/,/^}}/p' {SERVE}); "
            "OUT_PREFIX=refs/heads/devbox-out/; KEEP_RESULTS=3600; cleanup_old_results"
        )
        old_id: str = "20000101T000000-000000-aaaaaa"
        blob: str = subprocess.run(["git", "hash-object", "-w", "--stdin"], cwd=self.client, check=True,
                                   input=f"finished={int(time.time())}\n", capture_output=True, text=True).stdout.strip()
        tree: str = subprocess.run(["git", "mktree"], cwd=self.client, check=True,
                                   input=f"100644 blob {blob}\ttimes\n", capture_output=True, text=True).stdout.strip()
        commit: str = subprocess.run(["git", "commit-tree", tree, "-m", "old"], cwd=self.client, check=True,
                                     capture_output=True, text=True,
                                     env={**os.environ, "GIT_AUTHOR_NAME": "t", "GIT_AUTHOR_EMAIL": "t@t",
                                          "GIT_COMMITTER_NAME": "t", "GIT_COMMITTER_EMAIL": "t@t"}).stdout.strip()
        ref: str = f"refs/heads/devbox-out/{old_id}"
        sh("git", "push", "-q", "origin", f"{commit}:{ref}", cwd=self.client)
        subprocess.run(["bash", "-c", script], cwd=self.client, check=True, capture_output=True)
        listed: str = subprocess.run(["git", "ls-remote", "origin", ref], cwd=self.client,
                                     capture_output=True, text=True, check=True).stdout
        self.assertTrue(listed, "a result that finished just now was deleted")

    def test_several_arguments_are_kept_as_arguments(self) -> None:
        result = self.mac("run", "--", "printf", "%s|", "a b", "c")
        self.assertIn("a b|c|", result.stdout)

    def test_command_runs_on_the_latest_commit_of_the_work_branch(self) -> None:
        (self.client / "hello.txt").write_text("v2\n")
        for key, value in (("user.name", "test"), ("user.email", "test@example.com")):
            sh("git", "config", key, value, cwd=self.client)
        sh("git", "commit", "-q", "-am", "v2", cwd=self.client)
        sh("git", "push", "-q", "origin", "HEAD:refs/heads/work", cwd=self.client)
        self.assertIn("v2", self.mac("run", "--", "cat hello.txt").stdout)

    def test_commands_sent_back_to_back_all_run(self) -> None:
        first: str = self.mac("run", "--async", "--", "echo first").stdout.strip()
        second: str = self.mac("run", "--async", "--", "echo second").stdout.strip()
        self.assertIn("first", self.mac("wait", first, "--timeout", "40").stdout)
        self.assertIn("second", self.mac("wait", second, "--timeout", "40").stdout)

    def test_results_are_deleted_by_the_dev_box_after_a_while(self) -> None:
        command_id: str = self.mac("run", "--async", "--", "true").stdout.strip()
        self.mac("wait", command_id, "--timeout", "40")
        ref: str = f"refs/heads/devbox-out/{command_id}"
        for _ in range(90):
            listed = subprocess.run(["git", "ls-remote", "origin", ref], cwd=self.client,
                                    capture_output=True, text=True, check=True).stdout
            if not listed:
                return
            time.sleep(1)
        self.fail(f"{ref} was not deleted")

    def test_interrupt_reaches_a_background_child(self) -> None:
        # `simctl io recordVideo` stops on SIGINT; without job control bash starts it with SIGINT ignored.
        result = self.mac("run", "--", "sleep 60 & r=$!; sleep 1; kill -INT $r; wait $r; echo rc=$?")
        self.assertIn("rc=130", result.stdout)

    def test_a_running_command_can_be_killed(self) -> None:
        command_id: str = self.mac("run", "--async", "--", "sleep 60").stdout.strip()
        self.mac("kill")
        result = self.mac("wait", command_id, "--timeout", "40", check=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertRegex(result.stdout, r"ended by \S+-kill")

    def test_a_command_is_ended_at_its_time_limit(self) -> None:
        result = self.mac("run", "--timeout", "60", "--", "sleep 60", check=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("ended by the time limit", result.stdout)


if __name__ == "__main__":
    unittest.main()
