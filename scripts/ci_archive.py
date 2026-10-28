#!/usr/bin/env python3
"""Build a signed archive from the checked-out commit using private CI inputs.

The App Store profiles of the three bundles come from the App Store Connect API
(as in scripts/agent/prototype.py): an active profile with the distribution
certificate, at least a week of validity and the required entitlements is reused,
otherwise one is created. Adding a capability to an App ID (iCloud for sync,
Issue #51) invalidates the old profiles; they are replaced here without new secrets.
"""
import argparse
import base64
import datetime
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
sys.path.insert(0, str(ROOT / 'scripts/agent'))
from appstoreconnect import AppStoreConnect  # noqa: E402

PROFILE_BUNDLES = {  # Xcode product name -> bundle ID
    'strius': 'com.digiloglab.strius',
    'StruisRuntime': 'com.digiloglab.strius.runtime',
    'StruisExec': 'com.digiloglab.strius.exec',
}
APP_GROUP = 'group.com.digiloglab.struis.runtime'
ICLOUD_CONTAINER = 'iCloud.com.digiloglab.strius'
CONTAINERS_KEY = 'com.apple.developer.icloud-container-identifiers'
PROFILE_MIN_DAYS = 7


def profile_problem(document, product, certificate_der):
    """Why an App Store profile cannot sign `product`, or None."""
    entitlements = document.get('Entitlements', {})
    team = (document.get('TeamIdentifier') or [''])[0]
    if entitlements.get('application-identifier') != f'{team}.{PROFILE_BUNDLES[product]}' or entitlements.get('get-task-allow'):
        return 'bundle'
    if document.get('ProvisionedDevices'):
        return 'devices'
    if certificate_der not in document.get('DeveloperCertificates', []):
        return 'certificate'
    if APP_GROUP not in entitlements.get('com.apple.security.application-groups', []):
        return 'app-group'
    if product == 'strius' and ICLOUD_CONTAINER not in entitlements.get(CONTAINERS_KEY, []):
        return 'icloud'
    return None


def ensure_store_profiles(asc, certificate_der, serial, decode, now=None):
    """App Store profiles for the three bundles: product -> (profile bytes, decoded profile)."""
    now = now or datetime.datetime.now(datetime.timezone.utc)
    horizon = (now + datetime.timedelta(days=PROFILE_MIN_DAYS)).strftime('%Y-%m-%dT%H:%M:%S')
    certificates = [cert for cert in asc.distribution_certificates()
                    if (cert['attributes'].get('serialNumber') or '').upper().lstrip('0') == serial]
    if not certificates:
        raise RuntimeError('The distribution certificate is not registered in App Store Connect')
    profiles = {}
    for product, identifier in PROFILE_BUNDLES.items():
        bundle = asc.find_bundle_id(identifier)
        if not bundle:
            raise RuntimeError(f'App ID {identifier} is missing')
        chosen = None
        candidates = sorted(asc.profiles_for(bundle), key=lambda item: item['attributes'].get('expirationDate') or '', reverse=True)
        for profile in candidates:
            attributes = profile['attributes']
            # An App ID change (a new capability) makes its profiles INVALID; they are never reused.
            if (attributes.get('profileType') != 'IOS_APP_STORE' or attributes.get('profileState') != 'ACTIVE'
                    or (attributes.get('expirationDate') or '')[:19] <= horizon):
                continue
            data = base64.b64decode(attributes['profileContent'])
            document = decode(data)
            if profile_problem(document, product, certificate_der) is None:
                chosen = (data, document)
                break
        if not chosen:
            created = asc.create_profile(f'Struis App Store {product} {now:%y%m%d%H%M%S}', bundle,
                                         [certificates[0]['id']], 'IOS_APP_STORE')
            data = base64.b64decode(created['attributes']['profileContent'])
            document = decode(data)
            problem = profile_problem(document, product, certificate_der)
            if problem == 'icloud':
                raise RuntimeError(f'App ID {identifier} has no iCloud container {ICLOUD_CONTAINER}. '
                                   'Assign it on the Developer portal and run again.')
            if problem == 'app-group':
                raise RuntimeError(f'App ID {identifier} has no App Group {APP_GROUP}. '
                                   'Assign it on the Developer portal and run again.')
            if problem:
                raise RuntimeError(f'The new App Store profile for {product} does not match ({problem})')
            chosen = (data, document)
        profiles[product] = chosen
    return profiles


def certificate_identity(p12_path, password):
    """DER bytes and serial number (uppercase hex, no leading zeros) of the signing certificate."""
    environment = {**os.environ, 'P12_PASSWORD': password}
    command = ['openssl', 'pkcs12', '-in', str(p12_path), '-clcerts', '-nokeys', '-passin', 'env:P12_PASSWORD']
    pem = subprocess.run(command, capture_output=True, env=environment)
    if pem.returncode:
        pem = subprocess.run(command[:2] + ['-legacy'] + command[2:], capture_output=True, env=environment)
    der = subprocess.run(['openssl', 'x509', '-outform', 'DER'], input=pem.stdout, capture_output=True)
    serial = subprocess.run(['openssl', 'x509', '-noout', '-serial'], input=pem.stdout, capture_output=True)
    if pem.returncode or der.returncode or serial.returncode:
        raise RuntimeError('The distribution certificate cannot be read')
    return der.stdout, serial.stdout.decode().strip().split('=', 1)[1].upper().lstrip('0')


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
    if not all(os.environ.get(name) for name in auth_names):
        raise RuntimeError('App Store Connect authentication (all three inputs) is required for the signing profiles')
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
        api_key = private / f'AuthKey_{os.environ["APP_STORE_CONNECT_KEY_ID"].strip()}.p8'
        api_key.write_text(os.environ['APP_STORE_CONNECT_PRIVATE_KEY'].replace('\r', '').strip() + '\n')
        asc = AppStoreConnect(str(api_key), os.environ['APP_STORE_CONNECT_KEY_ID'].strip(),
                              os.environ['APP_STORE_CONNECT_ISSUER_ID'].strip())
        certificate_der, serial = certificate_identity(certificate, os.environ['P12_PASSWORD'])
        scratch = private / 'decode.mobileprovision'

        def decode(data):
            scratch.write_bytes(data)
            return plistlib.loads(run(['security', 'cms', '-D', '-i', str(scratch)]))

        profiles = {}
        teams = set()
        settings = []
        for product, (data, profile) in ensure_store_profiles(asc, certificate_der, serial, decode).items():
            bundle = PROFILE_BUNDLES[product]
            teams.add(profile['TeamIdentifier'][0])
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
            run(['xcodebuild', '-exportArchive', '-archivePath', str(archive), '-exportPath', str(output / 'Export'),
                 '-exportOptionsPlist', str(options), '-authenticationKeyPath', str(api_key),
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
