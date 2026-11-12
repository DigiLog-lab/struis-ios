# オフライン反復モード「問題の型」 進捗

再開する時は、まずこのファイルを読む。指示書は 2026-11-12 に持ち主（@Tomochika）が渡した「Fable向け指示書: Struis オフライン反復モードの問題の型」。作業ブランチは `agent/offline-drill` の 1 本。Draft PR は最後に 1 本だけ出す。

## 今の段階

- 2026-11-12 19:15 **指示書の完了条件の 5 つを満たし、Draft PR を 1 本出す所(出した後は、持ち主のレビュー待ち)。**
- 終わったもの:
  1. 書式の仕様書(`docs/offline-drill/format.md`)と JSON Schema(`strius/Resources/Prompts/drill_template.json`)。
  2. 解釈器・生成器・点検器(`strius/Engine/Drill/`)と単体テスト。
  3. 一覧 459 行(型 421、うち数値点検あり 414、数値点検なし 7、書式で表せない 38)。全部の型が点検を通ることを `DrillCatalogTests` が固定している。
  4. 型を書かせる指示文(`strius/Resources/Prompts/drill_template_instructions.md`)、返事の点検(`DrillAuthoring`)、保存先(`DrillTemplateStore`)。
  5. 画面のプロトタイプ(`OfflineDrillLabView`)とスクショ(`docs/offline-drill/screenshots/`)。
- Dev Box(run 43189677517、Xcode 27.1、iPhone 17 のシミュレータ)で確かめたこと(コードは caef00a):
  - `xcodebuild build-for-testing` が通る。
  - 追加した単体テストと、台帳まわりの既存の単体テスト(`LedgerTests`・`LedgerMigrationTests`・`LearningErasureTests`・`UnitDeletionTests`)の計 158 件: 157 件が合格、1 件は前からある飛ばし(`UnitDeletionTests.testLateGradingGenerationChatAndPrefetchNeverRestoreDeletedUnit` は環境変数を付けた時だけ動く)。
  - 一覧の全部の型について、作った問題文・式・答えの数式を SwiftMath が読める(`OfflineDrillLabTests.testEveryTemplateRendersWithSwiftMath`)。
  - プロトタイプの画面を実際に組み、余白と問題文の上の指は書く面に届き、ボタンの上の指はボタンに届く(`OfflineDrillLabTests.testMarginIsWritableWithAFingerAndTheButtonsStayTappable`)。
  - Linux(Swift 6.4.2)でも `striusTests/Drill/` の 105 件が合格。種を決めた生成の結果は Linux と iOS で同じ(`DrillGeneratorTests` の固定の期待値が両方で通る)。
- 確かめていないこと:
  - **指示文を実際の AI に渡して型を書かせること。** 指示書の範囲は「指示文と、その返事を点検できることまで」で、AI を呼ぶ所にはつないでいない。試すには持ち主の API の鍵で呼ぶことになるので、頼まれていない呼び出しはしていない。
  - シミュレータの画面に指で実際に線を書くこと。Dev Box には画面に触る道具が無く(`idb`・`cliclick` は入っていない、`simctl` に触る命令は無い)、UI テストは書かない決まりなので、指が届く先を単体テストで確かめる所までにした。書く面はタイムラインと同じ `TimelineInkCanvas`。
  - iPad の横向きのスクショ(`simctl` では向きを変えられない)。iPad は縦向きだけ撮った。横向きの並び(問題を左の列に置く)はタイムラインと同じ式で書いてあるが、画面では見ていない。
- Dev Box の 1 回目の立ち上げ(run 43188318664)は、ビルドに失敗した。立ち上げた時点のブランチ(57184bb)では、`strius/Engine/Drill/` を Xcode のプロジェクトに登録していなかったため(`striusTests/Drill/` は自動で入るので、テストだけが型を見つけられなかった)。793a486 で登録して立ち上げ直した。
- プロトタイプで直したこと: 文字サイズを大きくすると、問題の式と答えの式の右側が切れていた(書く面が上に乗っていて、式を横にスクロールできない)。式が列の幅に収まる大きさまで小さくするようにした(dafd137)。

## 段階ごとの道具

- Linux で回す: `cd scripts/offline-drill && swift test`(`/opt/swift/usr/bin` に Swift 6.4.2 を入れてある。入っていなければ swift.org の ubuntu24.04 向けを入れる)。
- 型を点検する: `cd scripts/offline-drill && swift run drillcheck check ../../striusTests/Fixtures/drill-templates --show 2`。
- Dev Box: `python3 scripts/devbox/mac.py start agent/offline-drill` → `mac.py ready` → `mac.py run -- …`。使い終わったら `mac.py stop`。

## 型を書き終えた範囲

一覧の正本は `striusTests/Fixtures/drill-templates/catalog.json`、読む用の文書は `docs/offline-drill/catalog.md`(単体テストが作る)。

- 数学: 中学 1〜3 年、数学 I・A・II・B・C・III、大学初年(偏微分・重積分・行列・微分方程式・フーリエ係数)まで全部。263 行、型 240。
- 物理: 高校(力学、熱、波、電磁気、原子)と大学初年(微積分を使う力学、剛体、振動、電磁気、熱力学)まで全部。126 行、型 118。
- 化学: 化学基礎、化学(気体・溶液・熱化学・電池・反応速度・平衡・有機の元素分析・高分子)、大学初年(反応速度論、化学熱力学、電気化学、緩衝液、吸光度)まで全部。70 行、型 63。

## 書式の変更の記録

- 2026-11-12 版 1 を作った。最初の試し書き(正負の数、分数、一次方程式、連立方程式、解の公式、二次不等式、三角比、積の微分、定積分、部分積分、複素数、行列、等加速度運動、単位換算、物質量、pH)で次を直した。
  - 不等式の点検の `relation` に差し込みを書けるようにした(不等号を選択肢にする型のため)。
  - `\mathrm{pH}`・`\vec{a}`・`\begin{cases}` などの直後の `{名前}` は差し込みにしない(同じ名前の変数があると、文字が値に置き換わってしまったため)。
  - `{k|coef}{p|paren}` のように差し込みが続く時、後ろを波かっこで囲まない(`\frac{a}{b}` の b は囲む)。
  - 表示の点検: 積分・総和の上端(`\int_{0}^{1}`)を指数と見なさない。分母の負の符号は、分母が数だけの時に限って指摘する。改行(`\\`)をまたいで係数を見ない。
  - 変数名に関数名(`q` など)を使えるようにした。使えないのは `pi`・`e`・`i`・`true`・`false`・`and`・`or`・`not` だけ。

- 2026-11-12 数学の網羅の途中で次を足した・直した(そのたびに、それまでの型を全部点検し直した)。
  - `parts` に `product`(べきの積。素因数分解、単項式)を足した。
  - 関数に `mean`・`nth`・`divisors` を足した(データの代表値・四分位数、約数の個数の確かめ)。
  - 不等式の点検に `where`(確かめる範囲)を足した(定義域のある二次関数の最大・最小を、定義域の中で確かめるため)。
  - 前に命令も `^` も `_` も無い `{名前}` で、名前が宣言されていないものは、読み込みで断るようにした(宣言し忘れた差し込みが `{cosA}` のまま画面に出ていたのを、余弦定理の型で見つけた)。
  - 複素数の表示の誤りを直した: 実部が 2 項で両方とも負の時に `-√2-√6` を `-√2+√6` と出していた(極形式の商の型の数値点検で見つかった)。
  - 微分の点検: 特異点の近くで差分の誤差が大きい時は、差分の幅を縮めて確かめ直す。微分方程式の点検: 許す誤差を、各項の大きさに対する割合にした(係数の大きい式で、差分の誤差だけで落ちていたため)。
  - 点検にかかる時間を縮めた: 総当たりは 4,000 通りまで(超えたら 2,000 組を抽出)、表示の点検は最初の 400 問とその後 16 問に 1 問、数値の点検は 48 問。型 240 個の点検が Linux の 2 コアで約 16 秒。

- 2026-11-12 物理・化学の網羅の途中で次を直した(そのたびに、それまでの型を全部点検し直した。書式の項目は増やしていない)。
  - `approx(a, b, 誤差)` が、誤差なしの数どうしでは誤差を見ずに「完全に等しいか」で比べていた。数値で比べるように直した。
  - `{x|abs|q}` や係数の位置で、`1.2 \times 10^{3}` の形の数にかっこを付けていた。かっこは係数として文字に掛かる時だけにした。
  - とても小さい定数・大きい定数(プランク定数 `6.63e-34`、電子の質量、アボガドロ定数)が 64 ビットの分数に収まらず実数になり、有効数字の丸めが境目に乗って点検で落ちる型が続いた。分子・分母を 128 ビットで持つ段を足した(64 ビット → 128 ビット → 実数の順に落とす)。
  - SwiftMath(`1d2c908`)は平衡の矢印(`\rightleftarrows`、`\rightleftharpoons`)を描けない(命令の表に無いことをソースで確かめた)。表示の点検はこの命令を断る。平衡の式は、式の外の文字として `$\mathrm{H_2} + \mathrm{I_2}$ ⇄ $2\mathrm{HI}$` と書いた。

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
- **開発用の入口**(画面のプロトタイプ): DEBUG のビルドだけで、起動引数 `-offline-drill-lab` を付けた時に `AppRootView` から直接開く。既存の `-problem-catalog-lab`(`ProblemCatalogLabView`)と同じ仕組み。設定の開発者向けの画面(`DeveloperSettingsView`)に置く案は、内部向けビルドの本番の画面から辿れてしまうので採らなかった。`OfflineDrillLabView.swift` と `OfflineDrillLabSamples.swift` は全体が `#if DEBUG` で、Release のビルドには入らない。
- **プロトタイプで見せる型**: 型の JSON はテストの資産でアプリに入っていないので、11 個(数学 7、物理 2、化学 2)を `scripts/offline-drill/make_lab_samples.py` で Swift の文字列に写した。写しが正本と同じで、端末の点検(SwiftMath での描画を含む)を通ることを `OfflineDrillLabTests` が確かめる。偽のデータは置いていない。
- **プロトタイプの画面**: タイムラインの部品をそのまま使った(地の色、`TimelineChip`、`TimelineQuestionText`、`TimelineMath`、`TimelineActionButton`、`TimelineInkCanvas`)。書く面は画面全体を覆い、右下のボタンの上だけ指を通す。2 案は起動引数 `-offline-drill-variant answer`(「答え」を押した時だけ見せる)と `next`(答えを出さず「次へ」だけ)。左上の「オフライン」から、型と案をその場で切り替えられる。問題文が画面より長い時のスクロールは作っていない(本番ではタイムラインの列のスクロールを使う)。
- **型の保存先**: 台帳(GRDB の同じ SQLite)の中の、端末だけの控えの表 `drill_templates`(移行 `v7-drill-templates`、`strius/Ledger/DrillTemplateStore.swift`)。台帳のイベント(`ledger_events`)には入れない。Claude との会話の控え(`ClaudeConversationStore`、移行 `v6-claude-conversations`)と同じ扱い。理由:
  - 型は学習の記録ではなく、点から AI に書かせ直せる派生物。消えても学習の記録は欠けない。
  - 型は端末の点検を通ったものだけを出す。点検器と書式の版はアプリの版ごとに違い得るので、別の端末が通した型を iCloud 同期で受け取ってそのまま出すことはできず、受け取った側でも点検が要る。
  - 書式の版が上がったら全部を書かせ直す。追記だけのイベントに入れると、古い版の型が履歴と同期に残り続ける(型 1 個は 1〜4 KB)。
  - イベントの適用・同期・作り直し(`Ledger.rebuild`)のコードに触れずに足せる(オンラインのタイムラインを変えない、という指示書の範囲)。
  - 代わりに失うもの: 端末ごとに AI への依頼が 1 回ずつ要る(iPhone と iPad を両方使う人は 2 回)。後から同期したくなったら、型をイベントに昇格させる。
  - 学習記録の消去(`eraseLearningRecords`)ではこの表を空にし、単元の削除(`Ledger.eraseHistory`)では消す点の行を消す。
  - 対象から外した点(2 回落ちた・AI が「型にできない」と答えた)も行を残す。同じ書式の版の間は頼み直さない。
- **型を書かせる依頼**: 頼むのは `kind` が `procedure` と `combination` の点だけ(`DrillAuthoring.isCandidate`)。`concept` と `memorized` は、指示書の対象外(概念の理解・暗記)なので AI を呼ばない。返事は `{"template": 型か null, "reason": 文}`。AI が「型にできない」と判断した時に null を返せるようにした(図を読む点などで、落ちると分かっている型を 2 回書かせないため)。
- **指示文**(`strius/Resources/Prompts/drill_template_instructions.md`): 前半は、型が何に使われるか・よい型・型にできない点・端末の点検で起こる失敗を、理由つきで書いた(条件分岐の規則は積んでいない)。後半の「書式」は仕様書(`format.md`)の同じ範囲の写しで、例の 3 つは実際の型そのもの。写しと例が正本とずれていないこと、解釈器が読める関数・部品・点検の種類が全部書いてあること、JSON Schema のキーが解釈器と同じことを、`DrillAuthoringTests` が確かめる。
- **AI を呼ぶ所にはつないでいない**(指示書の範囲外)。つなぐ時は、`DrillAuthoring.input(for:)` と指示文・`replySchema` を渡し、返事を `DrillAuthoringSession.receive(reply:)` に入れ、`.retry(message:)` ならその文を返してもう 1 回、`.finished` なら `DrillTemplateStore.save` に渡す。端末では `DrillRenderProbe.validator`(SwiftMath で読めるかも見る)を使う。
- **マージの時の UI テスト**: この変更は `strius/App/AppRootView.swift`(開発用の入口)と `strius/Resources/Prompts/`(指示文)に触るので、`scripts/ci/ui_test_plan.py` は UI テストを全部(55 本、合計約 52 分)選ぶ(2026-11-12 に `--list` で確認)。Dev Box では UI テストを流していない。
