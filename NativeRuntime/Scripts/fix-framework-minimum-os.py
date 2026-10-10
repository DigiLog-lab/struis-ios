#!/usr/bin/env python3
"""Match embedded framework metadata to its actual Mach-O deployment target."""
import os
from pathlib import Path
import plistlib
import re
import subprocess
import sys

for framework in sorted(Path(sys.argv[1]).glob('*.framework')):
    info = framework / 'Info.plist'
    data = plistlib.loads(info.read_bytes())
    binary = framework / data['CFBundleExecutable']
    commands = subprocess.check_output(['xcrun', 'vtool', '-show-build', str(binary)], text=True)
    versions = re.findall(r'^\s+minos\s+(\d+(?:\.\d+)+)', commands, re.M)
    if not versions:
        commands = subprocess.check_output(['otool', '-l', str(binary)], text=True)
        versions = re.findall(r'cmd LC_VERSION_MIN_IPHONEOS\s+cmdsize \d+\s+version (\d+(?:\.\d+)+)', commands)
    if not versions:
        raise RuntimeError('Missing deployment target: ' + str(binary))
    minimum = max(versions, key=lambda value: tuple(map(int, value.split('.'))))
    if data.get('MinimumOSVersion') == minimum:
        continue
    print(f'{framework.name}: MinimumOSVersion {data.get("MinimumOSVersion")} -> {minimum}')
    data['MinimumOSVersion'] = minimum
    info.write_bytes(plistlib.dumps(data, fmt=plistlib.FMT_BINARY))
    subprocess.run(['codesign', '--force', '--sign', os.environ.get('EXPANDED_CODE_SIGN_IDENTITY') or '-',
                    '--timestamp=none', '--preserve-metadata=identifier,entitlements,flags',
                    '--generate-entitlement-der', str(framework)], check=True)
