#!/usr/bin/env python3
"""画面のプロトタイプ(`OfflineDrillLabView`)に入れる型の写しを作り直す。

型の正本は striusTests/Fixtures/drill-templates/ で、アプリ本体には入れていない。プロトタイプは開発用のビルド
(DEBUG)だけにあり、そこで見せる型をこのスクリプトが Swift の文字列として写す。写しが正本と同じであることは、
単体テスト `DrillLabSamplesTests` が確かめる。

    python3 scripts/offline-drill/make_lab_samples.py
"""
from __future__ import annotations

import json
import pathlib

ROOT: pathlib.Path = pathlib.Path(__file__).resolve().parents[2]
FIXTURES: pathlib.Path = ROOT / "striusTests" / "Fixtures" / "drill-templates"
TARGET: pathlib.Path = ROOT / "strius" / "Features" / "OfflineDrill" / "OfflineDrillLabSamples.swift"

# 見せる型(教科と表示の種類が偏らないように選ぶ)。
SAMPLES: list[str] = [
    "math/math.m1.complete_square_vertex.json",
    "math/math.jhs1.fraction_add_sub.json",
    "math/math.jhs3.quadratic_formula.json",
    "math/math.m1.quadratic_inequality.json",
    "math/math.m2.derivative_polynomial.json",
    "math/math.m3.derivative_product.json",
    "math/math.univ.determinant_3x3.json",
    "physics/physics.mech.velocity_time.json",
    "physics/physics.em.coulomb_law.json",
    "chemistry/chemistry.basic.neutralization_titration.json",
    "chemistry/chemistry.theory.equilibrium_constant.json",
]


def main() -> None:
    lines: list[str] = [
        "#if DEBUG",
        "import Foundation",
        "",
        "// scripts/offline-drill/make_lab_samples.py が作る。手で直さない。",
        "// 型の正本は striusTests/Fixtures/drill-templates/。同じ中身であることは DrillLabSamplesTests が確かめる。",
        "",
        "/// 画面のプロトタイプで見せる型(実際に書いて点検を通した型の写し)。",
        "nonisolated enum OfflineDrillLabSamples {",
        "    /// 正本のファイル(striusTests/Fixtures/drill-templates からの場所)と、その中身。",
        "    static let sources: [(path: String, json: String)] = [",
    ]
    for path in SAMPLES:
        template: dict[str, object] = json.loads((FIXTURES / path).read_text(encoding="utf-8"))
        text: str = json.dumps(template, ensure_ascii=False, sort_keys=True, separators=(",", ":"))
        assert '"###' not in text
        lines.append(f'        (path: "{path}", json: #"""')
        lines.append("        " + text)
        lines.append('        """#),')
    lines += ["    ]", "}", "#endif", ""]
    TARGET.write_text("\n".join(lines), encoding="utf-8")
    print(f"{TARGET.relative_to(ROOT)}: {len(SAMPLES)} 件")


if __name__ == "__main__":
    main()
