#!/usr/bin/env python3
"""Validate, copy and sign the fixed test-only Dash images on an Xcode host."""
import hashlib
import json
import os
import plistlib
import re
import shutil
import subprocess
from pathlib import Path

HERE = Path(__file__).resolve().parent
REVISION = '3da49bb7ac15458ea4f554b589dde5197816f6ba'
EXPORTS = ['StruisSignedDashStageEnter', 'StruisSignedDashStageInstallLauncher']


def digest(path):
    result = hashlib.sha256()
    with path.open('rb') as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b''):
            result.update(chunk)
    return result.hexdigest()


def validate(vendor):
    path = vendor / 'compound-dash-preparation.json'
    if path.is_symlink() or path.stat().st_size > 65536:
        raise RuntimeError('Invalid preparation manifest')
    manifest = json.loads(path.read_text())
    if (manifest.get('abi') != 3 or manifest.get('mode') != 'debug-simulator-one-shot'
            or manifest.get('dashSourceRevision') != REVISION or manifest.get('exports') != EXPORTS):
        raise RuntimeError('Unsupported prepared Dash image ABI or provenance')
    helpers = manifest.get('helpers')
    if not isinstance(helpers, list) or len(helpers) != 8:
        raise RuntimeError('Expected exactly eight signed stage inputs')
    paths = []
    for index, helper in enumerate(helpers):
        name = f'HyotanDashStage{index}'
        archive = name + '-native.xcframework'
        relative = f'{archive}/ios-arm64-simulator/{name}.framework'
        if (not isinstance(helper, dict) or type(helper.get('index')) is not int
                or helper['index'] != index or helper.get('xcframework') != archive
                or helper.get('path') != relative
                or not re.fullmatch('[0-9a-f]{64}', str(helper.get('sha256', '')))):
            raise RuntimeError('Invalid fixed stage input')
        framework = vendor / relative
        if any(part.is_symlink() for part in (vendor / archive, framework.parent, framework,
                                              framework / name, framework / 'Info.plist')):
            raise RuntimeError('Symlinked stage input refused')
        info = plistlib.loads((framework / 'Info.plist').read_bytes())
        if info.get('CFBundleExecutable') != name or info.get('CFBundleSupportedPlatforms') != ['iPhoneSimulator']:
            raise RuntimeError('Stage input is not the fixed Simulator framework')
        if digest(framework / name) != helper['sha256']:
            raise RuntimeError('Stage executable hash mismatch')
        paths.append(framework)
    root_hash = manifest.get('rootSimulatorSHA256')
    if not re.fullmatch('[0-9a-f]{64}', str(root_hash or '')):
        raise RuntimeError('Missing prepared root image hash')
    root = vendor / 'dash-native.xcframework/ios-arm64-simulator/dash.framework/dash'
    if root.is_symlink() or digest(root) != root_hash:
        raise RuntimeError('Prepared root image hash mismatch')
    return paths


def main():
    destination = Path(os.environ['CODESIGNING_FOLDER_PATH']) / 'Frameworks'
    vendor = HERE.parent / 'NativeRuntime/Vendor'
    prepared = (os.environ.get('PLATFORM_NAME') == 'iphonesimulator'
                and os.environ.get('CONFIGURATION') == 'Debug'
                and (vendor / 'compound-dash-preparation.json').exists())
    # Only these fixed test payload names are managed; archive/default builds
    # cannot retain a prior Simulator stage image in their output directory.
    for index in range(8):
        path = destination / f'HyotanDashStage{index}.framework'
        if path.is_symlink():
            raise RuntimeError('Symlinked stage output refused')
        if path.exists():
            shutil.rmtree(path)
    if not prepared:
        return
    inputs = validate(vendor)
    identity = os.environ.get('EXPANDED_CODE_SIGN_IDENTITY') or '-'
    destination.mkdir(parents=True, exist_ok=True)
    for source in inputs:
        target = destination / source.name
        shutil.copytree(source, target)
        subprocess.run(['codesign', '--force', '--sign', identity, '--timestamp=none', str(target)], check=True)
        subprocess.run(['codesign', '--verify', '--strict', str(target)], check=True)
    print('Packaged and verified eight fixed Debug Simulator Dash stage signatures')


if __name__ == '__main__':
    main()
