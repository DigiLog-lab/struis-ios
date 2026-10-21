#!/usr/bin/env python3
"""Repair only disposable CI Simulator pair state; verify cloning before build."""
import json
import os
from pathlib import Path
import subprocess
import uuid

out = Path(os.environ['RUNNER_TEMP']) / 'ci-overnight'
out.mkdir(exist_ok=True)


def sim(*args):
    return subprocess.check_output(['xcrun', 'simctl', *args], text=True, timeout=90)


before = json.loads(sim('list', 'pairs', '-j'))
(out / 'pairs-before.json').write_text(json.dumps(before, indent=2))
for pair_id in before.get('pairs', {}):
    uuid.UUID(pair_id)  # Fail on unexpected inventory instead of passing arbitrary input.
    print('Unpair ' + pair_id, flush=True)
    subprocess.run(['xcrun', 'simctl', 'unpair', pair_id], check=True, timeout=90)
subprocess.run(['xcrun', 'simctl', 'delete', 'unavailable'], check=True, timeout=90)
after = json.loads(sim('list', 'pairs', '-j'))
(out / 'pairs-after.json').write_text(json.dumps(after, indent=2))
if after.get('pairs'):
    raise SystemExit('Simulator pairs remain after cleanup')
devices = json.loads(sim('list', 'devices', 'available', '-j'))['devices']
ios = sorted((key for key in devices if '.iOS-' in key),
             key=lambda key: [int(n) for n in key.rsplit('.iOS-', 1)[1].split('-')])
phone = next((d for key in reversed(ios) for d in devices[key] if d['name'] == 'iPhone 17'), None)
if not phone:
    raise SystemExit('No available iPhone 17 for clone preflight')
cloned = sim('clone', phone['udid'], 'Struis CI clone preflight').strip()
uuid.UUID(cloned)
(out / 'clone-preflight.json').write_text(json.dumps({
    'sourceDevice': phone['udid'], 'cloneDevice': cloned, 'result': 'success',
}, indent=2))
subprocess.run(['xcrun', 'simctl', 'delete', cloned], check=True, timeout=90)
print('SIMULATOR_CLONE_PREFLIGHT=passed', flush=True)
