#!/usr/bin/env python3
"""Submit one evidence-backed Tutor Desk memory update for backend validation."""
from __future__ import annotations

import argparse
import shutil
import sys
import uuid
from pathlib import Path

import yaml

ALLOWED_KEYS = {
    "schema_version", "source", "future_teaching_change", "observations",
    "skill_inferences", "learner_updates", "unknowns", "plan", "intervention",
}


def _safe_path(root: Path, value: str) -> Path:
    rel = Path(value)
    if rel.is_absolute():
        raise ValueError("path must be workspace-relative")
    resolved = (root / rel).resolve()
    if not resolved.is_relative_to(root):
        raise ValueError("path escapes workspace")
    return resolved


def submit(value: str) -> int:
    root = Path.cwd().resolve()
    source_path = _safe_path(root, value)
    if not source_path.is_file():
        raise FileNotFoundError(value)
    if source_path.stat().st_size > 65536:
        raise ValueError("memory update is too large")
    payload = yaml.safe_load(source_path.read_text(encoding="utf-8"))
    if not isinstance(payload, dict):
        raise ValueError("memory update must be a YAML mapping")
    unexpected = set(payload) - ALLOWED_KEYS
    if unexpected:
        raise ValueError(f"unexpected keys: {sorted(unexpected)}")
    if payload.get("schema_version") != 1:
        raise ValueError("schema_version must be 1")
    source = payload.get("source")
    if not isinstance(source, dict):
        raise ValueError("source is required")
    session_path = root / "tutor_desk" / "current" / "session.yaml"
    session = yaml.safe_load(session_path.read_text(encoding="utf-8"))
    for key in ("learner_id", "thread_id", "turn_run_id", "user_message_id"):
        if str(source.get(key) or "") != str(session.get(key) or ""):
            raise ValueError(f"source.{key} does not match current session")
    if not str(payload.get("future_teaching_change") or "").strip():
        raise ValueError("future_teaching_change is required")
    queue = root / "tutor_desk" / "queue" / "memory"
    queue.mkdir(parents=True, exist_ok=True)
    out = queue / f"{source['turn_run_id']}-{uuid.uuid4().hex}.yaml"
    shutil.copyfile(source_path, out)
    print(out.relative_to(root))
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(prog="struis_tutor_memory.py")
    sub = parser.add_subparsers(dest="command", required=True)
    submit_parser = sub.add_parser("submit")
    submit_parser.add_argument("--file", required=True)
    args = parser.parse_args()
    if args.command == "submit":
        return submit(args.file)
    return 2


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception as exc:
        print(f"struis_tutor_memory.py: {exc}", file=sys.stderr)
        raise SystemExit(2) from None
