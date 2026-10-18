#!/usr/bin/env python3
"""配信データの代わりの最小の prompt・schema を作る(実 AI の配線確認用。本番の配信本文ではない)。

    python3 scripts/e2e/standin_assets.py /tmp/standin-assets

アプリは DEBUG の Simulator で `STRUIS_DEVICE_ASSETS_DIR=/tmp/standin-assets` を付けて起動する
(`LocalDirectoryAssetSource`)。schema はアプリの Engine が読む形(単元の概要・一枚・判定)に合わせる。
"""
from __future__ import annotations

import json
import sys
from pathlib import Path


def obj(properties: dict, required: list[str] | None = None) -> dict:
    return {"type": "object", "properties": properties, "required": required if required is not None else list(properties), "additionalProperties": False}


STRING = {"type": "string"}
INTEGER = {"type": "integer", "minimum": 1, "maximum": 20}

SCHEMAS = {
    "workbook_unit.json": obj({
        "unit_title": STRING,
        "outcome": STRING,
        "subunits": {"type": "array", "minItems": 1, "maxItems": 6, "items": obj({
            "title": STRING, "outcome": STRING, "n": INTEGER, "scoring_unit": STRING,
        })},
    }),
    "workbook_set.json": obj({
        "problems": {"type": "array", "minItems": 1, "items": obj({
            "prompt": STRING, "answer_key": STRING, "checkpoints": {"type": "array", "items": STRING},
        })},
    }),
    "workbook_grading.json": obj({
        "readable": {"type": "boolean"},
        "items": {"type": "array", "items": obj({
            "label": STRING, "prompt_text": STRING, "matched_problem_id": {"type": ["string", "null"]},
            "verdict": {"type": "string", "enum": ["correct", "wrong", "unknown"]},
            "error_tag": STRING, "note": STRING,
        })},
        "candidates": {"type": "array", "items": obj({"problem_id": STRING, "reason": STRING})},
        "new_subunit": {"anyOf": [{"type": "null"}, obj({
            "unit_title": STRING, "subunit_title": STRING, "outcome": STRING, "n": INTEGER, "scoring_unit": STRING,
        })]},
        "note": STRING,
    }),
    "luna_lookup.json": obj({
        "status": {"type": "string", "enum": ["found", "not_found"]},
        "findings": {"type": "array", "items": obj({"source": STRING, "excerpt": STRING})},
        "note": STRING,
    }),
    "progress_update.json": obj({"updates": {"type": "array", "items": obj({"key": STRING, "value": STRING})}}),
}

TEXTS = {
    "app_server/base_instructions.md": "You are Struis, a patient math tutor for a Japanese learner. Reply in Japanese.\n",
    "app_server/developer_instructions.md": "Answer the learner briefly. Use struis.exec_command to read files when needed.\n",
    "app_server/AGENTS.md": "# Workspace\n\nThis folder holds the learner's tutor desk.\n",
    "app_server/luna_child_instructions.md": "You perform bounded lookups in the supplied files and report findings as JSON.\n",
    "app_server/delegate.py": "print('delegate stand-in')\n",
    "app_server/struis_tutor_memory.py": "print('memory stand-in')\n",
    "app_server/struis_reply_lint.py": "print('lint stand-in')\n",
    "app_server/grading_instructions.md": "Grade the learner's handwritten answers in the image. Answer with JSON matching the schema.\n",
    "app_server/set_instructions.md": "Write practice problems for the requested subunit. Answer with JSON matching the schema.\n",
    "app_server/unit_instructions.md": "Design a unit overview for the learner's request. Answer with JSON matching the schema.\n",
    "app_server/skills/struis-document/SKILL.md": "---\nname: struis-document\ndescription: Read attached documents.\n---\nUse struis.struis_document to read attachments.\n",
}


def main() -> None:
    root = Path(sys.argv[1] if len(sys.argv) > 1 else "/tmp/standin-assets")
    for relative, text in TEXTS.items():
        path = root / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text)
    for name, schema in SCHEMAS.items():
        path = root / "device_runtime/schemas" / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(json.dumps(schema, ensure_ascii=False, indent=1))
    print(root)


if __name__ == "__main__":
    main()
