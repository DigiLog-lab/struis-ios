"""App Store Connect の掲載情報の作業を1回分走らせる(.github/workflows/asc-listing.yml から呼ぶ)。

今回の作業: アプリ情報(サブタイトル・プライバシーポリシーURL・カテゴリ・コンテンツ配信権)と年齢制限の質問票。
書いた後に読み戻して、結果を出力する。
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
SUBTITLE: str = 'つい開いたその手で、1問解く'
PRIVACY_POLICY_URL: str = 'https://struis.digiloglab.com/privacy'
CATEGORY: str = 'EDUCATION'

# 年齢制限の質問票。内容はすべて「なし」、機能は年齢確認(Declared Age Range)だけ「あり」。
# 利用規約の対象が中学生以上なので、区分は 13+ に引き上げる。
NONE_CONTENT: list[str] = [
    'alcoholTobaccoOrDrugUseOrReferences', 'contests', 'gamblingSimulated', 'gunsOrOtherWeapons',
    'medicalOrTreatmentInformation', 'profanityOrCrudeHumor', 'sexualContentGraphicAndNudity',
    'sexualContentOrNudity', 'horrorOrFearThemes', 'matureOrSuggestiveThemes', 'violenceCartoonOrFantasy',
    'violenceRealisticProlongedGraphicOrSadistic', 'violenceRealistic',
]
FALSE_CAPABILITIES: list[str] = [
    'advertising', 'gambling', 'healthOrWellnessTopics', 'lootBox', 'messagingAndChat', 'parentalControls',
    'socialMedia', 'socialMediaAgeRestricted', 'unrestrictedWebAccess', 'userGeneratedContent',
]


def main(key_path: str, out_path: str) -> None:
    asc: AppStoreConnect = AppStoreConnect(key_path, os.environ['APP_STORE_CONNECT_KEY_ID'],
                                           os.environ['APP_STORE_CONNECT_ISSUER_ID'])
    out: dict[str, Any] = {'steps': []}
    query: str = urllib.parse.urlencode({'filter[bundleId]': BUNDLE_ID})
    app_id: str = asc.request('GET', f'/v1/apps?{query}')['data'][0]['id']

    infos: list[dict[str, Any]] = asc.request('GET', f'/v1/apps/{app_id}/appInfos')['data']
    info: dict[str, Any] = next(i for i in infos if i['attributes'].get('state') == 'PREPARE_FOR_SUBMISSION')
    info_id: str = info['id']
    localizations: list[dict[str, Any]] = asc.request('GET', f'/v1/appInfos/{info_id}/appInfoLocalizations')['data']
    ja: dict[str, Any] = next(loc for loc in localizations if loc['attributes']['locale'] == 'ja')

    def step(name: str, method: str, path: str, body: dict[str, Any]) -> None:
        try:
            asc.request(method, path, body)
            out['steps'].append({'step': name, 'result': 'ok'})
        except RuntimeError as error:
            out['steps'].append({'step': name, 'result': f'error: {error}'})

    step('app.contentRightsDeclaration', 'PATCH', f'/v1/apps/{app_id}', {'data': {
        'type': 'apps', 'id': app_id, 'attributes': {'contentRightsDeclaration': 'DOES_NOT_USE_THIRD_PARTY_CONTENT'}}})
    step('appInfoLocalization.ja', 'PATCH', f"/v1/appInfoLocalizations/{ja['id']}", {'data': {
        'type': 'appInfoLocalizations', 'id': ja['id'],
        'attributes': {'subtitle': SUBTITLE, 'privacyPolicyUrl': PRIVACY_POLICY_URL}}})
    step('appInfo.primaryCategory', 'PATCH', f'/v1/appInfos/{info_id}', {'data': {
        'type': 'appInfos', 'id': info_id,
        'relationships': {'primaryCategory': {'data': {'type': 'appCategories', 'id': CATEGORY}}}}})

    attributes: dict[str, Any] = {name: 'NONE' for name in NONE_CONTENT}
    attributes.update({name: False for name in FALSE_CAPABILITIES})
    attributes['ageAssurance'] = True
    attributes['ageRatingOverrideV2'] = 'THIRTEEN_PLUS'
    step('ageRatingDeclaration', 'PATCH', f'/v1/ageRatingDeclarations/{info_id}', {'data': {
        'type': 'ageRatingDeclarations', 'id': info_id, 'attributes': attributes}})

    # 読み戻し
    app_attributes: dict[str, Any] = asc.request('GET', f'/v1/apps/{app_id}')['data']['attributes']
    out['readBack'] = {
        'contentRightsDeclaration': app_attributes.get('contentRightsDeclaration'),
        'appInfo': asc.request('GET', f'/v1/appInfos/{info_id}')['data']['attributes'],
        'ja': asc.request('GET', f"/v1/appInfoLocalizations/{ja['id']}")['data']['attributes'],
        'primaryCategory': (asc.request('GET', f'/v1/appInfos/{info_id}/primaryCategory').get('data') or {}).get('id'),
        'ageRating': asc.request('GET', f'/v1/appInfos/{info_id}/ageRatingDeclaration')['data']['attributes'],
    }
    text: str = json.dumps(out, ensure_ascii=False, indent=1)
    with open(out_path, 'w', encoding='utf-8') as handle:
        handle.write(text)
    print(text)
    if any(s['result'] != 'ok' for s in out['steps']):
        sys.exit(1)


if __name__ == '__main__':
    main(sys.argv[1], sys.argv[2])
