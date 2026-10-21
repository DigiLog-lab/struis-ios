#!/usr/bin/env python3
"""Publish the packed native runtime to the GitHub Release `native-runtime`.

Run on main by agent-native-cache.yml with contents: write. Idempotent: an
asset already published for the key is kept. Older keys beyond KEEP are
removed so the release holds only recent inputs.
"""
import json
import os
from pathlib import Path
import sys
import urllib.error
import urllib.parse
import urllib.request

sys.path.insert(0, str(Path(__file__).resolve().parent))
import native_prebuilt  # noqa: E402

API = os.environ.get('GITHUB_API_URL', 'https://api.github.com')
UPLOADS = 'https://uploads.github.com'
KEEP = 3


def call(method, url, body=None, data=None, content_type='application/json'):
    headers = {'Authorization': f'Bearer {os.environ["GITHUB_TOKEN"]}', 'Accept': 'application/vnd.github+json',
               'X-GitHub-Api-Version': '2022-11-28', 'User-Agent': 'struis-native-publisher'}
    if body is not None:
        data = json.dumps(body).encode()
    if data is not None:
        headers['Content-Type'] = content_type
    request = urllib.request.Request(url, data=data, method=method, headers=headers)
    try:
        with urllib.request.urlopen(request, timeout=1800) as response:
            payload = response.read()
            return json.loads(payload) if payload else None
    except urllib.error.HTTPError as error:
        if error.code == 404 and method == 'GET':
            return None
        raise RuntimeError(f'{method} {url}: HTTP {error.code} {error.read()[:300]!r}') from None


def main():
    archive = Path(sys.argv[1])
    repository = os.environ['GITHUB_REPOSITORY']
    value = native_prebuilt.key()
    name = native_prebuilt.asset_name(value)
    if archive.name != name:
        raise SystemExit(f'The archive must be named {name}')
    release = call('GET', f'{API}/repos/{repository}/releases/tags/{native_prebuilt.RELEASE_TAG}')
    if release is None:
        release = call('POST', f'{API}/repos/{repository}/releases', {
            'tag_name': native_prebuilt.RELEASE_TAG, 'target_commitish': 'main',
            'name': 'Native runtime (CI build input)', 'prerelease': True,
            'body': 'Outputs of NativeRuntime/Scripts/bootstrap.py for Xcode Cloud (scripts/ci/native_prebuilt.py). '
                    'Not an app release.'})
    assets = call('GET', f'{API}/repos/{repository}/releases/{release["id"]}/assets?per_page=100') or []
    present = {asset['name']: asset for asset in assets}
    for path in (Path(str(archive) + '.sha256'), archive):
        if path.name in present:
            print(f'{path.name} is already published')
            continue
        query = urllib.parse.urlencode({'name': path.name})
        with path.open('rb') as stream:
            call('POST', f'{UPLOADS}/repos/{repository}/releases/{release["id"]}/assets?{query}',
                 data=stream.read(), content_type='application/gzip' if path.suffix == '.gz' else 'text/plain')
        print(f'published {path.name}')
    # Keep the newest KEEP keys (an archive and its .sha256 each).
    archives = sorted((asset for asset in assets if asset['name'].endswith('.tar.gz') and asset['name'] != name),
                      key=lambda asset: asset['created_at'], reverse=True)
    for asset in archives[KEEP - 1:]:
        for stale in (asset, present.get(asset['name'] + '.sha256')):
            if stale:
                call('DELETE', f'{API}/repos/{repository}/releases/assets/{stale["id"]}')
                print(f'removed {stale["name"]}')


if __name__ == '__main__':
    main()
