# オフライン反復モード「問題の型」 進捗

再開する時は、まずこのファイルを読む。指示書は 2026-11-12 に持ち主（@Tomochika）が渡した「Fable向け指示書: Struis オフライン反復モードの問題の型」。作業ブランチは `agent/offline-drill` の 1 本。Draft PR は最後に 1 本だけ出す。

## 今の段階

- 2026-11-12 17:10 **段階 2(書式・解釈器・生成器・点検器)が終わり、段階 3(数学の一覧と型)に入る所。**
- 終わったもの: 事前検証、書式の仕様書(`docs/offline-drill/format.md`)、JSON Schema(`strius/Resources/Prompts/drill_template.json`)、解釈器・生成器・点検器(`strius/Engine/Drill/`)、単体テスト 86 件(`striusTests/Drill/`、Linux の Swift 6.4.2 で全部通過)。
- まだのもの(この順で進める): 数学の一覧と型 → 物理・化学の一覧と型 → 型を書かせる指示文と保存場所 → 画面のプロトタイプ → Dev Box で単体テストとスクショ → Draft PR。
- Dev Box ではまだ 1 度もビルドしていない(Linux だけで確かめた)。iOS 側のビルドとテストは段階 6 でまとめて確かめる。

## 段階ごとの道具

- Linux で回す: `cd scripts/offline-drill && swift test`(`/opt/swift/usr/bin` に Swift 6.4.2 を入れてある。入っていなければ swift.org の ubuntu24.04 向けを入れる)。
- 型を点検する: `cd scripts/offline-drill && swift run drillcheck check ../../striusTests/Fixtures/drill-templates --show 2`。
- Dev Box: `python3 scripts/devbox/mac.py start agent/offline-drill` → `mac.py ready` → `mac.py run -- …`。使い終わったら `mac.py stop`。

## 型を書き終えた範囲

- まだ無い(試し書きは `/tmp` に置いただけで、リポジトリには入れていない)。

## 書式の変更の記録

- 2026-11-12 版 1 を作った。最初の試し書き(正負の数、分数、一次方程式、連立方程式、解の公式、二次不等式、三角比、積の微分、定積分、部分積分、複素数、行列、等加速度運動、単位換算、物質量、pH)で次を直した。
  - 不等式の点検の `relation` に差し込みを書けるようにした(不等号を選択肢にする型のため)。
  - `\mathrm{pH}`・`\vec{a}`・`\begin{cases}` などの直後の `{名前}` は差し込みにしない(同じ名前の変数があると、文字が値に置き換わってしまったため)。
  - `{k|coef}{p|paren}` のように差し込みが続く時、後ろを波かっこで囲まない(`\frac{a}{b}` の b は囲む)。
  - 表示の点検: 積分・総和の上端(`\int_{0}^{1}`)を指数と見なさない。分母の負の符号は、分母が数だけの時に限って指摘する。改行(`\\`)をまたいで係数を見ない。
  - 変数名に関数名(`q` など)を使えるようにした。使えないのは `pi`・`e`・`i`・`true`・`false`・`and`・`or`・`not` だけ。

## 点検に落ちている型

- まだ無い。

## 自分で決めたことと理由

- **Linux の Swift**: 作業環境に Swift は入っていなかった(2026-11-12 に `which swift` で確認)。swift.org の 6.4.2(ubuntu24.04)を `/opt/swift` に入れた。Dev Box の Xcode 27.1 も Swift 6.4。
- **コードの置き場**: `strius/Engine/Drill/`。Foundation だけに依存させ、GRDB にも SwiftUI にも触れない。Linux では `scripts/offline-drill/Package.swift` が、このフォルダと `striusTests/Drill/` をシンボリックリンクでそのまま読む(コードの写しは作らない)。モジュール名をアプリと同じ `strius` にして、テストの `@testable import strius` を両方で通す。
- **型の JSON の置き場**: `striusTests/Fixtures/drill-templates/<教科>/<id>.json` と `catalog.json`(操作の一覧の正本)。テストの資産にして、アプリ本体には入れない(アプリを軽くしたい、という持ち主の方針)。`docs/offline-drill/catalog.md` は `catalog.json` から単体テスト(`DrillCatalogTests`)が作る。
- **数の持ち方**: 分数と平方根(複素数を含む)は誤差なしで持つ。物理・化学の小数も、10 進の表記どおりの分数で持ち、有効数字の丸めを誤差なしで行う。誤差なしで持てない値(対数、ラジアンの三角関数)だけ Double。理由は、Double で 2.5 のような丸めの境目に乗ると、端末によって答えの表示が変わり得るため。
- **単位**: 式の中では全部 SI の値で計算し、表示する時に宣言した単位に戻す。型に換算の係数を書かせない。式の次元と宣言した単位が合わなければ点検で落とす。理由は、物理・化学の公式は数値で独立に確かめにくく、次元の確認が公式の書き間違いを見つける一番確実な手段だから。
- **式の形の答え**(多項式など): 数式処理は作らず、係数を数として計算して `sum` の部品で組み立てる。整形規則(係数 1、+-、x^1、0 の項)は部品の側に持たせ、型を書く AI には係数の式だけを書かせる。
- **数値の点検の方法**: 画面に出す LaTeX そのものを数値にして、答えと比べる。型の式どうしを比べるだけだと、画面に出る式と答えの食い違いを見つけられないため。
- **問題の数の下限**: 違う問題が 20 通り以上(指示書の目安どおり)。条件を満たす組の割合は 1% 以上(生成器が 4,000 回まで選び直すので、1% あれば見つからない確率は無視できる)。
- **開発用の入口**(画面のプロトタイプ): 既存の `-problem-catalog-lab` と同じ、DEBUG の起動引数で `AppRootView` から直接開く形にする予定。本番の画面からは辿れない。
