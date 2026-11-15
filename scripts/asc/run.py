"""App Store Connect の掲載情報の作業を1回分走らせる(.github/workflows/asc-listing.yml から呼ぶ)。

今回の作業: サブスク3プラン。グループの表示名、各プランの表示名と説明、価格(全配信地域)、配信地域、
ライトの1週間の無料体験、審査用のスクショ。すでに入っているものは上書きか飛ばす。最後に読み戻す。
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
BASE_TERRITORY: str = 'JPN'
GROUP_NAME: str = 'Struis のプラン'
PLANS: dict[str, dict[str, Any]] = {
    'com.digiloglab.strius.plan.light': {'name': 'ライト', 'description': '週約12問が目安。まずはここから', 'yen': 1480},
    'com.digiloglab.strius.plan.standard': {'name': 'スタンダード', 'description': '週約30問が目安。毎日しっかり解く人に', 'yen': 3980},
    'com.digiloglab.strius.plan.generous': {'name': 'たっぷり', 'description': '週約75問が目安。たくさん解きたい人に', 'yen': 9800},
}
TRIAL_PRODUCT: str = 'com.digiloglab.strius.plan.light'
EU: set[str] = {
    'AUT', 'BEL', 'BGR', 'HRV', 'CYP', 'CZE', 'DNK', 'EST', 'FIN', 'FRA', 'DEU', 'GRC', 'HUN', 'IRL',
    'ITA', 'LVA', 'LTU', 'LUX', 'MLT', 'NLD', 'POL', 'PRT', 'ROU', 'SVK', 'SVN', 'ESP', 'SWE',
}
SCREENSHOT: str = os.path.join(os.path.dirname(__file__), 'assets', 'review-paywall.png')


class Runner:
    def __init__(self, asc: AppStoreConnect) -> None:
        self.asc: AppStoreConnect = asc
        self.steps: list[dict[str, str]] = []

    def step(self, name: str, method: str, path: str, body: dict[str, Any] | None = None) -> Any:
        try:
            result: Any = self.asc.request(method, path, body)
            self.steps.append({'step': name, 'result': 'ok'})
            return result
        except RuntimeError as error:
            self.steps.append({'step': name, 'result': f'error: {error}'})
            return None


def upload_screenshot(run: Runner, subscription_id: str, label: str) -> None:
    asc: AppStoreConnect = run.asc
    existing: dict[str, Any] | None = None
    try:
        existing = asc.request('GET', f'/v1/subscriptions/{subscription_id}/appStoreReviewScreenshot').get('data')
    except RuntimeError:
        existing = None
    if existing and (existing['attributes'].get('assetDeliveryState') or {}).get('state') == 'COMPLETE':
        run.steps.append({'step': f'{label}.reviewScreenshot', 'result': 'ok (already uploaded)'})
        return
    if existing:
        run.step(f'{label}.reviewScreenshot.deleteBroken', 'DELETE', f"/v1/subscriptionAppStoreReviewScreenshots/{existing['id']}")
    data: bytes = open(SCREENSHOT, 'rb').read()
    created: Any = run.step(f'{label}.reviewScreenshot.reserve', 'POST', '/v1/subscriptionAppStoreReviewScreenshots', {
        'data': {'type': 'subscriptionAppStoreReviewScreenshots',
                 'attributes': {'fileName': 'review-paywall.png', 'fileSize': len(data)},
                 'relationships': {'subscription': {'data': {'type': 'subscriptions', 'id': subscription_id}}}}})
    if not created:
        return
    shot_id: str = created['data']['id']
    for op in created['data']['attributes']['uploadOperations']:
        chunk: bytes = data[op['offset']:op['offset'] + op['length']]
        headers: dict[str, str] = {h['name']: h['value'] for h in op.get('requestHeaders', [])}
        request: urllib.request.Request = urllib.request.Request(op['url'], data=chunk, method=op['method'], headers=headers)
        urllib.request.urlopen(request, timeout=120).read()
    run.step(f'{label}.reviewScreenshot.commit', 'PATCH', f'/v1/subscriptionAppStoreReviewScreenshots/{shot_id}', {
        'data': {'type': 'subscriptionAppStoreReviewScreenshots', 'id': shot_id,
                 'attributes': {'uploaded': True, 'sourceFileChecksum': hashlib.md5(data).hexdigest()}}})


def main(key_path: str, out_path: str) -> None:
    asc: AppStoreConnect = AppStoreConnect(key_path, os.environ['APP_STORE_CONNECT_KEY_ID'],
                                           os.environ['APP_STORE_CONNECT_ISSUER_ID'])
    run: Runner = Runner(asc)
    out: dict[str, Any] = {}
    query: str = urllib.parse.urlencode({'filter[bundleId]': BUNDLE_ID})
    app_id: str = asc.request('GET', f'/v1/apps?{query}')['data'][0]['id']
    group: dict[str, Any] = asc.request('GET', f'/v1/apps/{app_id}/subscriptionGroups')['data'][0]
    group_id: str = group['id']

    # 配信地域(アプリ本体と同じ: EU を除く)
    territories: list[str] = [t['id'] for t in asc.paginate('/v1/territories?limit=200') if t['id'] not in EU]

    # グループの表示名
    group_locs: list[dict[str, Any]] = asc.request('GET', f'/v1/subscriptionGroups/{group_id}/subscriptionGroupLocalizations')['data']
    ja_group: dict[str, Any] | None = next((g for g in group_locs if g['attributes']['locale'] == LOCALE), None)
    if ja_group:
        run.step('group.localization', 'PATCH', f"/v1/subscriptionGroupLocalizations/{ja_group['id']}", {'data': {
            'type': 'subscriptionGroupLocalizations', 'id': ja_group['id'], 'attributes': {'name': GROUP_NAME}}})
    else:
        run.step('group.localization', 'POST', '/v1/subscriptionGroupLocalizations', {'data': {
            'type': 'subscriptionGroupLocalizations', 'attributes': {'name': GROUP_NAME, 'locale': LOCALE},
            'relationships': {'subscriptionGroup': {'data': {'type': 'subscriptionGroups', 'id': group_id}}}}})

    subs: list[dict[str, Any]] = asc.request('GET', f'/v1/subscriptionGroups/{group_id}/subscriptions')['data']
    for sub in subs:
        product: str = sub['attributes']['productId']
        plan: dict[str, Any] = PLANS[product]
        sub_id: str = sub['id']
        label: str = product.rsplit('.', 1)[-1]

        # 表示名と説明
        locs: list[dict[str, Any]] = asc.request('GET', f'/v1/subscriptions/{sub_id}/subscriptionLocalizations')['data']
        ja: dict[str, Any] | None = next((loc for loc in locs if loc['attributes']['locale'] == LOCALE), None)
        if ja:
            run.step(f'{label}.localization', 'PATCH', f"/v1/subscriptionLocalizations/{ja['id']}", {'data': {
                'type': 'subscriptionLocalizations', 'id': ja['id'],
                'attributes': {'name': plan['name'], 'description': plan['description']}}})
        else:
            run.step(f'{label}.localization', 'POST', '/v1/subscriptionLocalizations', {'data': {
                'type': 'subscriptionLocalizations',
                'attributes': {'name': plan['name'], 'locale': LOCALE, 'description': plan['description']},
                'relationships': {'subscription': {'data': {'type': 'subscriptions', 'id': sub_id}}}}})

        # 価格: 日本の価格の点を探し、他の地域は Apple の換算(equalizations)に合わせる。
        existing_prices: list[dict[str, Any]] = asc.paginate(f'/v1/subscriptions/{sub_id}/prices?include=territory&limit=200')
        priced: set[str] = {p['relationships']['territory']['data']['id'] for p in existing_prices
                            if p.get('relationships', {}).get('territory', {}).get('data')}
        points: list[dict[str, Any]] = asc.paginate(
            f'/v1/subscriptions/{sub_id}/pricePoints?filter[territory]={BASE_TERRITORY}&limit=200')
        base: dict[str, Any] = next(p for p in points if float(p['attributes']['customerPrice']) == float(plan['yen']))
        targets: dict[str, str] = {BASE_TERRITORY: base['id']}
        for eq in asc.paginate(f"/v1/subscriptionPricePoints/{base['id']}/equalizations?include=territory&limit=200"):
            code: str = eq['relationships']['territory']['data']['id']
            targets[code] = eq['id']
        created: int = 0
        failed: list[str] = []
        for code in territories:
            if code in priced or code not in targets:
                continue
            try:
                asc.request('POST', '/v1/subscriptionPrices', {'data': {
                    'type': 'subscriptionPrices', 'attributes': {'startDate': None, 'preserveCurrentPrice': False},
                    'relationships': {'subscription': {'data': {'type': 'subscriptions', 'id': sub_id}},
                                      'territory': {'data': {'type': 'territories', 'id': code}},
                                      'subscriptionPricePoint': {'data': {'type': 'subscriptionPricePoints', 'id': targets[code]}}}}})
                created += 1
            except RuntimeError as error:
                failed.append(f'{code}: {str(error)[:200]}')
        missing: list[str] = [c for c in territories if c not in targets]
        run.steps.append({'step': f'{label}.prices', 'result': 'ok' if not failed else 'error',
                          'detail': f'created={created} alreadyPriced={len(priced)} noPricePoint={missing} failed={failed[:5]}'})

        # 配信地域
        try:
            availability: dict[str, Any] | None = asc.request('GET', f'/v1/subscriptions/{sub_id}/subscriptionAvailability').get('data')
        except RuntimeError:
            availability = None
        if not availability:
            run.step(f'{label}.availability', 'POST', '/v1/subscriptionAvailabilities', {'data': {
                'type': 'subscriptionAvailabilities', 'attributes': {'availableInNewTerritories': True},
                'relationships': {'subscription': {'data': {'type': 'subscriptions', 'id': sub_id}},
                                  'availableTerritories': {'data': [{'type': 'territories', 'id': c} for c in territories]}}}})
        else:
            run.steps.append({'step': f'{label}.availability', 'result': 'ok (already set)'})

        # ライトだけ1週間の無料体験
        if product == TRIAL_PRODUCT:
            offers: list[dict[str, Any]] = asc.paginate(f'/v1/subscriptions/{sub_id}/introductoryOffers?limit=200')
            if offers:
                run.steps.append({'step': f'{label}.introductoryOffer', 'result': f'ok (already {len(offers)})'})
            else:
                result: Any = run.step(f'{label}.introductoryOffer(all)', 'POST', '/v1/subscriptionIntroductoryOffers', {'data': {
                    'type': 'subscriptionIntroductoryOffers',
                    'attributes': {'duration': 'ONE_WEEK', 'offerMode': 'FREE_TRIAL', 'numberOfPeriods': 1},
                    'relationships': {'subscription': {'data': {'type': 'subscriptions', 'id': sub_id}}}}})
                if result is None:
                    # 地域を省けない時は、地域ごとに作る。
                    run.steps.pop()
                    bad: list[str] = []
                    for code in territories:
                        try:
                            asc.request('POST', '/v1/subscriptionIntroductoryOffers', {'data': {
                                'type': 'subscriptionIntroductoryOffers',
                                'attributes': {'duration': 'ONE_WEEK', 'offerMode': 'FREE_TRIAL', 'numberOfPeriods': 1},
                                'relationships': {'subscription': {'data': {'type': 'subscriptions', 'id': sub_id}},
                                                  'territory': {'data': {'type': 'territories', 'id': code}}}}})
                        except RuntimeError as error:
                            bad.append(f'{code}: {str(error)[:200]}')
                    run.steps.append({'step': f'{label}.introductoryOffer(per territory)',
                                      'result': 'ok' if not bad else 'error', 'detail': str(bad[:5])})

        upload_screenshot(run, sub_id, label)

    # 読み戻し
    read: list[dict[str, Any]] = []
    for sub in asc.request('GET', f'/v1/subscriptionGroups/{group_id}/subscriptions')['data']:
        sub_id = sub['id']
        entry: dict[str, Any] = {'productId': sub['attributes']['productId'], 'state': sub['attributes']['state'],
                                 'groupLevel': sub['attributes']['groupLevel']}
        entry['localizations'] = [loc['attributes'] for loc in
                                  asc.request('GET', f'/v1/subscriptions/{sub_id}/subscriptionLocalizations')['data']]
        prices: list[dict[str, Any]] = asc.paginate(f'/v1/subscriptions/{sub_id}/prices?include=territory,subscriptionPricePoint&limit=200')
        entry['priceCount'] = len(prices)
        offers = asc.paginate(f'/v1/subscriptions/{sub_id}/introductoryOffers?limit=200')
        entry['introductoryOffers'] = len(offers)
        entry['introductoryOfferSample'] = offers[0]['attributes'] if offers else None
        try:
            shot: dict[str, Any] = asc.request('GET', f'/v1/subscriptions/{sub_id}/appStoreReviewScreenshot')['data']
            entry['reviewScreenshot'] = (shot['attributes'].get('assetDeliveryState') or {}).get('state')
        except RuntimeError as error:
            entry['reviewScreenshot'] = str(error)[:200]
        read.append(entry)
    jpn: list[dict[str, Any]] = []
    out['steps'] = run.steps
    out['readBack'] = read
    out['groupLocalizations'] = [g['attributes'] for g in
                                 asc.request('GET', f'/v1/subscriptionGroups/{group_id}/subscriptionGroupLocalizations')['data']]
    del jpn
    text: str = json.dumps(out, ensure_ascii=False, indent=1)
    with open(out_path, 'w', encoding='utf-8') as handle:
        handle.write(text)
    print(json.dumps(run.steps, ensure_ascii=False))
    if any(not s['result'].startswith('ok') for s in run.steps):
        sys.exit(1)


if __name__ == '__main__':
    main(sys.argv[1], sys.argv[2])
