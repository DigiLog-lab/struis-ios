#!/usr/bin/env python3
"""Register standalone resources through Xcodeproj; omit absent optional bundles."""
from pathlib import Path
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
subprocess.run([sys.executable, str(ROOT / "scripts/prepare_external_test_inputs.py")], check=True)
subprocess.run(["ruby", str(ROOT / "scripts/sync_test_resources.rb")], check=True)
