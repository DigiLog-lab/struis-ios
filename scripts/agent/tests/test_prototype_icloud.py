"""Prototype signing with the iCloud container of iCloud sync (Issue #51)."""
import argparse
import base64
import datetime
import hashlib
from pathlib import Path
import plistlib
import sys
import tempfile
import unittest
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
sys.path.insert(0, str(Path(__file__).resolve().parent))
import prototype  # noqa: E402
from gate_fakes import MemoryStore  # noqa: E402

META = {'slot': 's01', 'bundleId': 'com.digiloglab.strius.preview.s01', 'appGroup': 'group.com.digiloglab.strius.preview.s01'}
EXPIRES = (datetime.datetime.now(datetime.timezone.utc) + datetime.timedelta(days=200)).isoformat()


def profile_document(identifier, *, container):
    # The worker extensions request Enhanced Security; the profile carries it.
    entitlements = {'com.apple.security.application-groups': [META['appGroup']], 'com.apple.security.hardened-process': True}
    if container:
        entitlements[prototype.CONTAINERS_KEY] = [prototype.ICLOUD_CONTAINER]
    return {'UUID': f'uuid-{identifier}-{container}', 'Name': identifier, 'Entitlements': entitlements,
            'ExpirationDate': datetime.datetime(2027, 1, 1), 'ProvisionedDevices': ['device']}


class FakeConnect:
    def __init__(self, existing, created):
        self.existing = existing
        self.created = created
        self.creations = []
        self.capabilities = []

    def distribution_certificates(self):
        return [{'id': 'cert', 'attributes': {'serialNumber': 'ABC'}}]

    def enabled_devices(self):
        return [{'id': 'device'}]

    def find_bundle_id(self, identifier):
        return {'id': identifier}

    def ensure_bundle_id(self, identifier, name):
        return {'id': identifier}, True

    def ensure_capability(self, bundle, capability):
        self.capabilities.append((bundle['id'], capability))
        return True

    def profiles_for(self, bundle):
        return self.existing.get(bundle['id'], [])

    def create_adhoc_profile(self, name, bundle, certificates, devices):
        self.creations.append(bundle['id'])
        return self.created[bundle['id']]


def resource(name, document, documents):
    key = f"{document['UUID']}"
    documents[key] = document
    return {'attributes': {'name': name, 'profileState': 'ACTIVE', 'profileType': 'IOS_APP_ADHOC',
                           'expirationDate': EXPIRES, 'profileContent': base64.b64encode(key.encode()).decode()}}


class PrototypeICloudTests(unittest.TestCase):
    def setUp(self):
        self.documents = {}
        self.private = Path(tempfile.mkdtemp())

        def run(command, log=None, cwd=None, env=None):
            if command[:2] == ['security', 'cms']:
                return plistlib.dumps(self.documents[Path(command[-1]).read_bytes().decode()])
            raise AssertionError(command)
        patch = mock.patch.object(prototype, 'run', side_effect=run)
        patch.start()
        self.addCleanup(patch.stop)

    def connect(self, app_existing_container, app_created_container=True):
        existing, created = {}, {}
        for product, suffix in prototype.COMPONENTS.items():
            identifier = META['bundleId'] + suffix
            # The name every reusable profile of this bundle starts with (see ensure_profiles).
            fingerprint = hashlib.sha256(b'devicecert').hexdigest()[:8]
            stem = f"Struis Preview {META['slot'].upper()}{suffix.replace('.', ' ').title()} AdHoc {fingerprint}"
            container = app_existing_container if not suffix else False
            existing[identifier] = [resource(stem, profile_document(identifier, container=container), self.documents)]
            created[identifier] = resource(stem, profile_document(identifier + '.new', container=app_created_container if not suffix else False), self.documents)
        return FakeConnect(existing, created)

    def ensure(self, connect):
        return prototype.ensure_profiles(connect, META, 'ABC', self.private)

    def test_the_app_profile_is_reused_only_with_the_icloud_container(self):
        connect = self.connect(app_existing_container=True)
        profiles, _ = self.ensure(connect)
        self.assertEqual(connect.creations, [])
        self.assertTrue(all(profile['reused'] for profile in profiles.values()), 'extensions do not need the container')

        connect = self.connect(app_existing_container=False)
        profiles, _ = self.ensure(connect)
        self.assertEqual(connect.creations, [META['bundleId']])
        self.assertFalse(profiles['strius']['reused'])

    def test_a_new_profile_without_the_container_asks_for_the_portal(self):
        connect = self.connect(app_existing_container=False, app_created_container=False)
        with self.assertRaises(prototype.BuildError) as raised:
            self.ensure(connect)
        self.assertIn(prototype.ICLOUD_CONTAINER, raised.exception.summary + raised.exception.detail)
        self.assertIn('Developer ポータル', raised.exception.detail)

    def test_register_slots_enables_icloud_on_the_app_id_only(self):
        store = MemoryStore()
        connect = FakeConnect({}, {})
        summaries = []
        with mock.patch.object(prototype, 'Store', return_value=store), \
                mock.patch.object(prototype, 'asc_client', return_value=connect), \
                mock.patch.object(prototype, 'append_summary', side_effect=summaries.append), \
                mock.patch('builtins.print'):
            prototype.cmd_register_slots(argparse.Namespace(count=1))
        icloud = [bundle for bundle, capability in connect.capabilities if capability == 'ICLOUD']
        self.assertEqual(icloud, [META['bundleId']])
        self.assertIn(prototype.ICLOUD_CONTAINER, summaries[0])


if __name__ == '__main__':
    unittest.main()
