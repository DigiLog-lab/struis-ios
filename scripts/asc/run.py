"""App Store Connect の掲載情報の作業を1回分走らせる(.github/workflows/asc-listing.yml から呼ぶ)。

今回の作業: バージョン 1.0 の文章(説明文・キーワード・プロモーションテキスト・サポートURL・著作権)と、
審査用の連絡先(電話番号以外)とメモ。あわせてサブスクの日本の価格と状態を読み戻す。
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
LOCALE: str = 'ja'
TEXT_DIR: str = os.path.join(os.path.dirname(__file__), 'text')


def read_text(name: str) -> str:
    with open(os.path.join(TEXT_DIR, name), encoding='utf-8') as handle:
        return handle.read().strip()


def main(key_path: str, out_path: str) -> None:
    asc: AppStoreConnect = AppStoreConnect(key_path, os.environ['APP_STORE_CONNECT_KEY_ID'],
                                           os.environ['APP_STORE_CONNECT_ISSUER_ID'])
    steps: list[dict[str, str]] = []
    out: dict[str, Any] = {}

    def step(name: str, method: str, path: str, body: dict[str, Any] | None = None) -> Any:
        try:
            result: Any = asc.request(method, path, body)
            steps.append({'step': name, 'result': 'ok'})
            return result
        except RuntimeError as error:
            steps.append({'step': name, 'result': f'error: {error}'})
            return None

    query: str = urllib.parse.urlencode({'filter[bundleId]': BUNDLE_ID})
    app_id: str = asc.request('GET', f'/v1/apps?{query}')['data'][0]['id']
    versions: list[dict[str, Any]] = asc.request('GET', f'/v1/apps/{app_id}/appStoreVersions')['data']
    version: dict[str, Any] = next(v for v in versions if v['attributes']['appStoreState'] == 'PREPARE_FOR_SUBMISSION')
    version_id: str = version['id']

    step('version.copyright', 'PATCH', f'/v1/appStoreVersions/{version_id}', {'data': {
        'type': 'appStoreVersions', 'id': version_id, 'attributes': {'copyright': read_text('copyright.txt')}}})

    attributes: dict[str, Any] = {
        'description': read_text('description.txt'),
        'keywords': read_text('keywords.txt'),
        'promotionalText': read_text('promotional.txt'),
        'supportUrl': 'https://struis.digiloglab.com/',
    }
    out['lengths'] = {k: len(v) for k, v in attributes.items()}
    locs: list[dict[str, Any]] = asc.request('GET', f'/v1/appStoreVersions/{version_id}/appStoreVersionLocalizations')['data']
    ja: dict[str, Any] | None = next((loc for loc in locs if loc['attributes']['locale'] == LOCALE), None)
    if ja:
        step('version.localization.ja', 'PATCH', f"/v1/appStoreVersionLocalizations/{ja['id']}", {'data': {
            'type': 'appStoreVersionLocalizations', 'id': ja['id'], 'attributes': attributes}})
    else:
        created: Any = step('version.localization.ja', 'POST', '/v1/appStoreVersionLocalizations', {'data': {
            'type': 'appStoreVersionLocalizations', 'attributes': dict(attributes, locale=LOCALE),
            'relationships': {'appStoreVersion': {'data': {'type': 'appStoreVersions', 'id': version_id}}}}})
        ja = created['data'] if created else None

    review: dict[str, Any] = {
        'contactFirstName': 'Tomochika',
        'contactLastName': 'Miyauji',
        'contactEmail': 'support@digiloglab.com',
        'demoAccountRequired': False,
        'notes': read_text('review-notes.txt'),
    }
    try:
        detail: dict[str, Any] | None = asc.request('GET', f'/v1/appStoreVersions/{version_id}/appStoreReviewDetail').get('data')
    except RuntimeError:
        detail = None
    if detail:
        step('reviewDetail', 'PATCH', f"/v1/appStoreReviewDetails/{detail['id']}", {'data': {
            'type': 'appStoreReviewDetails', 'id': detail['id'], 'attributes': review}})
    else:
        step('reviewDetail', 'POST', '/v1/appStoreReviewDetails', {'data': {
            'type': 'appStoreReviewDetails', 'attributes': review,
            'relationships': {'appStoreVersion': {'data': {'type': 'appStoreVersions', 'id': version_id}}}}})

    # 読み戻し(連絡先の個人情報は出力しない)
    v_attr: dict[str, Any] = asc.request('GET', f'/v1/appStoreVersions/{version_id}')['data']['attributes']
    out['version'] = {k: v_attr.get(k) for k in ('versionString', 'copyright', 'releaseType', 'appStoreState')}
    if ja:
        out['ja'] = asc.request('GET', f"/v1/appStoreVersionLocalizations/{ja['id']}")['data']['attributes']
    d_data: dict[str, Any] | None = asc.request('GET', f'/v1/appStoreVersions/{version_id}/appStoreReviewDetail').get('data')
    d_attr: dict[str, Any] = (d_data or {}).get('attributes') or {}
    out['reviewDetail'] = {'exists': d_data is not None, 'demoAccountRequired': d_attr.get('demoAccountRequired'),
                           'hasEmail': bool(d_attr.get('contactEmail')), 'hasName': bool(d_attr.get('contactLastName')),
                           'hasPhone': bool(d_attr.get('contactPhone')), 'notes': d_attr.get('notes')}

    group: dict[str, Any] = asc.request('GET', f'/v1/apps/{app_id}/subscriptionGroups')['data'][0]
    subs_out: list[dict[str, Any]] = []
    for sub in asc.request('GET', f"/v1/subscriptionGroups/{group['id']}/subscriptions")['data']:
        prices: list[dict[str, Any]] = asc.request(
            'GET', f"/v1/subscriptions/{sub['id']}/prices?filter[territory]=JPN&include=subscriptionPricePoint")
        points: dict[str, Any] = {i['id']: i['attributes'] for i in prices.get('included', [])}
        jpn: list[Any] = [points.get(p['relationships']['subscriptionPricePoint']['data']['id'], {}).get('customerPrice')
                          for p in prices['data']]
        subs_out.append({'productId': sub['attributes']['productId'], 'state': sub['attributes']['state'], 'jpnPrice': jpn})
    out['subscriptions'] = subs_out
    out['steps'] = steps
    text: str = json.dumps(out, ensure_ascii=False, indent=1)
    with open(out_path, 'w', encoding='utf-8') as handle:
        handle.write(text)
    print(json.dumps(steps, ensure_ascii=False))
    if any(not s['result'].startswith('ok') for s in steps):
        sys.exit(1)


if __name__ == '__main__':
    main(sys.argv[1], sys.argv[2])
