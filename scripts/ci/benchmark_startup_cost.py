#!/usr/bin/env python3
"""Compare sequential vs overlapped Simulator preparation with the same build."""
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timezone
import json
import os
from pathlib import Path
import subprocess
import sys
import time

mode = sys.argv[1]
assert mode in ('sequential', 'overlap')
root = Path(os.environ['RUNNER_TEMP']) / 'startup-cost-benchmark'
root.mkdir(exist_ok=True)
records = []
origin = time.monotonic()


def command(label, args, timeout=900, allow_failure=False):
    started = time.monotonic()
    print(f'STARTUP begin {label}', flush=True)
    with (root / (label + '.log')).open('w') as stream:
        completed = subprocess.run(args, stdout=stream, stderr=subprocess.STDOUT, timeout=timeout)
    record = dict(label=label, startedOffset=started-origin,
                  wallSeconds=time.monotonic()-started, exitCode=completed.returncode)
    records.append(record)
    print('STARTUP ' + json.dumps(record), flush=True)
    if completed.returncode and not allow_failure:
        print((root / (label + '.log')).read_text()[-12000:], flush=True)
        raise RuntimeError(label + ' failed')
    return (root / (label + '.log')).read_text()


def prepare_simulator():
    devices = json.loads(command('list-devices', ['xcrun', 'simctl', 'list', 'devices', 'available', '-j']))['devices']
    runtimes = sorted((key for key in devices if '.iOS-' in key),
                      key=lambda key: [int(part) for part in key.rsplit('.iOS-', 1)[1].split('-')])
    udid = next(device['udid'] for key in reversed(runtimes) for device in devices[key]
                if device['name'] == 'iPhone 17')
    # boot returns nonzero when Xcode already booted this destination. bootstatus is authoritative.
    command('boot-request', ['xcrun', 'simctl', 'boot', udid], timeout=600, allow_failure=True)
    command('boot-status', ['xcrun', 'simctl', 'bootstatus', udid, '-b'])
    return udid


error = None
try:
    with ThreadPoolExecutor(max_workers=1) as executor:
        preparation = executor.submit(prepare_simulator) if mode == 'overlap' else None
        command('build', ['xcodebuild', 'build-for-testing', '-project', 'strius.xcodeproj', '-scheme', 'strius',
                '-destination', 'platform=iOS Simulator,name=iPhone 17', '-derivedDataPath',
                os.environ['RUNNER_TEMP'] + '/DerivedData', 'ARCHS=arm64', 'STRUIS_AUTH_REQUIRED=YES'], timeout=2100)
        udid = preparation.result() if preparation else prepare_simulator()
    app = Path(os.environ['RUNNER_TEMP']) / 'DerivedData/Build/Products/Debug-iphonesimulator/strius.app'
    bundle = command('bundle-id', ['/usr/libexec/PlistBuddy', '-c', 'Print :CFBundleIdentifier', str(app / 'Info.plist')]).strip()
    command('install', ['xcrun', 'simctl', 'install', udid, str(app)])
    command('launch', ['xcrun', 'simctl', 'launch', udid, bundle])
    container = command('container', ['xcrun', 'simctl', 'get_app_container', udid, bundle, 'data']).strip()
    started = time.monotonic()
    while not (Path(container) / 'Library/Application Support/Struis').is_dir():
        if time.monotonic() - started >= 240:
            raise RuntimeError('Learner data was not initialized within 240 seconds')
        time.sleep(1)
    time.sleep(5)
    records.append(dict(label='wait-ready', wallSeconds=time.monotonic()-started, exitCode=0))
    command('terminate', ['xcrun', 'simctl', 'terminate', udid, bundle])
except Exception as exc:
    error = repr(exc)
finally:
    result = dict(mode=mode, commit=os.environ['GITHUB_SHA'],
                  completedAt=datetime.now(timezone.utc).isoformat(),
                  wallSeconds=time.monotonic()-origin, error=error, stages=records)
    (root / 'measurements.json').write_text(json.dumps(result, indent=2))
    print('STARTUP_RESULT ' + json.dumps(result), flush=True)
    with open(os.environ['GITHUB_STEP_SUMMARY'], 'a') as summary:
        summary.write(f'## Simulator startup: {mode}\n\nTotal: {result["wallSeconds"]:.2f} seconds.\n\n')
        summary.write('| Stage | Seconds |\n|---|---:|\n')
        for record in records:
            summary.write(f'| {record["label"]} | {record["wallSeconds"]:.2f} |\n')
sys.exit(1 if error else 0)
