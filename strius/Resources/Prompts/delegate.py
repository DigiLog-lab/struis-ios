"""Workspace command used by the foreground coach to await a private lookup."""

from __future__ import annotations

import json
import os
import sys
import time
import uuid
from pathlib import Path


def main() -> int:
    if len(sys.argv) != 2:
        raise ValueError("Pass the private turn inbox path; provide the request JSON on stdin")
    inbox = Path(sys.argv[1]).resolve(strict=True)
    workspace = Path.cwd().resolve()
    if not inbox.is_relative_to(workspace / ".struis_delegations"):
        raise ValueError("Invalid delegation inbox")
    request = json.loads(sys.stdin.read(24001))
    request_id = uuid.uuid4().hex
    temporary = inbox / f"{request_id}.tmp"
    pending = inbox / f"{request_id}.request.json"
    response = inbox / f"{request_id}.response.json"
    temporary.write_text(json.dumps(request, ensure_ascii=False), encoding="utf-8")
    os.replace(temporary, pending)
    deadline = time.monotonic() + 300
    while time.monotonic() < deadline:
        if response.is_file():
            result = json.loads(response.read_text(encoding="utf-8"))
            print(json.dumps(result, ensure_ascii=False))
            return 0 if result.get("success") else 1
        if (inbox / "closed").exists():
            print(json.dumps({"success": False, "reason": "Parent turn ended or was stopped"}))
            return 1
        time.sleep(0.1)
    print(json.dumps({"success": False, "reason": "Delegation timed out; do not retry automatically"}))
    return 1


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, ValueError) as exc:
        print(json.dumps({"success": False, "reason": str(exc)}))
        raise SystemExit(1) from exc
