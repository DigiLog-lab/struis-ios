"""App Store Connect の掲載情報の作業を1回分走らせる(.github/workflows/asc-listing.yml から呼ぶ)。

今回の作業: バージョン 1.0 の公開方法を手動(MANUAL)にする。日本語の掲載スクショ(案I)。iPhone 6.9/6.7インチ(1290x2796)と
iPad 13インチ(2752x2064、横向き)に6枚ずつ、assets/screens の番号の順で入れる。
入っている枚数・チェックサムが同じなら何もせず、処理の状態だけ読み戻す。違えば全部消して入れ直す。
"""
from __future__ import annotations

import hashlib
import json
import os
import sys
import urllib.parse
import urllib.request
from typing import Any

sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..', 'agent'))
from appstoreconnect import AppStoreConnect  # noqa: E402

BUNDLE_ID: str = 'com.digiloglab.strius'
LOCALE: str = 'ja'
SCREENS_DIR: str = os.path.join(os.path.dirname(__file__), 'assets', 'screens')
SETS: dict[str, str] = {'APP_IPHONE_67': 'iphone', 'APP_IPAD_PRO_3GEN_129': 'ipad'}


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
    step('version.releaseType', 'PATCH', f"/v1/appStoreVersions/{version['id']}", {'data': {
        'type': 'appStoreVersions', 'id': version['id'], 'attributes': {'releaseType': 'MANUAL'}}})
    out['releaseType'] = asc.request('GET', f"/v1/appStoreVersions/{version['id']}")['data']['attributes'].get('releaseType')
    locs: list[dict[str, Any]] = asc.request('GET', f"/v1/appStoreVersions/{version['id']}/appStoreVersionLocalizations")['data']
    loc_id: str = next(l['id'] for l in locs if l['attributes']['locale'] == LOCALE)

    sets: list[dict[str, Any]] = asc.request('GET', f'/v1/appStoreVersionLocalizations/{loc_id}/appScreenshotSets')['data']
    by_type: dict[str, dict[str, Any]] = {s['attributes']['screenshotDisplayType']: s for s in sets}
    out['existingSetTypes'] = sorted(by_type)

    for display_type, folder in SETS.items():
        files: list[bytes] = [open(os.path.join(SCREENS_DIR, folder, f'{i}.png'), 'rb').read() for i in range(1, 7)]
        sums: list[str] = [hashlib.md5(d).hexdigest() for d in files]
        shot_set: dict[str, Any] | None = by_type.get(display_type)
        if shot_set is None:
            created: Any = step(f'{folder}.set.create', 'POST', '/v1/appScreenshotSets', {'data': {
                'type': 'appScreenshotSets', 'attributes': {'screenshotDisplayType': display_type},
                'relationships': {'appStoreVersionLocalization': {
                    'data': {'type': 'appStoreVersionLocalizations', 'id': loc_id}}}}})
            if not created:
                continue
            shot_set = created['data']
        set_id: str = shot_set['id']
        current: list[dict[str, Any]] = asc.request('GET', f'/v1/appScreenshotSets/{set_id}/appScreenshots')['data']
        if [c['attributes'].get('sourceFileChecksum') for c in current] == sums:
            steps.append({'step': f'{folder}.screenshots', 'result': 'ok (already uploaded)'})
            continue
        for c in current:
            step(f"{folder}.delete.{c['attributes'].get('fileName')}", 'DELETE', f"/v1/appScreenshots/{c['id']}")
        for index, data in enumerate(files, start=1):
            name: str = f'struis-{folder}-{index}.png'
            reserved: Any = step(f'{folder}.{index}.reserve', 'POST', '/v1/appScreenshots', {'data': {
                'type': 'appScreenshots', 'attributes': {'fileName': name, 'fileSize': len(data)},
                'relationships': {'appScreenshotSet': {'data': {'type': 'appScreenshotSets', 'id': set_id}}}}})
            if not reserved:
                continue
            shot_id: str = reserved['data']['id']
            try:
                for op in reserved['data']['attributes']['uploadOperations']:
                    chunk: bytes = data[op['offset']:op['offset'] + op['length']]
                    headers: dict[str, str] = {h['name']: h['value'] for h in op.get('requestHeaders', [])}
                    request = urllib.request.Request(op['url'], data=chunk, method=op['method'], headers=headers)
                    urllib.request.urlopen(request, timeout=120).read()
            except Exception as error:  # noqa: BLE001
                steps.append({'step': f'{folder}.{index}.put', 'result': f'error: {error}'})
                continue
            step(f'{folder}.{index}.commit', 'PATCH', f'/v1/appScreenshots/{shot_id}', {'data': {
                'type': 'appScreenshots', 'id': shot_id,
                'attributes': {'uploaded': True, 'sourceFileChecksum': sums[index - 1]}}})

    # 読み戻し(処理には少しかかるので、状態は次の実行でも確かめる)
    out['sets'] = {}
    for s in asc.request('GET', f'/v1/appStoreVersionLocalizations/{loc_id}/appScreenshotSets')['data']:
        shots: list[dict[str, Any]] = asc.request('GET', f"/v1/appScreenshotSets/{s['id']}/appScreenshots")['data']
        out['sets'][s['attributes']['screenshotDisplayType']] = [
            {'fileName': x['attributes'].get('fileName'),
             'state': (x['attributes'].get('assetDeliveryState') or {}).get('state'),
             'errors': (x['attributes'].get('assetDeliveryState') or {}).get('errors'),
             'size': x['attributes'].get('imageAsset') and [x['attributes']['imageAsset'].get('width'),
                                                            x['attributes']['imageAsset'].get('height')]}
            for x in shots]
    out['steps'] = steps
    with open(out_path, 'w', encoding='utf-8') as handle:
        handle.write(json.dumps(out, ensure_ascii=False, indent=1))
    print(json.dumps(steps, ensure_ascii=False))
    if any(not s['result'].startswith('ok') for s in steps):
        sys.exit(1)


if __name__ == '__main__':
    main(sys.argv[1], sys.argv[2])
