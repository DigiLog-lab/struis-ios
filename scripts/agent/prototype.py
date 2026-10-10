#!/usr/bin/env python3
"""Ad Hoc prototype builds for .github/workflows/agent-prototype.yml.

Each prototype (Issue number + variant) owns one identifier slot: an app
Bundle ID with `.runtime` and `.exec` extension IDs and a dedicated App Group.
App Store Connect API keys cannot create App Groups or attach them to App IDs
(the Xcode provisioning endpoint `appGroups` answers 401 for API keys), so the
App Groups of a slot are registered once on the developer portal. Everything
else - App IDs, capabilities, devices, Ad Hoc profiles, signing, IPA, upload and
install links - is automated here.

Commands: register-slots, allocate, build, report-failure.
"""
import argparse
import base64
import datetime
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import secrets
import shlex
import shutil
import signal
import subprocess
import sys
import tempfile

sys.path.insert(0, str(Path(__file__).resolve().parent))
from agentlib import (  # noqa: E402
    GitHub, PROTOTYPE_MARKER, STORE_URL, Store, StoreError, append_summary, iso, run_url, utc_now, write_output)
from appstoreconnect import AppStoreConnect  # noqa: E402

PREFIX = os.environ.get('AGENT_BUNDLE_PREFIX', 'com.digiloglab.strius.preview')
SLOTS_KEY = 'prototypes/slots.json'
COMPONENTS = {  # Xcode product name -> bundle suffix
    'strius': '',
    'StruisRuntime': '.runtime',
    'StruisExec': '.exec',
}
WORKER_SOURCE = 'NativeRuntime/Worker/RuntimeWorker.swift'
WORKER_LITERAL = 'AppExtensionPoint.Identifier(host: "com.digiloglab.strius", name: "Runtime")'
ICON = 'strius/Assets.xcassets/AppIcon.appiconset/app-icon-1024.png'
TOOLS = Path(__file__).resolve().parent


def workspace():
    return Path(os.environ.get('GITHUB_WORKSPACE', os.getcwd()))


def home():
    path = Path(os.environ.get('RUNNER_TEMP', tempfile.gettempdir())) / 'prototype'
    path.mkdir(parents=True, exist_ok=True)
    return path


def slot_name(number):
    return f's{number:02d}'


def slot_record(name):
    base = f'{PREFIX}.{name}'
    return {'bundleBase': base, 'appGroup': f'group.{base}'}


def meta_key(issue, variant):
    return f'prototypes/{issue}/{variant}/meta.json'


def event(store, issue, variant, status, note=None):
    stamp = utc_now().strftime('%Y%m%dT%H%M%S%fZ')
    store.put_json(f'prototypes/{issue}/{variant}/events/{stamp}-workflow.json',
                   {'status': status, 'note': note, 'at': iso(), 'source': 'workflow', 'run': run_url()})


def asc_client(private_dir):
    key = private_dir / 'AuthKey.p8'
    key.write_text(os.environ['APP_STORE_CONNECT_PRIVATE_KEY'].replace('\r', '').strip() + '\n')
    key.chmod(0o600)
    return AppStoreConnect(str(key), os.environ['APP_STORE_CONNECT_KEY_ID'].strip(),
                           os.environ['APP_STORE_CONNECT_ISSUER_ID'].strip())


# ------------------------------------------------------------- register ---

def cmd_register_slots(args):
    """Create the App IDs of new slots and list the portal steps that remain."""
    store = Store()
    with tempfile.TemporaryDirectory(prefix='asc-') as private:
        asc = asc_client(Path(private))
        registry, _ = store.get_json_with_etag(SLOTS_KEY)
        existing = (registry or {}).get('slots', {})
        names = [slot_name(index) for index in range(1, args.count + 1)]
        created = []
        for name in names:
            record = slot_record(name)
            for product, suffix in COMPONENTS.items():
                identifier = record['bundleBase'] + suffix
                label = f"Struis Preview {name.upper()} {product.replace('Struis', '') or 'App'}"
                bundle, new = asc.ensure_bundle_id(identifier, label)
                asc.ensure_capability(bundle, 'APP_GROUPS')
                if new:
                    created.append(identifier)

        def change(document):
            document = document or {'version': 1, 'prefix': PREFIX, 'slots': {}}
            for name in names:
                document['slots'].setdefault(name, {**slot_record(name), 'registeredAt': iso(), 'assigned': None})
            return document

        registry = store.update_json(SLOTS_KEY, change)
    pending = [name for name in names if name not in existing]
    lines = ['### Prototype slots',
             f'- App IDs created: {len(created)}',
             f"- slots: {', '.join(sorted(registry['slots']))}",
             '- Developer portal (once per slot): register each App Group below and enable it on the three App IDs.']
    for name in pending or names:
        record = registry['slots'][name]
        lines.append(f"  - `{record['appGroup']}` → `{record['bundleBase']}`, `.runtime`, `.exec`")
    append_summary('\n'.join(lines))
    print('\n'.join(lines))


# ------------------------------------------------------------- allocate ---

def cmd_allocate(args):
    """Keep the prototype's slot, or assign the next unused slot to a new prototype."""
    store = Store()
    issue, variant = args.issue, args.variant
    meta, _ = store.get_json_with_etag(meta_key(issue, variant))
    if not meta:
        assigned = {}

        def take(document):
            if not document:
                raise SystemExit('Prototype slots are not registered. Run agent-prototype.yml with operation=register-slots.')
            for name, record in sorted(document['slots'].items()):
                owner = record.get('assigned')
                if owner and owner.get('issue') == issue and owner.get('variant') == variant:
                    assigned.update(name=name, **record)
                    return document
            for name, record in sorted(document['slots'].items()):
                if not record.get('assigned') and not record.get('retired'):
                    record['assigned'] = {'issue': issue, 'variant': variant, 'at': iso()}
                    assigned.update(name=name, **record)
                    return document
            raise SystemExit('NO_FREE_SLOT')

        try:
            store.update_json(SLOTS_KEY, take)
        except SystemExit as error:
            if str(error) == 'NO_FREE_SLOT':
                write_output('error', 'no-free-slot')
                raise SystemExit('未使用のプロトタイプ枠がありません。register-slots で枠を追加し、App Group を登録してください。')
            raise
        meta = {
            'issue': issue, 'variant': variant, 'slot': assigned['name'],
            'bundleId': assigned['bundleBase'], 'appGroup': assigned['appGroup'],
            'branch': args.ref, 'title': args.title, 'summary': args.summary,
            'createdAt': iso(), 'builds': [],
        }
        try:
            store.put_json(meta_key(issue, variant), meta, if_none_match=True)
        except StoreError:
            meta, _ = store.get_json_with_etag(meta_key(issue, variant))
    else:
        def refresh(document):
            document['branch'] = args.ref
            document['title'] = args.title or document.get('title')
            document['summary'] = args.summary or document.get('summary')
            return document
        meta = store.update_json(meta_key(issue, variant), refresh)
    event(store, issue, variant, 'building', args.summary)
    write_output('bundle_id', meta['bundleId'])
    write_output('app_group', meta['appGroup'])
    write_output('slot', meta['slot'])
    print(json.dumps(meta, ensure_ascii=False, indent=2))


# ---------------------------------------------------------------- build ---

def run(command, log=None, cwd=None, env=None):
    printable = ' '.join(shlex.quote(str(part)) for part in command)
    print(f'$ {printable[:400]}', flush=True)
    if log:
        with open(log, 'wb') as stream:
            result = subprocess.run([str(part) for part in command], cwd=cwd, env=env, stdout=stream, stderr=subprocess.STDOUT)
        if result.returncode:
            lines = Path(log).read_text(errors='replace').splitlines()
            errors = [line for line in lines if 'error:' in line.lower() or 'failed' in line.lower()][-25:]
            raise BuildError(f'{Path(str(command[0])).name} {command[1] if len(command) > 1 else ""} exit {result.returncode}',
                             '\n'.join(errors or lines[-25:]))
        return None
    result = subprocess.run([str(part) for part in command], cwd=cwd, env=env, capture_output=True)
    if result.returncode:
        raise BuildError(f'{Path(str(command[0])).name} exit {result.returncode}',
                         result.stderr.decode(errors='replace')[-2000:])
    return result.stdout


SENSITIVE = ('P12_PASSWORD', 'STRUIS_DELIVERY_APP_KEY', 'APP_STORE_CONNECT_PRIVATE_KEY', 'BUILD_CERTIFICATE_BASE64')


def redact(text):
    for name in SENSITIVE:
        for part in (os.environ.get(name) or '').splitlines():
            if len(part.strip()) >= 6:
                text = text.replace(part.strip(), '[redacted]')
    return re.sub(r'(STRUIS_DELIVERY_APP_KEY\\?=)\S+', r'\1[redacted]', text)


class BuildError(RuntimeError):
    def __init__(self, summary, detail=''):
        super().__init__(summary)
        self.summary = redact(summary)
        self.detail = redact(detail)


def certificate_serial(p12_path, password):
    pem = subprocess.run(['openssl', 'pkcs12', '-in', p12_path, '-clcerts', '-nokeys', '-passin', 'env:P12_PASSWORD'],
                         capture_output=True, env={**os.environ, 'P12_PASSWORD': password})
    if pem.returncode:
        pem = subprocess.run(['openssl', 'pkcs12', '-legacy', '-in', p12_path, '-clcerts', '-nokeys', '-passin',
                              'env:P12_PASSWORD'], capture_output=True, env={**os.environ, 'P12_PASSWORD': password})
    serial = subprocess.run(['openssl', 'x509', '-noout', '-serial'], input=pem.stdout, capture_output=True, check=True)
    return serial.stdout.decode().strip().split('=', 1)[1].upper().lstrip('0')


def ensure_profiles(asc, meta, serial, private):
    """Ad Hoc profiles for the three bundles with every enabled device."""
    certificates = [cert for cert in asc.distribution_certificates()
                    if (cert['attributes'].get('serialNumber') or '').upper().lstrip('0') == serial]
    if not certificates:
        raise BuildError('provisioning', '署名証明書が App Store Connect の配布証明書に見つかりません。')
    certificate_id = certificates[0]['id']
    devices = asc.enabled_devices()
    if not devices:
        raise BuildError('provisioning', 'Ad Hoc 配布先として有効な端末が登録されていません。')
    device_ids = sorted(device['id'] for device in devices)
    fingerprint = hashlib.sha256(('|'.join(device_ids) + certificate_id).encode()).hexdigest()[:8]
    profiles = {}
    for product, suffix in COMPONENTS.items():
        identifier = meta['bundleId'] + suffix
        bundle = asc.find_bundle_id(identifier)
        if not bundle:
            raise BuildError('provisioning', f'App ID {identifier} がありません。register-slots を実行してください。')
        name = f"Struis Preview {meta['slot'].upper()}{suffix.replace('.', ' ').title()} AdHoc {fingerprint}"
        path = private / f'{product}.mobileprovision'

        def decode(profile):
            path.write_bytes(base64.b64decode(profile['attributes']['profileContent']))
            document = plistlib.loads(run(['security', 'cms', '-D', '-i', path]))
            return document, meta['appGroup'] in document['Entitlements'].get('com.apple.security.application-groups', [])

        reusable = None
        horizon = (utc_now() + datetime.timedelta(days=7)).isoformat()
        for profile in asc.profiles_for(bundle):
            attributes = profile['attributes']
            if ((attributes.get('name') or '').startswith(name) and attributes.get('profileState') == 'ACTIVE'
                    and attributes.get('profileType') == 'IOS_APP_ADHOC' and (attributes.get('expirationDate') or '') > horizon):
                decoded, has_group = decode(profile)
                if has_group:
                    reusable = profile
                    break
        if not reusable:
            created = asc.create_adhoc_profile(f"{name} {utc_now():%y%m%d%H%M%S}", bundle, [certificate_id], device_ids)
            decoded, has_group = decode(created)
            if not has_group:
                raise BuildError('provisioning',
                                 f"App ID {identifier} に App Group {meta['appGroup']} が割り当てられていません。"
                                 'Developer ポータルで App Groups を設定してから再実行してください。')
        else:
            decoded, _ = decode(reusable)
        profiles[product] = {'uuid': decoded['UUID'], 'name': decoded['Name'], 'path': path, 'bundle': identifier,
                             'expires': decoded['ExpirationDate'].isoformat(), 'devices': len(decoded.get('ProvisionedDevices', [])),
                             'reused': bool(reusable)}
    return profiles, len(device_ids)


def patch_workspace(meta, build_number, root):
    """Prototype identity lives only in this disposable checkout."""
    worker = root / WORKER_SOURCE
    source = worker.read_text()
    if source.count(WORKER_LITERAL) != 1:
        raise BuildError('patch', f'{WORKER_SOURCE} の拡張ポイント宣言が想定と異なります。')
    worker.write_text(source.replace(WORKER_LITERAL, WORKER_LITERAL.replace('"com.digiloglab.strius"', f'"{meta["bundleId"]}"')))
    info_path = root / 'Info.plist'
    info = plistlib.loads(info_path.read_bytes())
    label = f"{meta['issue']}{meta['variant'].upper()}"
    info['CFBundleDisplayName'] = f'{label} Struis'
    info_path.write_bytes(plistlib.dumps(info))
    run(['swift', TOOLS / 'badge_icon.swift', root / ICON, f"#{meta['issue']} {meta['variant'].upper()}"])
    local = root / 'Config/Local.xcconfig'
    delivery = os.environ.get('STRUIS_DELIVERY_APP_KEY', '')
    if any(character in delivery for character in '\r\n') or '//' in delivery:
        raise BuildError('patch', '配信キーを xcconfig で表現できません。')
    local.write_text(f'STRUIS_DELIVERY_APP_KEY = {delivery}\n')
    local.chmod(0o600)
    return info['CFBundleDisplayName']


def terminate(signum, _frame):
    raise SystemExit(128 + signum)


def cmd_build(args):
    issue, variant = args.issue, args.variant
    store = Store()
    root = workspace()
    out = home()
    meta = store.get_json(meta_key(issue, variant))
    if not meta:
        raise SystemExit('allocate has not run')
    build_number = max([int(build['buildNumber']) for build in meta.get('builds', [])] + [0]) + 1
    commit = subprocess.run(['git', '-C', str(root), 'rev-parse', 'HEAD'], capture_output=True, text=True, check=True).stdout.strip()
    record = {
        'issue': issue, 'variant': variant, 'prototypeId': variant.upper(), 'slot': meta['slot'],
        'bundleId': meta['bundleId'], 'appGroup': meta['appGroup'], 'branch': args.ref, 'commit': commit,
        'buildNumber': build_number, 'title': meta.get('title'), 'summary': meta.get('summary'),
        'run': run_url(), 'startedAt': iso(), 'result': 'failure', 'stage': 'provisioning',
    }
    (out / 'record.json').write_text(json.dumps(record, ensure_ascii=False, indent=2))
    original_keychains = shlex.split(run(['security', 'list-keychains', '-d', 'user']).decode())
    installed = []
    keychain = None
    private_dir = tempfile.TemporaryDirectory(prefix='prototype-signing-')
    signal.signal(signal.SIGTERM, terminate)
    try:
        private = Path(private_dir.name)
        os.umask(0o077)
        asc = asc_client(private)
        p12 = private / 'distribution.p12'
        p12.write_bytes(base64.b64decode(os.environ['BUILD_CERTIFICATE_BASE64'], validate=True))
        profiles, device_count = ensure_profiles(asc, meta, certificate_serial(p12, os.environ['P12_PASSWORD']), private)

        keychain = private / 'prototype.keychain-db'
        password = secrets.token_urlsafe(32)
        run(['security', 'create-keychain', '-p', password, keychain])
        run(['security', 'set-keychain-settings', '-lut', '21600', keychain])
        run(['security', 'unlock-keychain', '-p', password, keychain])
        run(['security', 'import', p12, '-k', keychain, '-P', os.environ['P12_PASSWORD'], '-T', '/usr/bin/codesign'])
        run(['security', 'set-key-partition-list', '-S', 'apple-tool:,apple:,codesign:', '-s', '-k', password, keychain])
        run(['security', 'list-keychains', '-d', 'user', '-s', keychain, *original_keychains])
        identities = re.findall(r'\b[0-9A-F]{40}\b', run(['security', 'find-identity', '-v', '-p', 'codesigning', keychain]).decode())
        if len(identities) != 1:
            raise BuildError('signing', '配布用の署名 identity を1つに特定できません。')
        for product, profile in profiles.items():
            for directory in (Path.home() / 'Library/MobileDevice/Provisioning Profiles',
                              Path.home() / 'Library/Developer/Xcode/UserData/Provisioning Profiles'):
                directory.mkdir(parents=True, exist_ok=True)
                destination = directory / f"{profile['uuid']}.mobileprovision"
                shutil.copyfile(profile['path'], destination)
                installed.append(destination)

        record['stage'] = 'patch'
        display_name = patch_workspace(meta, build_number, root)
        record['displayName'] = display_name

        record['stage'] = 'archive'
        team = plistlib.loads(run(['security', 'cms', '-D', '-i', profiles['strius']['path']]))['TeamIdentifier'][0]
        archive = out / 'Prototype.xcarchive'
        settings = [f"STRUIS_CI_PROFILE_{product}={profile['uuid']}" for product, profile in profiles.items()]
        run(['xcodebuild', 'archive', '-project', 'strius.xcodeproj', '-scheme', 'strius', '-configuration', 'Release',
             '-destination', 'generic/platform=iOS', '-derivedDataPath', out / 'DerivedData', '-archivePath', archive,
             f'DEVELOPMENT_TEAM={team}', 'CODE_SIGN_STYLE=Manual', f'CODE_SIGN_IDENTITY={identities[0]}',
             'PROVISIONING_PROFILE_SPECIFIER=$(STRUIS_CI_PROFILE_$(PRODUCT_NAME))', *settings,
             f"STRUIS_BUNDLE_ID_BASE={meta['bundleId']}", f"STRUIS_APP_GROUP={meta['appGroup']}",
             f'CURRENT_PROJECT_VERSION={build_number}'], log=out / 'archive.log', cwd=root)

        record['stage'] = 'export'
        options = private / 'ExportOptions.plist'
        options.write_bytes(plistlib.dumps({
            'method': 'release-testing', 'signingStyle': 'manual', 'teamID': team, 'thinning': '<none>',
            'provisioningProfiles': {profile['bundle']: profile['uuid'] for profile in profiles.values()},
            'signingCertificate': identities[0], 'manageAppVersionAndBuildNumber': False}))
        export = out / 'Export'
        run(['xcodebuild', '-exportArchive', '-archivePath', archive, '-exportPath', export,
             '-exportOptionsPlist', options], log=out / 'export.log', cwd=root)
        ipa = next(export.glob('*.ipa'))

        record['stage'] = 'verify'
        verify = out / 'verify'
        shutil.rmtree(verify, ignore_errors=True)
        run(['ditto', '-x', '-k', ipa, verify])
        app = next((verify / 'Payload').glob('*.app'))
        run(['codesign', '--verify', '--deep', '--strict', app])
        info = plistlib.loads((app / 'Info.plist').read_bytes())
        checks = {app: (meta['bundleId'], 'strius')}
        for extension in (app / 'Extensions').glob('*.appex'):
            product = extension.stem
            checks[extension] = (meta['bundleId'] + COMPONENTS[product], product)
        for bundle, (identifier, product) in checks.items():
            bundle_info = plistlib.loads((bundle / 'Info.plist').read_bytes())
            entitlements = plistlib.loads(run(['codesign', '-d', '--entitlements', ':-', bundle]) or b'<plist><dict/></plist>')
            embedded = plistlib.loads(run(['security', 'cms', '-D', '-i', bundle / 'embedded.mobileprovision']))
            if bundle_info.get('CFBundleIdentifier') != identifier:
                raise BuildError('verify', f'{bundle.name} の Bundle ID が {identifier} ではありません。')
            if entitlements.get('com.apple.security.application-groups') != [meta['appGroup']]:
                raise BuildError('verify', f'{bundle.name} の App Group が想定と異なります。')
            if embedded['UUID'] != profiles[product]['uuid'] or entitlements.get('get-task-allow'):
                raise BuildError('verify', f'{bundle.name} の provisioning profile が想定と異なります。')
            point = (bundle_info.get('EXAppExtensionAttributes') or {}).get('EXExtensionPointIdentifier')
            if bundle is not app and point != f"{meta['bundleId']}.Runtime":
                raise BuildError('verify', f'{bundle.name} の拡張ポイントが {point} です。')
        if set(checks) != {app, app / 'Extensions/StruisRuntime.appex', app / 'Extensions/StruisExec.appex'}:
            raise BuildError('verify', 'IPA の extension 構成が想定と異なります。')

        record['stage'] = 'upload'
        record.update({
            'version': info['CFBundleShortVersionString'], 'buildNumber': int(info['CFBundleVersion']),
            'displayName': info.get('CFBundleDisplayName'), 'ipaBytes': ipa.stat().st_size,
            'ipaSha256': hashlib.sha256(ipa.read_bytes()).hexdigest(), 'devices': device_count,
            'profiles': {product: {key: value for key, value in profile.items() if key != 'path'} for product, profile in profiles.items()},
            'generatedAt': iso(),
        })
        prefix = f'prototypes/{issue}/{variant}/builds/{build_number}'
        store.upload_file(f'{prefix}/app.ipa', ipa, 'application/octet-stream')
        record['result'] = 'success'
        record['stage'] = 'done'
        store.put_json(f'{prefix}/build.json', record)
        (out / 'record.json').write_text(json.dumps(record, ensure_ascii=False, indent=2))
    except BuildError as error:
        record['error'] = {'summary': error.summary, 'detail': error.detail}
        (out / 'record.json').write_text(json.dumps(record, ensure_ascii=False, indent=2))
        print(f'::error::{error.summary}: {error.detail[:500]}')
        raise SystemExit(1)
    finally:
        subprocess.run(['security', 'list-keychains', '-d', 'user', '-s', *original_keychains], capture_output=True)
        if keychain:
            subprocess.run(['security', 'delete-keychain', str(keychain)], capture_output=True)
        for path in installed:
            path.unlink(missing_ok=True)
        local = root / 'Config/Local.xcconfig'
        local.unlink(missing_ok=True)
        private_dir.cleanup()


# --------------------------------------------------------------- report ---

def screenshot_link(store, out):
    shot = out / 'screenshot.png'
    if not shot.exists():
        return None
    token = secrets.token_urlsafe(24)
    store.upload_file(f'media/{token}/prototype.png', shot, 'image/png')
    return f'{STORE_URL}/media/{token}/prototype.png'


def cmd_report(args):
    """Record the outcome and post the install link (or the failure) to the Issue."""
    issue, variant = args.issue, args.variant
    store = Store()
    out = home()
    record_path = out / 'record.json'
    record = json.loads(record_path.read_text()) if record_path.exists() else {
        'issue': issue, 'variant': variant, 'prototypeId': variant.upper(), 'result': 'failure',
        'stage': 'setup', 'run': run_url(), 'branch': args.ref}
    meta = store.get_json(meta_key(issue, variant)) or {}
    label = f"Prototype {variant.upper()}"
    title = record.get('title') or meta.get('title') or ''
    repository = os.environ.get('GITHUB_REPOSITORY', '')
    server = os.environ.get('GITHUB_SERVER_URL', 'https://github.com')
    commit = record.get('commit')
    commit_link = f'[{commit[:7]}]({server}/{repository}/commit/{commit})' if commit else '-'
    marker = f'{PROTOTYPE_MARKER}\n<!-- prototype={variant} -->'
    if record.get('result') == 'success':
        def append(document):
            document.setdefault('builds', [])
            if not any(int(build['buildNumber']) == int(record['buildNumber']) for build in document['builds']):
                document['builds'].append({key: record.get(key) for key in (
                    'buildNumber', 'version', 'commit', 'generatedAt', 'result', 'run', 'ipaBytes')})
            return document
        store.update_json(meta_key(issue, variant), append)
        event(store, issue, variant, 'ready', f"build {record['buildNumber']}")
        links = store.sign_install(issue, variant, record['buildNumber'])
        shot = screenshot_link(store, out)
        body = [marker,
                f'### 🧪 {label}: {title} — 配布可能',
                record.get('summary') or meta.get('summary') or '',
                '',
                f"**[インストールページを開く]({links['installUrl']})**(登録済み iPhone の Safari で開いてください)",
                '',
                '| 項目 | 値 |', '|---|---|',
                f"| Prototype ID | `{variant.upper()}` (Issue #{issue}) |",
                f"| 表示名 | `{record.get('displayName')}` |",
                f"| Bundle ID | `{record['bundleId']}` |",
                f"| App Group | `{record['appGroup']}` |",
                f"| Version (Build) | {record['version']} ({record['buildNumber']}) |",
                f"| Commit | {commit_link} (`{record.get('branch')}`) |",
                f"| 署名 | Ad Hoc / 登録端末 {record.get('devices')} 台 |",
                f"| IPA | {round(record.get('ipaBytes', 0) / 1048576, 1)} MB / sha256 `{record.get('ipaSha256', '')[:12]}` |",
                f"| リンク有効期限 | {links['expiresAt']} |",
                f"| ビルド | [Actions]({record['run']}) |",
                '',
                f"<img src=\"{links['qrUrl']}\" width=\"180\" alt=\"インストールページの QR コード\">"]
        if shot:
            body += ['', f'<img src="{shot}" width="280" alt="{label} の起動画面(Simulator)">']
        body += ['', '同じ ID のまま修正・再配布できます。他の案はそのまま残ります。']
        append_summary(f"### {label}\n- result: success\n- bundle: `{record['bundleId']}`\n- build: {record['buildNumber']}\n- install: {links['installUrl']}")
    else:
        event(store, issue, variant, 'failed', f"{record.get('stage')}: {(record.get('error') or {}).get('summary')}")
        error = record.get('error') or {}
        body = [marker,
                f'### ⚠️ {label}: {title} — ビルド失敗',
                '',
                f"- 段階: `{record.get('stage')}`",
                f"- 原因: {error.get('summary') or '実行ログを参照してください'}",
                f"- 実行ログ: {record.get('run') or run_url()}",
                f"- Commit: {commit_link} (`{record.get('branch')}`)",
                '- 再実行: このIssueで修正や再ビルドを依頼してください。Actions の「Re-run jobs」でも同じ入力で再実行できます。']
        if error.get('detail'):
            body += ['', '```', error['detail'][-3000:], '```']
        append_summary(f"### {label}\n- result: failure at {record.get('stage')}\n- {error.get('summary')}")
    GitHub().comment(issue, '\n'.join(body))
    if record.get('result') != 'success':
        raise SystemExit(1)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest='command', required=True)
    register = commands.add_parser('register-slots')
    register.add_argument('--count', type=int, required=True)
    register.set_defaults(func=cmd_register_slots)
    for name, func in (('allocate', cmd_allocate), ('build', cmd_build), ('report', cmd_report)):
        command = commands.add_parser(name)
        command.add_argument('--issue', type=int, required=True)
        command.add_argument('--variant', required=True)
        command.add_argument('--ref', required=True)
        command.add_argument('--title', default='')
        command.add_argument('--summary', default='')
        command.set_defaults(func=func)
    args = parser.parse_args()
    if hasattr(args, 'variant') and not re.fullmatch(r'[a-z][a-z0-9]{0,7}', args.variant):
        raise SystemExit('variant must be lowercase letters/digits starting with a letter')
    args.func(args)


if __name__ == '__main__':
    main()
