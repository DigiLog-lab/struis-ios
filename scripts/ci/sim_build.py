#!/usr/bin/env python3
"""The Simulator build of a tree, made once and reused (docs/development-method.md, "7. マージキュー").

ios.yml's verification uploads the products of `xcodebuild build-for-testing` as the Artifact
`sim-build-<tree SHA>-xcode<version>` (14 days). The tree, not the commit: main's merge commit of a PR that
contained main has the PR's tree, so the build the queue verified is main's build too.

    sim_build.py prepare DERIVED_DATA UDID   # reuse the Artifact of HEAD's tree, or build; writes BUILT and
                                             # BUILD_NAME to $GITHUB_ENV (BUILT=1: upload it)
    sim_build.py pack DERIVED_DATA TAR       # Build/Products as one tar, the file the Artifact holds
    sim_build.py main OUT                    # the newest build of main's history (the "before" of a
                                             # before/after screenshot on the Dev Box): OUT/Build/Products

The Artifact holds one tar of Build/Products: an Artifact keeps neither file modes nor symbolic links, and
the app's and the test runners' executables need theirs.

Only Artifacts uploaded by ios.yml runs of main's definition (repository_dispatch) count: a run of a PR's
own definition (workflow_dispatch) could upload anything under any name. Needs gh and GH_TOKEN.
"""
from __future__ import annotations

import io
import json
import os
import pathlib
import subprocess
import sys
import zipfile
from typing import Any

REPOSITORY: str = os.environ.get("GITHUB_REPOSITORY", "DigiLog-lab/struis-ios")
TAR_NAME: str = "products.tar"


def run(*args: str, cwd: str | None = None) -> str:
    return subprocess.run(list(args), capture_output=True, text=True, check=True, cwd=cwd).stdout.strip()


def api(path: str) -> Any:
    return json.loads(run("gh", "api", f"repos/{REPOSITORY}/{path}"))


def xcode_version() -> str:
    first: str = run("xcodebuild", "-version").splitlines()[0]   # "Xcode 27.1"
    return first.split()[-1]


def artifact_name(tree: str, xcode: str) -> str:
    return f"sim-build-{tree}-xcode{xcode}"


def trusted(artifact: dict[str, Any], runs: dict[int, dict[str, Any]]) -> bool:
    """Uploaded by ios.yml running main's definition (the queue's verification), and not expired."""
    if artifact.get("expired"):
        return False
    run_id = int((artifact.get("workflow_run") or {}).get("id") or 0)
    if not run_id:
        return False
    if run_id not in runs:
        runs[run_id] = api(f"actions/runs/{run_id}")
    workflow_run: dict[str, Any] = runs[run_id]
    return (str(workflow_run.get("path", "")).startswith(".github/workflows/ios.yml")
            and workflow_run.get("event") == "repository_dispatch")


def find(name: str) -> int | None:
    runs: dict[int, dict[str, Any]] = {}
    listed: dict[str, Any] = api(f"actions/artifacts?name={name}&per_page=30")
    for artifact in sorted(listed.get("artifacts", []), key=lambda a: str(a.get("created_at", "")), reverse=True):
        if trusted(artifact, runs):
            return int(artifact["id"])
    return None


def download(artifact_id: int, build: pathlib.Path) -> None:
    """The Artifact's tar unpacked into BUILD (giving BUILD/Products)."""
    data: bytes = subprocess.run(["gh", "api", f"repos/{REPOSITORY}/actions/artifacts/{artifact_id}/zip"],
                                 capture_output=True, check=True).stdout
    build.mkdir(parents=True, exist_ok=True)
    with zipfile.ZipFile(io.BytesIO(data)) as archive:
        with archive.open(TAR_NAME) as tar:
            subprocess.run(["tar", "-x", "-C", str(build), "-f", "-"], input=tar.read(), check=True)


def pack(derived_data: pathlib.Path, tar: pathlib.Path) -> int:
    subprocess.run(["tar", "-c", "-C", str(derived_data / "Build"), "-f", str(tar), "Products"], check=True)
    return 0


def env_out(**values: str) -> None:
    target = os.environ.get("GITHUB_ENV")
    for key, value in values.items():
        print(f"{key}={value}")
        if target:
            with open(target, "a") as handle:
                handle.write(f"{key}={value}\n")


def prepare(derived_data: pathlib.Path, udid: str) -> int:
    tree: str = run("git", "rev-parse", "HEAD^{tree}")
    name: str = artifact_name(tree, xcode_version())
    artifact_id = find(name)
    if artifact_id is not None:
        download(artifact_id, derived_data / "Build")
        print(f"reused the build of tree {tree[:12]} (Artifact {artifact_id})")
        env_out(BUILD_NAME=name, BUILT="0")
        return 0
    subprocess.run(["xcodebuild", "build-for-testing", "-project", "strius.xcodeproj", "-scheme", "strius",
                    "-destination", f"id={udid}", "-derivedDataPath", str(derived_data),
                    "ARCHS=arm64", "STRUIS_AUTH_REQUIRED=YES"], check=True)
    env_out(BUILD_NAME=name, BUILT="1")
    return 0


def main_build(out: pathlib.Path, depth: int = 50) -> int:
    xcode: str = xcode_version()
    subprocess.run(["git", "fetch", "-q", f"--depth={depth}", "origin", "main"], check=True)
    for line in run("git", "log", "--format=%H %T", f"-{depth}", "FETCH_HEAD").splitlines():
        commit, tree = line.split()
        artifact_id = find(artifact_name(tree, xcode))
        if artifact_id is not None:
            download(artifact_id, out / "Build")
            print(f"main's build: commit {commit[:12]} (tree {tree[:12]}), Artifact {artifact_id} -> {out}/Build/Products")
            return 0
    print(f"no build of main's last {depth} commits for Xcode {xcode}", file=sys.stderr)
    return 1


def main(argv: list[str]) -> int:
    if len(argv) == 3 and argv[0] == "prepare":
        return prepare(pathlib.Path(argv[1]), argv[2])
    if len(argv) == 3 and argv[0] == "pack":
        return pack(pathlib.Path(argv[1]), pathlib.Path(argv[2]))
    if len(argv) == 2 and argv[0] == "main":
        return main_build(pathlib.Path(argv[1]))
    print(__doc__, file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
