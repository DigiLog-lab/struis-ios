#!/usr/bin/env python3
"""Build a signed archive from the checked-out commit using private CI inputs."""
import argparse
import base64
import json
import os
from pathlib import Path
import plistlib
import re
import secrets
import signal
import stat
import shlex
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]
PROFILE_INPUTS = {
    'strius': ('APP', 'com.digiloglab.strius'),
    'StruisRuntime': ('RUNTIME', 'com.digiloglab.strius.runtime'),
    'StruisExec': ('EXEC', 'com.digiloglab.strius.exec'),
}


def run(command, log=None):
    if log:
        with log.open('wb') as stream:
            result = subprocess.run(command, cwd=ROOT, stdout=stream, stderr=subprocess.STDOUT)
        if result.returncode:
            sensitive = [part for key, value in os.environ.items()
                         if key in ('P12_PASSWORD', 'STRUIS_DELIVERY_APP_KEY', 'APP_STORE_CONNECT_PRIVATE_KEY')
                         for part in value.splitlines() if part]
            for line in log.read_text(errors='replace').splitlines():
                if 'error:' in line.lower():
                    for value in sensitive:
                        if value:
                            line = line.replace(value, '[redacted]')
                    print(line[:1000], file=sys.stderr)
            raise RuntimeError(f'{command[0]} failed with exit {result.returncode}; private log: {log.name}')
        return None
    result = subprocess.run(command, cwd=ROOT, capture_output=True)
    if result.returncode:
        raise RuntimeError(f'{command[0]} {command[1]} failed with exit {result.returncode}')
    return result.stdout


def terminate(signum, _frame):
    raise SystemExit(128 + signum)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--output', required=True, type=Path)
    parser.add_argument('--upload', action='store_true')
    parser.add_argument('--build-number')
    args = parser.parse_args()
    if args.build_number and not re.fullmatch(r'[1-9][0-9]*', args.build_number):
        raise RuntimeError('Build number must be a positive integer')
    if args.upload and (not args.build_number or not os.environ.get('STRUIS_DELIVERY_APP_KEY')):
        raise RuntimeError('Upload requires an explicit build number and service configuration')
    auth_names = ('APP_STORE_CONNECT_PRIVATE_KEY', 'APP_STORE_CONNECT_KEY_ID', 'APP_STORE_CONNECT_ISSUER_ID')
    auth_present = [bool(os.environ.get(name)) for name in auth_names]
    if any(auth_present) and not all(auth_present):
        raise RuntimeError('App Store Connect authentication requires all three inputs')
    if args.upload and not all(auth_present):
        raise RuntimeError('Upload requires App Store Connect authentication')
    os.umask(0o077)
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    commit = run(['git', 'rev-parse', 'HEAD']).decode().strip()
    if os.environ.get('GITHUB_SHA') and os.environ['GITHUB_SHA'] != commit:
        raise RuntimeError('Checkout and workflow commit differ')
    archive = output / 'Struis.xcarchive'
    if archive.exists():
        raise RuntimeError('Use a new output directory for each archive')
    local = ROOT / 'Config/Local.xcconfig'
    local_original = local.read_bytes() if local.exists() else None
    original_keychains = shlex.split(run(['security', 'list-keychains', '-d', 'user']).decode())
    installed = {}
    protected = {}
    keychain = None
    temporary = tempfile.TemporaryDirectory(prefix='struis-signing-')
    signal.signal(signal.SIGTERM, terminate)
    try:
        private = Path(temporary.name)
        keychain = private / 'build.keychain-db'
        keychain_password = secrets.token_urlsafe(32)
        certificate = private / 'distribution.p12'
        certificate.write_bytes(base64.b64decode(os.environ['BUILD_CERTIFICATE_BASE64'], validate=True))
        run(['security', 'create-keychain', '-p', keychain_password, str(keychain)])
        run(['security', 'set-keychain-settings', '-lut', '21600', str(keychain)])
        run(['security', 'unlock-keychain', '-p', keychain_password, str(keychain)])
        run(['security', 'import', str(certificate), '-k', str(keychain), '-P', os.environ['P12_PASSWORD'], '-T', '/usr/bin/codesign'])
        run(['security', 'set-key-partition-list', '-S', 'apple-tool:,apple:,codesign:', '-s', '-k', keychain_password, str(keychain)])
        run(['security', 'list-keychains', '-d', 'user', '-s', str(keychain), *original_keychains])
        identities = run(['security', 'find-identity', '-v', '-p', 'codesigning', str(keychain)]).decode()
        identity = re.findall(r'\b[0-9A-F]{40}\b', identities)
        if len(identity) != 1:
            raise RuntimeError('Expected one valid distribution identity')
        profiles = {}
        teams = set()
        settings = []
        for product, (label, bundle) in PROFILE_INPUTS.items():
            data = base64.b64decode(os.environ[f'BUILD_PROVISION_PROFILE_{label}_BASE64'], validate=True)
            path = private / f'{label}.mobileprovision'
            path.write_bytes(data)
            profile = plistlib.loads(run(['security', 'cms', '-D', '-i', str(path)]))
            entitlements = profile['Entitlements']
            team = profile['TeamIdentifier'][0]
            if entitlements['application-identifier'] != f'{team}.{bundle}' or entitlements.get('get-task-allow'):
                raise RuntimeError(f'Distribution profile mismatch for {product}')
            if 'group.com.digiloglab.struis.runtime' not in entitlements.get('com.apple.security.application-groups', []):
                raise RuntimeError(f'App Group missing for {product}')
            teams.add(team)
            profiles[bundle] = profile['UUID']
            settings.append(f'STRUIS_CI_PROFILE_{product}={profile["UUID"]}')
            for directory in (Path.home() / 'Library/MobileDevice/Provisioning Profiles',
                              Path.home() / 'Library/Developer/Xcode/UserData/Provisioning Profiles'):
                directory.mkdir(parents=True, exist_ok=True)
                destination = directory / f'{profile["UUID"]}.mobileprovision'
                installed[destination] = destination.read_bytes() if destination.exists() else None
                destination.write_bytes(data)
                # Keep only newly installed profiles readable while Xcode manages its store.
                if installed[destination] is None:
                    protected[destination] = destination.stat().st_flags
                    os.chflags(destination, protected[destination] | stat.UF_IMMUTABLE)
        if len(teams) != 1:
            raise RuntimeError('Signing profiles use different teams')
        team = next(iter(teams))
        delivery = os.environ.get('STRUIS_DELIVERY_APP_KEY', '')
        if '\n' in delivery or '\r' in delivery or '//' in delivery:
            raise RuntimeError('Service setting cannot be represented in this configuration')
        local.write_text(f'STRUIS_DELIVERY_APP_KEY = {delivery}\n')
        local.chmod(0o600)
        command = ['xcodebuild', 'archive', '-project', 'strius.xcodeproj', '-scheme', 'strius',
                   '-configuration', 'Release', '-destination', 'generic/platform=iOS',
                   '-derivedDataPath', str(output / 'DerivedData'), '-archivePath', str(archive),
                   f'DEVELOPMENT_TEAM={team}', 'CODE_SIGN_STYLE=Manual', f'CODE_SIGN_IDENTITY={identity[0]}',
                   'PROVISIONING_PROFILE_SPECIFIER=$(STRUIS_CI_PROFILE_$(PRODUCT_NAME))', *settings]
        if args.build_number:
            command.append(f'CURRENT_PROJECT_VERSION={args.build_number}')
        run(command, output / 'archive-private.log')
        app = archive / 'Products/Applications/strius.app'
        run(['codesign', '--verify', '--deep', '--strict', str(app)])
        audit_environment = dict(os.environ, CI_XCODEBUILD_ACTION='archive', CI_XCODEBUILD_EXIT_CODE='0',
                                 CI_ARCHIVE_PATH=str(archive), CI_DERIVED_DATA_PATH=str(output / 'DerivedData'))
        with (output / 'bundle-audit.json').open('wb') as stream:
            subprocess.run([sys.executable, 'NativeRuntime/Scripts/audit-cloud-archive.py'], cwd=ROOT,
                           env=audit_environment, stdout=stream, stderr=subprocess.STDOUT, check=True)
        info = plistlib.loads((app / 'Info.plist').read_bytes())
        if info.get('StruisDeliveryAppKey', '') != delivery:
            raise RuntimeError('Archive service configuration differs from the private input')
        record = {'sourceCommit': commit, 'version': info['CFBundleShortVersionString'],
                  'build': info['CFBundleVersion'], 'bundleIdentifier': info['CFBundleIdentifier'],
                  'signedArchiveVerified': True, 'bundleAuditPassed': True,
                  'serviceConfigured': bool(delivery), 'uploaded': False}
        if args.upload:
            options = private / 'ExportOptions.plist'
            options.write_bytes(plistlib.dumps({'method': 'app-store-connect', 'destination': 'upload',
                'teamID': team, 'signingStyle': 'manual', 'provisioningProfiles': profiles,
                'manageAppVersionAndBuildNumber': False}))
            key = private / f'AuthKey_{os.environ["APP_STORE_CONNECT_KEY_ID"]}.p8'
            key.write_text(os.environ['APP_STORE_CONNECT_PRIVATE_KEY'])
            run(['xcodebuild', '-exportArchive', '-archivePath', str(archive), '-exportPath', str(output / 'Export'),
                 '-exportOptionsPlist', str(options), '-authenticationKeyPath', str(key),
                 '-authenticationKeyID', os.environ['APP_STORE_CONNECT_KEY_ID'],
                 '-authenticationKeyIssuerID', os.environ['APP_STORE_CONNECT_ISSUER_ID']], output / 'upload-private.log')
            record['uploaded'] = True
        (output / 'provenance.json').write_text(json.dumps(record, indent=2) + '\n')
        print(json.dumps(record))
    finally:
        signal.signal(signal.SIGINT, signal.SIG_IGN)
        signal.signal(signal.SIGTERM, signal.SIG_IGN)
        subprocess.run(['security', 'list-keychains', '-d', 'user', '-s', *original_keychains], capture_output=True)
        if keychain:
            subprocess.run(['security', 'delete-keychain', str(keychain)], capture_output=True)
        for destination, flags in protected.items():
            if destination.exists():
                os.chflags(destination, flags)
        for destination, original in installed.items():
            if original is None:
                destination.unlink(missing_ok=True)
            else:
                destination.write_bytes(original)
        if local_original is None:
            local.unlink(missing_ok=True)
        else:
            local.write_bytes(local_original)
            local.chmod(0o600)
        temporary.cleanup()


if __name__ == '__main__':
    main()
