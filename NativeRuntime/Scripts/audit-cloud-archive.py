#!/usr/bin/env python3
"""Run the native payload/signature audit on Xcode Cloud's completed archive."""
import os
from pathlib import Path
import re
import subprocess
import sys


def audit(environment):
    if environment.get('CI_XCODEBUILD_ACTION') != 'archive':
        print('NATIVE_ARCHIVE_AUDIT skipped: action is not archive')
        return
    if environment.get('CI_XCODEBUILD_EXIT_CODE') != '0':
        print('NATIVE_ARCHIVE_AUDIT skipped: archive did not succeed')
        return
    archive = Path(environment['CI_ARCHIVE_PATH'])
    derived = Path(environment['CI_DERIVED_DATA_PATH'])
    app = archive / 'Products/Applications/strius.app'
    if not app.is_dir() or not derived.is_dir():
        raise RuntimeError('Native archive app or DerivedData is missing')
    targets = {'strius', 'StruisRuntime', 'StruisExec'}
    maps = []
    found = set()
    for path in sorted(derived.rglob('*-LinkMap-*.txt')):
        match = re.fullmatch(r'(strius|StruisRuntime|StruisExec)-LinkMap-.+\.txt', path.name)
        parts = path.relative_to(derived).parts
        if (match and 'ArchiveIntermediates' in parts
                and any(part.endswith('-iphoneos') for part in parts)
                and path.parent.name == match[1] + '.build'
                and path.is_file() and path.stat().st_size):
            found.add(match[1])
            maps.append(path)
    if found != targets:
        raise RuntimeError('Native link maps missing for: ' + ', '.join(sorted(targets - found)))
    command = [sys.executable, str(Path(__file__).with_name('audit-bundle.py')), '--app', str(app)]
    for path in maps:
        command += ['--link-map', str(path)]
    # codesign/otool are invoked by the existing auditor on the actual signed archive.
    # Its JSON report is retained in the Cloud post-xcodebuild log; failures fail the hook.
    subprocess.run(command, check=True)


if __name__ == '__main__':
    audit(os.environ)
