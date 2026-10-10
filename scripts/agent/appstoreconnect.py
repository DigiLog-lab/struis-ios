"""Small App Store Connect API client (Bundle IDs, capabilities, devices, profiles).

The ES256 token is signed with the system openssl so the runner needs no extra
Python packages. The private key is read from a file that the workflow writes
with mode 0600 and removes afterwards.
"""
import base64
import json
import os
import subprocess
import time
import urllib.error
import urllib.parse
import urllib.request

API = 'https://api.appstoreconnect.apple.com'


def _b64url(data):
    return base64.urlsafe_b64encode(data).rstrip(b'=').decode()


def _der_to_raw_signature(der):
    """Convert an ECDSA DER signature (SEQUENCE of r, s) to the JOSE r||s form."""
    def read_length(data, offset):
        length = data[offset]
        offset += 1
        if length & 0x80:
            count = length & 0x7F
            length = int.from_bytes(data[offset:offset + count], 'big')
            offset += count
        return length, offset

    if der[0] != 0x30:
        raise ValueError('unexpected signature encoding')
    _, offset = read_length(der, 1)
    values = []
    for _ in range(2):
        if der[offset] != 0x02:
            raise ValueError('unexpected signature encoding')
        length, offset = read_length(der, offset + 1)
        values.append(int.from_bytes(der[offset:offset + length], 'big'))
        offset += length
    return b''.join(value.to_bytes(32, 'big') for value in values)


class AppStoreConnect:
    def __init__(self, key_path, key_id, issuer_id):
        self.key_path = key_path
        self.key_id = key_id
        self.issuer_id = issuer_id
        self._token = None
        self._token_time = 0

    def token(self):
        if self._token and time.time() - self._token_time < 600:
            return self._token
        now = int(time.time())
        header = _b64url(json.dumps({'alg': 'ES256', 'kid': self.key_id, 'typ': 'JWT'}).encode())
        payload = _b64url(json.dumps({'iss': self.issuer_id, 'iat': now, 'exp': now + 1100,
                                      'aud': 'appstoreconnect-v1'}).encode())
        signing_input = f'{header}.{payload}'.encode()
        der = subprocess.run(['openssl', 'dgst', '-sha256', '-sign', self.key_path], input=signing_input,
                             capture_output=True, check=True).stdout
        self._token = f'{header}.{payload}.{_b64url(_der_to_raw_signature(der))}'
        self._token_time = time.time()
        return self._token

    def request(self, method, path, body=None):
        url = path if path.startswith('https://') else f'{API}{path}'
        data = None if body is None else json.dumps(body).encode()
        for attempt in range(5):
            request = urllib.request.Request(url, data=data, method=method, headers={
                'Authorization': f'Bearer {self.token()}', 'Content-Type': 'application/json'})
            try:
                with urllib.request.urlopen(request, timeout=60) as response:
                    payload = response.read()
                    return json.loads(payload) if payload else None
            except urllib.error.HTTPError as error:
                detail = error.read().decode(errors='replace')
                if error.code == 429 or (error.code >= 500 and attempt < 4):
                    time.sleep(min(60, 2 ** (attempt + 2)))
                    continue
                raise RuntimeError(f'App Store Connect {method} {path}: HTTP {error.code} {detail[:600]}') from None
        raise RuntimeError(f'App Store Connect {method} {path}: retries exhausted')

    def paginate(self, path):
        items = []
        url = path
        while url:
            page = self.request('GET', url)
            items.extend(page.get('data', []))
            url = (page.get('links') or {}).get('next')
        return items

    # ------------------------------------------------------------ bundle IDs

    def find_bundle_id(self, identifier):
        query = urllib.parse.urlencode({'filter[identifier]': identifier, 'filter[platform]': 'IOS', 'limit': 200})
        for item in self.paginate(f'/v1/bundleIds?{query}'):
            if item['attributes']['identifier'] == identifier:
                return item
        return None

    def ensure_bundle_id(self, identifier, name):
        existing = self.find_bundle_id(identifier)
        if existing:
            return existing, False
        created = self.request('POST', '/v1/bundleIds', {'data': {
            'type': 'bundleIds',
            'attributes': {'identifier': identifier, 'name': name, 'platform': 'IOS'}}})
        return created['data'], True

    def capabilities(self, bundle_id):
        return self.paginate(f"/v1/bundleIds/{bundle_id['id']}/bundleIdCapabilities")

    def ensure_capability(self, bundle_id, capability_type):
        if any(item['attributes'].get('capabilityType') == capability_type for item in self.capabilities(bundle_id)):
            return False
        self.request('POST', '/v1/bundleIdCapabilities', {'data': {
            'type': 'bundleIdCapabilities',
            'attributes': {'capabilityType': capability_type},
            'relationships': {'bundleId': {'data': {'type': 'bundleIds', 'id': bundle_id['id']}}}}})
        return True

    # ------------------------------------------------- devices and profiles

    def enabled_devices(self):
        query = urllib.parse.urlencode({'filter[status]': 'ENABLED', 'limit': 200})
        return [device for device in self.paginate(f'/v1/devices?{query}')
                if device['attributes'].get('platform') in ('IOS', 'UNIVERSAL')
                and device['attributes'].get('deviceClass') in ('IPHONE', 'IPAD', 'IPOD')]

    def distribution_certificates(self):
        query = urllib.parse.urlencode({'filter[certificateType]': 'DISTRIBUTION,IOS_DISTRIBUTION', 'limit': 200})
        return self.paginate(f'/v1/certificates?{query}')

    def profiles_for(self, bundle_id):
        return self.paginate(f"/v1/bundleIds/{bundle_id['id']}/profiles")

    def create_adhoc_profile(self, name, bundle_id, certificate_ids, device_ids):
        created = self.request('POST', '/v1/profiles', {'data': {
            'type': 'profiles',
            'attributes': {'name': name, 'profileType': 'IOS_APP_ADHOC'},
            'relationships': {
                'bundleId': {'data': {'type': 'bundleIds', 'id': bundle_id['id']}},
                'certificates': {'data': [{'type': 'certificates', 'id': identifier} for identifier in certificate_ids]},
                'devices': {'data': [{'type': 'devices', 'id': identifier} for identifier in device_ids]},
            }}})
        return created['data']


def from_environment(key_path):
    return AppStoreConnect(key_path, os.environ['APP_STORE_CONNECT_KEY_ID'], os.environ['APP_STORE_CONNECT_ISSUER_ID'])
