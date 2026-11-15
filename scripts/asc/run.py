"""App Store Connect の掲載情報の作業を1回分走らせる(.github/workflows/asc-listing.yml から呼ぶ)。

今回の作業: アプリ本体の価格(無料)と配信地域(EU の27か国を除く全地域)。書いた後に読み戻す。
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
BASE_TERRITORY: str = 'JPN'
# EU の加盟27か国(DSA の事業者情報が要る地域)。ここだけ配信しない。
EU: set[str] = {
    'AUT', 'BEL', 'BGR', 'HRV', 'CYP', 'CZE', 'DNK', 'EST', 'FIN', 'FRA', 'DEU', 'GRC', 'HUN', 'IRL',
    'ITA', 'LVA', 'LTU', 'LUX', 'MLT', 'NLD', 'POL', 'PRT', 'ROU', 'SVK', 'SVN', 'ESP', 'SWE',
}


def main(key_path: str, out_path: str) -> None:
    asc: AppStoreConnect = AppStoreConnect(key_path, os.environ['APP_STORE_CONNECT_KEY_ID'],
                                           os.environ['APP_STORE_CONNECT_ISSUER_ID'])
    out: dict[str, Any] = {'steps': []}
    query: str = urllib.parse.urlencode({'filter[bundleId]': BUNDLE_ID})
    app_id: str = asc.request('GET', f'/v1/apps?{query}')['data'][0]['id']

    def step(name: str, method: str, path: str, body: dict[str, Any]) -> Any:
        try:
            result: Any = asc.request(method, path, body)
            out['steps'].append({'step': name, 'result': 'ok'})
            return result
        except RuntimeError as error:
            out['steps'].append({'step': name, 'result': f'error: {error}'})
            return None

    # 価格: 今の予定を見て、無料になっていなければ無料の価格を入れる。
    manual: list[dict[str, Any]] = []
    try:
        manual = asc.paginate(f'/v1/appPriceSchedules/{app_id}/manualPrices?include=appPricePoint&limit=50')
    except RuntimeError as error:
        out['manualPricesError'] = str(error)
    out['manualPricesBefore'] = manual
    points: list[dict[str, Any]] = asc.request(
        'GET', f'/v1/apps/{app_id}/appPricePoints?filter[territory]={BASE_TERRITORY}&limit=200')['data']
    free: dict[str, Any] = next(p for p in points if float(p['attributes']['customerPrice']) == 0.0)
    out['freePricePoint'] = free['id']
    step('appPriceSchedule(free)', 'POST', '/v1/appPriceSchedules', {
        'data': {'type': 'appPriceSchedules', 'relationships': {
            'app': {'data': {'type': 'apps', 'id': app_id}},
            'baseTerritory': {'data': {'type': 'territories', 'id': BASE_TERRITORY}},
            'manualPrices': {'data': [{'type': 'appPrices', 'id': '${price-free}'}]}}},
        'included': [{'type': 'appPrices', 'id': '${price-free}', 'attributes': {'startDate': None},
                      'relationships': {'appPricePoint': {'data': {'type': 'appPricePoints', 'id': free['id']}}}}]})

    # 配信地域
    territories: list[str] = [t['id'] for t in asc.paginate('/v1/territories?limit=200')]
    out['territoryCount'] = len(territories)
    out['euMissingFromList'] = sorted(EU - set(territories))
    included: list[dict[str, Any]] = []
    refs: list[dict[str, str]] = []
    for code in territories:
        local: str = f'${{ta-{code}}}'
        refs.append({'type': 'territoryAvailabilities', 'id': local})
        included.append({'type': 'territoryAvailabilities', 'id': local,
                         'attributes': {'available': code not in EU},
                         'relationships': {'territory': {'data': {'type': 'territories', 'id': code}}}})
    step('appAvailabilityV2', 'POST', '/v2/appAvailabilities', {
        'data': {'type': 'appAvailabilities', 'attributes': {'availableInNewTerritories': True},
                 'relationships': {'app': {'data': {'type': 'apps', 'id': app_id}},
                                   'territoryAvailabilities': {'data': refs}}},
        'included': included})

    # 読み戻し
    try:
        after: list[dict[str, Any]] = asc.paginate(
            f'/v1/appPriceSchedules/{app_id}/manualPrices?include=appPricePoint&limit=50')
        out['manualPricesAfter'] = after
    except RuntimeError as error:
        out['manualPricesAfter'] = str(error)
    try:
        availability: dict[str, Any] = asc.request('GET', f'/v1/apps/{app_id}/appAvailabilityV2')['data']
        out['availability'] = availability['attributes']
        rows: list[dict[str, Any]] = asc.paginate(
            f"/v2/appAvailabilities/{availability['id']}/territoryAvailabilities?include=territory&limit=200")
        available: list[str] = []
        unavailable: list[str] = []
        for row in rows:
            code: str = row['relationships']['territory']['data']['id']
            (available if row['attributes'].get('available') else unavailable).append(code)
        out['availableCount'] = len(available)
        out['unavailable'] = sorted(unavailable)
    except RuntimeError as error:
        out['availability'] = str(error)

    text: str = json.dumps(out, ensure_ascii=False, indent=1)
    with open(out_path, 'w', encoding='utf-8') as handle:
        handle.write(text)
    print(json.dumps({'steps': out['steps'], 'unavailable': out.get('unavailable'),
                      'availableCount': out.get('availableCount')}, ensure_ascii=False))
    if any(s['result'] != 'ok' for s in out['steps']):
        sys.exit(1)


if __name__ == '__main__':
    main(sys.argv[1], sys.argv[2])
