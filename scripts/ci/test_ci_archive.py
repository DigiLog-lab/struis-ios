"""App Store profiles for the archive come from the App Store Connect API (Issue #51), not from secrets."""
import base64
import datetime
import importlib.util
from pathlib import Path
import unittest


SPEC = importlib.util.spec_from_file_location("ci_archive", Path(__file__).resolve().parents[1] / "ci_archive.py")
archive = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(archive)

NOW = datetime.datetime(2026, 10, 27, tzinfo=datetime.timezone.utc)
CERT = b'certificate-der'
TEAM = 'TEAM123456'


def document(product, *, container=True, group=True, cert=CERT, devices=None, uuid='u'):
    entitlements = {'application-identifier': f'{TEAM}.{archive.PROFILE_BUNDLES[product]}',
                    'com.apple.security.application-groups': [archive.APP_GROUP] if group else []}
    if container:
        entitlements[archive.CONTAINERS_KEY] = [archive.ICLOUD_CONTAINER]
    profile = {'TeamIdentifier': [TEAM], 'Entitlements': entitlements, 'DeveloperCertificates': [cert], 'UUID': uuid}
    if devices:
        profile['ProvisionedDevices'] = devices
    return profile


def resource(key, *, state='ACTIVE', kind='IOS_APP_STORE', expires='2027-10-01T00:00:00.000+0000'):
    return {'id': key, 'attributes': {'profileType': kind, 'profileState': state, 'expirationDate': expires,
                                      'profileContent': base64.b64encode(key.encode()).decode()}}


class FakeConnect:
    def __init__(self, profiles, documents, created=None):
        self.profiles = profiles
        self.documents = documents
        self.created_documents = created or {}
        self.created = []

    def distribution_certificates(self):
        return [{'id': 'cert-1', 'attributes': {'serialNumber': '00ABC'}}]

    def find_bundle_id(self, identifier):
        return {'id': identifier}

    def profiles_for(self, bundle):
        return self.profiles.get(bundle['id'], [])

    def create_profile(self, name, bundle, certificate_ids, profile_type):
        self.created.append((bundle['id'], certificate_ids, profile_type))
        key = f"new-{bundle['id']}"
        self.documents[key] = self.created_documents[bundle['id']]
        return resource(key)


def ensure(connect):
    return archive.ensure_store_profiles(connect, CERT, 'ABC', lambda data: connect.documents[data.decode()], now=NOW)


class StoreProfileTests(unittest.TestCase):
    def all_reusable(self):
        profiles, documents = {}, {}
        for product, bundle in archive.PROFILE_BUNDLES.items():
            profiles[bundle] = [resource(f'ok-{product}')]
            documents[f'ok-{product}'] = document(product, container=product == 'strius', uuid=product)
        return profiles, documents

    def test_reuses_an_active_profile_with_the_certificate_group_and_container(self):
        profiles, documents = self.all_reusable()
        connect = FakeConnect(profiles, documents)
        result = ensure(connect)
        self.assertEqual({product: entry[1]['UUID'] for product, entry in result.items()},
                         {product: product for product in archive.PROFILE_BUNDLES})
        self.assertEqual(connect.created, [])

    def test_an_invalidated_or_expiring_profile_is_replaced(self):
        profiles, documents = self.all_reusable()
        app = archive.PROFILE_BUNDLES['strius']
        profiles[app] = [resource('ok-strius', state='INVALID'), resource('soon', expires='2026-10-30T00:00:00.000+0000')]
        documents['soon'] = document('strius')
        connect = FakeConnect(profiles, documents, created={app: document('strius', uuid='fresh')})
        result = ensure(connect)
        self.assertEqual(result['strius'][1]['UUID'], 'fresh')
        self.assertEqual(connect.created, [(app, ['cert-1'], 'IOS_APP_STORE')])

    def test_the_app_profile_needs_the_icloud_container(self):
        profiles, documents = self.all_reusable()
        app = archive.PROFILE_BUNDLES['strius']
        documents['ok-strius'] = document('strius', container=False)
        connect = FakeConnect(profiles, documents, created={app: document('strius', uuid='with-container')})
        self.assertEqual(ensure(connect)['strius'][1]['UUID'], 'with-container')

    def test_a_new_profile_without_the_container_asks_for_the_portal(self):
        profiles, documents = self.all_reusable()
        app = archive.PROFILE_BUNDLES['strius']
        profiles[app] = []
        connect = FakeConnect(profiles, documents, created={app: document('strius', container=False)})
        with self.assertRaisesRegex(RuntimeError, 'iCloud container .* Developer portal'):
            ensure(connect)

    def test_other_certificates_ad_hoc_profiles_and_missing_groups_are_not_reused(self):
        profiles, documents = self.all_reusable()
        runtime = archive.PROFILE_BUNDLES['StruisRuntime']
        profiles[runtime] = [resource('other-cert'), resource('adhoc', kind='IOS_APP_ADHOC'), resource('no-group')]
        documents['other-cert'] = document('StruisRuntime', cert=b'other')
        documents['adhoc'] = document('StruisRuntime', devices=['device'])
        documents['no-group'] = document('StruisRuntime', group=False)
        connect = FakeConnect(profiles, documents, created={runtime: document('StruisRuntime', container=False, uuid='runtime-new')})
        self.assertEqual(ensure(connect)['StruisRuntime'][1]['UUID'], 'runtime-new', 'extensions do not need the container')

    def test_no_profile_secrets_are_read(self):
        source = (Path(__file__).resolve().parents[1] / 'ci_archive.py').read_text()
        self.assertNotIn('BUILD_PROVISION_PROFILE', source)


if __name__ == '__main__':
    unittest.main()
