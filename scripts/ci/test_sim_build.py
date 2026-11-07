"""sim_build.py: which Artifacts may be reused, and the products' round trip through an Artifact.

    python3 -m unittest discover -s scripts/ci -p 'test_*.py' -v
"""
from __future__ import annotations

import io
import os
import pathlib
import subprocess
import sys
import tempfile
import unittest
import zipfile
from typing import Any
from unittest import mock

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
import sim_build  # noqa: E402


def artifact(artifact_id: int, run_id: int, created: str, expired: bool = False) -> dict[str, Any]:
    return {"id": artifact_id, "expired": expired, "created_at": created, "workflow_run": {"id": run_id}}


RUNS: dict[str, dict[str, Any]] = {
    "actions/runs/1": {"path": ".github/workflows/ios.yml", "event": "repository_dispatch"},
    "actions/runs/2": {"path": ".github/workflows/ios.yml", "event": "workflow_dispatch"},
    "actions/runs/3": {"path": ".github/workflows/devbox.yml", "event": "repository_dispatch"},
    "actions/runs/4": {"path": ".github/workflows/ios.yml", "event": "repository_dispatch"},
}


class TrustTests(unittest.TestCase):
    def find(self, artifacts: list[dict[str, Any]]) -> int | None:
        def api(path: str) -> Any:
            return {"artifacts": artifacts} if path.startswith("actions/artifacts") else RUNS[path]
        with mock.patch.object(sim_build, "api", side_effect=api):
            return sim_build.find("sim-build-t-xcode27.1")

    def test_only_mains_verification_counts(self) -> None:
        # A PR's own definition (workflow_dispatch) or the Dev Box could upload anything under the name.
        self.assertIsNone(self.find([artifact(20, 2, "2026-11-07T02:00:00Z"), artifact(30, 3, "2026-11-07T03:00:00Z")]))
        self.assertEqual(self.find([artifact(20, 2, "2026-11-07T02:00:00Z"), artifact(10, 1, "2026-11-07T01:00:00Z")]), 10)

    def test_the_newest_trusted_one_is_taken_and_expired_ones_are_not(self) -> None:
        self.assertEqual(self.find([artifact(10, 1, "2026-11-07T01:00:00Z"), artifact(40, 4, "2026-11-07T04:00:00Z")]), 40)
        self.assertEqual(self.find([artifact(10, 1, "2026-11-07T01:00:00Z"),
                                    artifact(40, 4, "2026-11-07T04:00:00Z", expired=True)]), 10)

    def test_the_name_carries_the_tree_and_xcode(self) -> None:
        self.assertEqual(sim_build.artifact_name("abc", "27.1"), "sim-build-abc-xcode27.1")


class RoundTripTests(unittest.TestCase):
    def test_modes_and_links_survive_the_artifact(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = pathlib.Path(tmp)
            products = root / "dd" / "Build" / "Products" / "Debug-iphonesimulator" / "strius.app"
            products.mkdir(parents=True)
            (products / "strius").write_text("binary")
            (products / "strius").chmod(0o755)
            os.symlink("strius", products / "link")
            tar = root / sim_build.TAR_NAME
            sim_build.pack(root / "dd", tar)
            # upload-artifact zips the file; the zip keeps no modes, the tar inside does.
            buffer = io.BytesIO()
            with zipfile.ZipFile(buffer, "w") as archive:
                archive.write(tar, sim_build.TAR_NAME)
            zipped: bytes = buffer.getvalue()
            real_run = subprocess.run

            def fake_run(args: list[str], **kwargs: Any) -> Any:
                if args[:2] == ["gh", "api"]:
                    return subprocess.CompletedProcess(args, 0, stdout=zipped)
                return real_run(args, **kwargs)
            with mock.patch.object(sim_build.subprocess, "run", side_effect=fake_run):
                sim_build.download(7, root / "other" / "Build")
            app = root / "other" / "Build" / "Products" / "Debug-iphonesimulator" / "strius.app"
            self.assertTrue(os.access(app / "strius", os.X_OK))
            self.assertTrue((app / "link").is_symlink())


if __name__ == "__main__":
    unittest.main()
