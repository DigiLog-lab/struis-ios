#!/usr/bin/env python3
"""Actual pinned MessageProcessor lifecycle fixture in its own test process.
Needs CARGO_TARGET_DIR explicitly set outside the source checkout. No product
factory is installed. No external model/API or authentication is used.
"""
import os, pathlib, subprocess, sys
ROOT = pathlib.Path(__file__).resolve().parents[1]
if not os.environ.get('CARGO_TARGET_DIR'):
    raise SystemExit('Set CARGO_TARGET_DIR to an owned external build cache')
subprocess.run([sys.executable,str(ROOT/'Scripts/check-turn-lease-preparation.py')],check=True)
# Exact name is checked from the binary's actual --list output; upstream's
# private module spelling is not silently guessed into a zero-test success.
base=['cargo','test','-p','codex-app-server','--lib','--offline','--locked']
cwd=ROOT/'Vendor/codex-source/codex-rs'
listing=subprocess.run(base+['hyotan_captured_turn_actual_rpc_ingress_interrupt_completion_and_failure','--','--list','--ignored'],cwd=cwd,text=True,capture_output=True)
if listing.returncode:
    print(listing.stdout,end='');print(listing.stderr,end='')
    raise SystemExit(listing.returncode)
print(listing.stderr,end='')
names=[line.removesuffix(': test') for line in listing.stdout.splitlines() if line.endswith(': test')]
if len(names)!=1 or not names[0].endswith('::hyotan_captured_turn_actual_rpc_ingress_interrupt_completion_and_failure'):
    raise SystemExit('Expected exactly one actual pinned lifecycle test')
result=subprocess.run(base+[names[0],'--','--exact','--ignored','--test-threads=1'],cwd=cwd,text=True,capture_output=True)
print(result.stdout,end='');print(result.stderr,end='')
if result.returncode or '1 passed; 0 failed' not in result.stdout:
    raise SystemExit(result.returncode or 1)
print('PASS actual pinned MessageProcessor lifecycle; test-only factory; not all filesystem routes or Apple acceptance')
