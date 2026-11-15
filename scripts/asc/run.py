"""App Store Connect の掲載情報の作業を1回分走らせる(.github/workflows/asc-listing.yml から呼ぶ)。

今回の作業: Apple 公式の OpenAPI 仕様を取り、これから使う型の項目と選択肢を書き出す(書き込みはしない)。
"""
from __future__ import annotations

import io
import json
import sys
import urllib.request
import zipfile
from typing import Any

SPEC_URL: str = 'https://developer.apple.com/sample-code/app-store-connect/app-store-connect-openapi-specification.zip'
SCHEMAS: list[str] = [
    'AgeRatingDeclarationUpdateRequest',
    'AppUpdateRequest',
    'AppInfoUpdateRequest',
    'AppInfoLocalizationUpdateRequest',
    'AppStoreVersionUpdateRequest',
    'AppStoreVersionLocalizationUpdateRequest',
    'AppStoreVersionLocalizationCreateRequest',
    'AppStoreReviewDetailCreateRequest',
    'AppStoreReviewDetailUpdateRequest',
    'AppAvailabilityV2CreateRequest',
    'TerritoryAvailabilityInlineCreate',
    'AppPriceScheduleCreateRequest',
    'SubscriptionUpdateRequest',
    'SubscriptionLocalizationCreateRequest',
    'SubscriptionGroupLocalizationCreateRequest',
    'SubscriptionPriceCreateRequest',
    'SubscriptionIntroductoryOfferCreateRequest',
    'SubscriptionAvailabilityCreateRequest',
    'SubscriptionAppStoreReviewScreenshotCreateRequest',
    'AppScreenshotSetCreateRequest',
    'AppScreenshotCreateRequest',
    'AccessibilityDeclarationCreateRequest',
    'ScreenshotDisplayType',
    'SubscriptionOfferDuration',
    'SubscriptionOfferMode',
]


def resolve(schemas: dict[str, Any], node: Any, depth: int = 0) -> Any:
    if depth > 6:
        return '...'
    if isinstance(node, dict):
        if '$ref' in node:
            name: str = node['$ref'].split('/')[-1]
            target: dict[str, Any] = schemas.get(name, {})
            if 'enum' in target:
                return {'enum': target['enum']}
            return {'ref': name, 'schema': resolve(schemas, target, depth + 1)}
        out: dict[str, Any] = {}
        for key, value in node.items():
            if key in ('description', 'example', 'deprecated') and not isinstance(value, (dict, list)):
                if key == 'deprecated':
                    out[key] = value
                continue
            out[key] = resolve(schemas, value, depth + 1)
        return out
    if isinstance(node, list):
        return [resolve(schemas, item, depth + 1) for item in node]
    return node


def main(key_path: str, out_path: str) -> None:
    del key_path
    data: bytes = urllib.request.urlopen(SPEC_URL, timeout=120).read()
    archive: zipfile.ZipFile = zipfile.ZipFile(io.BytesIO(data))
    name: str = next(n for n in archive.namelist() if n.endswith('.json'))
    spec: dict[str, Any] = json.loads(archive.read(name))
    schemas: dict[str, Any] = spec['components']['schemas']
    del schemas
    text: str = json.dumps(spec, ensure_ascii=False)
    with open(out_path, 'w', encoding='utf-8') as handle:
        handle.write(text)
    print(f'wrote {len(text)} bytes')


if __name__ == '__main__':
    main(sys.argv[1], sys.argv[2])
