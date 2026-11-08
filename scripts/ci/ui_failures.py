#!/usr/bin/env python3
"""The screen recording and the screenshot at the moment of failure, for each failed UI test.

XCTest records the screen of every UI test and keeps the recording of a failed one in the result bundle
(Xcode 27: an attachment "Screen Recording ….mp4" of the test's first activity, lifetime deleteOnSuccess).
This exports that recording and takes the frame at the failure (scripts/ci/video_frame.swift: macOS
runners have no ffmpeg), into OUT/<Class>-<method>.mp4 and .png, and prints a Markdown summary.

    python3 scripts/ci/ui_failures.py OUT RESULT.xcresult [RESULT.xcresult ...] >> "$GITHUB_STEP_SUMMARY"
"""
from __future__ import annotations

import json
import pathlib
import re
import shutil
import subprocess
import sys
import tempfile
from typing import Any

HERE: pathlib.Path = pathlib.Path(__file__).resolve().parent
# Seconds before the failure: the failure is recorded after the screen showed what went wrong.
BEFORE_FAILURE: float = 0.3


def xcresulttool(*args: str) -> Any:
    out: str = subprocess.run(["xcrun", "xcresulttool", *args], capture_output=True, text=True, check=True).stdout
    return json.loads(out)


def failed_tests(tests: Any) -> list[str]:
    """Identifiers ("Class/method()") of the failed test cases in `xcresulttool get test-results tests`."""
    found: list[str] = []

    def walk(node: Any) -> None:
        if isinstance(node, dict):
            if node.get("nodeType") == "Test Case" and node.get("result") == "Failed" and node.get("nodeIdentifier"):
                found.append(str(node["nodeIdentifier"]))
            for value in node.values():
                walk(value)
        elif isinstance(node, list):
            for value in node:
                walk(value)

    walk(tests)
    return sorted(set(found))


def recording_and_failure(activities: Any) -> tuple[str, float, float] | None:
    """(recording's name, its start, the failure's time) of the last run of a test that has both."""
    result: tuple[str, float, float] | None = None
    for run in activities.get("testRuns", []):
        recording: tuple[str, float] | None = None
        failure: float | None = None

        def walk(nodes: list[Any]) -> None:
            nonlocal recording, failure
            for node in nodes:
                for attachment in node.get("attachments", []):
                    name = str(attachment.get("name", ""))
                    if recording is None and name.endswith(".mp4") and attachment.get("timestamp") is not None:
                        recording = (name, float(attachment["timestamp"]))
                if failure is None and node.get("isAssociatedWithFailure") and node.get("startTime") is not None:
                    failure = float(node["startTime"])
                walk(node.get("childActivities", []))

        walk(run.get("activities", []))
        if recording is not None and failure is not None:
            result = (recording[0], recording[1], failure)
    return result


def file_name(test_id: str) -> str:
    return re.sub(r"[^A-Za-z0-9_-]+", "-", test_id.replace("()", "")).strip("-")


def exported_recording(manifest: Any, suggested_name: str) -> str | None:
    for test in manifest:
        for attachment in test.get("attachments", []):
            if attachment.get("suggestedHumanReadableName") == suggested_name:
                return str(attachment["exportedFileName"])
    return None


def collect(out: pathlib.Path, bundles: list[pathlib.Path]) -> list[str]:
    out.mkdir(parents=True, exist_ok=True)
    lines: list[str] = []
    frame_tool: pathlib.Path | None = None
    for bundle in bundles:
        if not bundle.exists():
            continue
        for test_id in failed_tests(xcresulttool("get", "test-results", "tests", "--path", str(bundle))):
            found = recording_and_failure(xcresulttool(
                "get", "test-results", "activities", "--path", str(bundle), "--test-id", test_id))
            if found is None:
                lines.append(f"- `{test_id}`: 録画が結果に残っていません")
                continue
            recording_name, started, failed_at = found
            with tempfile.TemporaryDirectory() as tmp:
                subprocess.run(["xcrun", "xcresulttool", "export", "attachments", "--path", str(bundle),
                                "--output-path", tmp, "--test-id", test_id], capture_output=True, check=True)
                manifest: Any = json.loads((pathlib.Path(tmp) / "manifest.json").read_text())
                exported = exported_recording(manifest, recording_name)
                if exported is None:
                    lines.append(f"- `{test_id}`: 録画を取り出せませんでした")
                    continue
                video: pathlib.Path = out / f"{file_name(test_id)}.mp4"
                shutil.copyfile(pathlib.Path(tmp) / exported, video)
            seconds: float = max(0.0, failed_at - started - BEFORE_FAILURE)
            if frame_tool is None:
                frame_tool = out.parent / "video_frame"
                subprocess.run(["xcrun", "swiftc", "-parse-as-library", "-O", str(HERE / "video_frame.swift"),
                                "-o", str(frame_tool)], check=True)
            shot: pathlib.Path = out / f"{file_name(test_id)}.png"
            took = subprocess.run([str(frame_tool), str(video), f"{seconds:.2f}", str(shot)])
            lines.append(f"- `{test_id}`: 失敗は録画の {seconds:.1f} 秒目。`{video.name}`"
                         + (f"、`{shot.name}`" if took.returncode == 0 else "(スクショは取れませんでした)"))
    return lines


def main(argv: list[str]) -> int:
    if len(argv) < 2:
        print(__doc__, file=sys.stderr)
        return 2
    lines = collect(pathlib.Path(argv[0]), [pathlib.Path(path) for path in argv[1:]])
    if lines:
        print("### 失敗した UI テストの録画とスクショ(Artifact `ui-failures-…`)\n")
        print("\n".join(lines))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
