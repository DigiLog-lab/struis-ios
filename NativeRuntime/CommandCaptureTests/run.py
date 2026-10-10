#!/usr/bin/env python3
"""Exercise the exact capture helper over real bounded native pipes."""
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile

root = Path(__file__).resolve().parent.parent
source = root / "CommandCaptureTests/capture.c"
header = root / "Worker/NativeCommandCapture.h"
compiler = os.environ.get("CC", "cc")
flags = ["-std=c11", "-Wall", "-Wextra", "-Werror", "-pthread"]
with tempfile.TemporaryDirectory(prefix="hyotan-command-capture-") as folder:
    temporary = Path(folder)
    binary = temporary / "capture"
    subprocess.run([compiler, *flags, "-fsanitize=address,undefined", str(source), "-o", str(binary)], check=True)
    result = subprocess.run([str(binary)], check=True, text=True, capture_output=True, timeout=15)
    print(result.stdout, end="")
    old = temporary / "old-order"
    (old / "Worker").mkdir(parents=True)
    (old / "CommandCaptureTests").mkdir()
    text = header.read_text()
    before = "        bool completedBeforeRead = atomic_load_explicit(finished, memory_order_acquire);\n"
    after = "if (completedBeforeRead) return 0;"
    assert text.count(before) == text.count(after) == 1
    text = text.replace(before, "").replace(after, "if (atomic_load_explicit(finished, memory_order_acquire)) return 0;")
    (old / "Worker/NativeCommandCapture.h").write_text(text)
    shutil.copyfile(source, old / "CommandCaptureTests/capture.c")
    old_binary = temporary / "old-capture"
    subprocess.run([compiler, *flags, str(old / "CommandCaptureTests/capture.c"), "-o", str(old_binary)], check=True)
    rejected = subprocess.run([str(old_binary)], text=True, capture_output=True, timeout=15, cwd=temporary)
    assert rejected.returncode != 0 and "length == sizeof(marker) - 1" in rejected.stderr
    print("PASS previous completion-after-read order loses marker under the same real pipe race")
    print(json.dumps({"source_sha256": hashlib.sha256(source.read_bytes()).hexdigest(),
                      "header_sha256": hashlib.sha256(header.read_bytes()).hexdigest(),
                      "real_pipe_cases": 4, "actual_read_failure_cases": 1, "sanitizers": ["address", "undefined"],
                      "previous_order_failure_returncode": rejected.returncode}, sort_keys=True))
