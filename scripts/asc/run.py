"""App Store Connect の掲載情報の作業を1回分走らせる(.github/workflows/asc-listing.yml から呼ぶ)。

今回の作業: 読み取りで現状を確かめ、値を変えない書き込みで権限を確かめる。
"""
from __future__ import annotations

import json
import os
import sys
import urllib.parse
from typing import Any

sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..', 'agent'))
from appstoreconnect import AppStoreConnect  # noqa: E402

BUNDLE_ID: str = 'com.digiloglab.strius'


def main(key_path: str, out_path: str) -> None:
    asc: AppStoreConnect = AppStoreConnect(key_path, os.environ['APP_STORE_CONNECT_KEY_ID'],
                                           os.environ['APP_STORE_CONNECT_ISSUER_ID'])
    out: dict[str, Any] = {}
    query: str = urllib.parse.urlencode({'filter[bundleId]': BUNDLE_ID})
    apps: list[dict[str, Any]] = asc.request('GET', f'/v1/apps?{query}')['data']
    app: dict[str, Any] = apps[0]
    app_id: str = app['id']
    out['app'] = {'id': app_id, 'attributes': app['attributes']}

    infos: list[dict[str, Any]] = asc.request('GET', f'/v1/apps/{app_id}/appInfos')['data']
    out['appInfos'] = []
    for info in infos:
        entry: dict[str, Any] = {'id': info['id'], 'attributes': info['attributes']}
        entry['localizations'] = [
            {'id': loc['id'], 'attributes': loc['attributes']}
            for loc in asc.request('GET', f"/v1/appInfos/{info['id']}/appInfoLocalizations")['data']]
        try:
            entry['primaryCategory'] = asc.request('GET', f"/v1/appInfos/{info['id']}/primaryCategory")['data']
        except RuntimeError as error:
            entry['primaryCategory'] = str(error)
        try:
            entry['ageRating'] = asc.request('GET', f"/v1/appInfos/{info['id']}/ageRatingDeclaration")['data']
        except RuntimeError as error:
            entry['ageRating'] = str(error)
        out['appInfos'].append(entry)

    versions: list[dict[str, Any]] = asc.request('GET', f'/v1/apps/{app_id}/appStoreVersions')['data']
    out['appStoreVersions'] = [{'id': v['id'], 'attributes': v['attributes']} for v in versions]
    builds: list[dict[str, Any]] = asc.request(
        'GET', f'/v1/builds?filter[app]={app_id}&sort=-uploadedDate&limit=5')['data']
    out['builds'] = [{'id': b['id'], 'version': b['attributes'].get('version'),
                      'processingState': b['attributes'].get('processingState'),
                      'uploadedDate': b['attributes'].get('uploadedDate')} for b in builds]

    groups: list[dict[str, Any]] = asc.request('GET', f'/v1/apps/{app_id}/subscriptionGroups')['data']
    out['subscriptionGroups'] = []
    for group in groups:
        subs: list[dict[str, Any]] = asc.request('GET', f"/v1/subscriptionGroups/{group['id']}/subscriptions")['data']
        out['subscriptionGroups'].append({'id': group['id'], 'attributes': group['attributes'],
                                          'subscriptions': [{'id': s['id'], 'attributes': s['attributes']} for s in subs]})

    for name, path in (('priceSchedule', f'/v1/apps/{app_id}/appPriceSchedule'),
                       ('availability', f'/v1/apps/{app_id}/appAvailabilityV2')):
        try:
            out[name] = asc.request('GET', path)
        except RuntimeError as error:
            out[name] = str(error)

    # 権限の確かめ: 編集できる appInfo の日本語のローカライズに、今と同じ値を書き戻す。
    write_check: str = 'skipped: no localization'
    for info in out['appInfos']:
        for loc in info['localizations']:
            attributes: dict[str, Any] = loc['attributes']
            same: dict[str, Any] = {k: attributes.get(k) for k in ('subtitle', 'privacyPolicyUrl') if attributes.get(k)}
            body: dict[str, Any] = {'data': {'type': 'appInfoLocalizations', 'id': loc['id'], 'attributes': same}}
            try:
                asc.request('PATCH', f"/v1/appInfoLocalizations/{loc['id']}", body)
                write_check = f"ok: PATCH appInfoLocalizations {loc['id']} ({attributes.get('locale')}) with {sorted(same)}"
            except RuntimeError as error:
                write_check = f'error: {error}'
            break
        if write_check != 'skipped: no localization':
            break
    out['writeCheck'] = write_check

    text: str = json.dumps(out, ensure_ascii=False, indent=1)
    with open(out_path, 'w', encoding='utf-8') as handle:
        handle.write(text)
    print(text)


if __name__ == '__main__':
    main(sys.argv[1], sys.argv[2])
