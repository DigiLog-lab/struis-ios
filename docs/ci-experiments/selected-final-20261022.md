# 選択したCIの結論と実測 — 2026-10-22

**推奨する日常構成は「全Unit/結合テスト＋変更が影響するUI」。** 記録・採点の内部ロジックを長いUI操作で重ねて毎回確認する構成から、Unitで守る性質と画面接続で守る性質へ割り当てた。全56 UIの判断は [選択表](ui-scope-decisions-20261022.md)、組込みの具体案は [日常CI設計](selected-daily-design-20261022.md) に保存した。

**通常CIでの平均10分はまだ実証していない。** 以下は明示したprofileの実験。新規VMの測定は待ち行列〜job終了を含む。準備済みworkerの区間は別欄にし、初回準備を除いたシミュレーションと明記する。

採点の内部ロジックだけを変え、DTO/action/stage/保存/画面通知の契約を保つprofileは、**全Unit・UI0件で平均9分29.5秒、最大9分56秒を実測**した。UI3件は平均で14.5秒、準備済みUI9件は32.4秒の短縮がさらに必要。実際の変更種類の比率と、通常の一連のmerge gate全体は未測定である。

## 比較

| 構成 | 回数 | 平均 | 最大 | 判定できた範囲 |
|---|---:|---:|---:|---|
| 新規VM・全Unit＋UI3件 | 2 | 10分14.5秒 | 10分30.0秒 | 600秒未達。workflow作成〜job終了 |
| 準備済みworker・全Unit＋UI9件 | 2 | 10分32.4秒 | 11分52.1秒 | 600秒未達。区間のみ。初回準備/実gate公開を除く |
| 新規VM・全Unit＋UI0件 | 2 | 9分29.5秒 | 9分56.0秒 | 600秒以内。workflow作成〜job終了 |

UI3件の新規VM構成は599秒と630秒、平均614.5秒で、厳密な600秒に14.5秒足りない。異なるprofileの実験を無条件に平均して、実際のPR全体の平均とはしない。

前の全UI構成はrunner内の平均36分51秒だった。今回の選択後の時間とは、開始点と実行範囲が違う。差の全てをrunner性能や単一の最適化の因果効果とは扱わない。

## 全試行と失敗

| 実行 | 作成〜job終了 | runner時間 | 準備済み区間〜job終了 | Unit P/S/F | 製品UI P/S/F | probe |
|---|---:|---:|---:|---|---|---|
| [新規VM・UI3件・統合コマンド1回目](https://github.com/DigiLog-lab/struis-ios/actions/runs/39703205685) | 9分59.0秒 | 9分56.0秒 | — | 369/29/0 | 3/0/0 | Passed |
| [新規VM・UI3件・事前mock起動/別コマンド](https://github.com/DigiLog-lab/struis-ios/actions/runs/39703205685) | 19分10.0秒 | 19分07.0秒 | — | 369/29/0 | 3/0/0 | Passed |
| [新規VM・UI3件・統合コマンド2回目](https://github.com/DigiLog-lab/struis-ios/actions/runs/39704905140) | 10分30.0秒 | 10分27.0秒 | — | 369/29/0 | 3/0/0 | Passed |
| [故障2件検出＋準備済みUI9件・1回目](https://github.com/DigiLog-lab/struis-ios/actions/runs/39706557023) | 21分28.0秒 | 21分22.0秒 | 9分12.6秒 | 369/29/0 | 9/0/0 | Passed |
| [新規VM・UI3件・署名省略](https://github.com/DigiLog-lab/struis-ios/actions/runs/39707332800) | 10分26.0秒 | 10分23.0秒 | — | 368/29/1 | 3/0/0 | Passed |
| [新規VM・UI0件・1回目](https://github.com/DigiLog-lab/struis-ios/actions/runs/39708942168) | 9分56.0秒 | 9分52.0秒 | — | 369/29/0 | 0/0/0 | なし |
| [準備済みUI9件・2回目](https://github.com/DigiLog-lab/struis-ios/actions/runs/39708942171) | 18分23.0秒 | 18分19.0秒 | 11分52.1秒 | 369/29/0 | 9/0/0 | Passed |
| [新規VM・UI0件・2回目](https://github.com/DigiLog-lab/struis-ios/actions/runs/39709986533) | 9分03.0秒 | 9分01.0秒 | — | 369/29/0 | 0/0/0 | なし |

P/S/FはPassed/Skipped/Failed。Unit29件は既知skipを維持し、成功には数えない。probeは実験環境の設定確認で、製品の回帰検証とは別。UI0は56件のskipではなく、契約profileの条件で選ばなかった56件である。

署名省略は1回失敗し、採用しない。`ClaudeAppAttestTests/testReinstalledDeviceRegistersANewKeyWhenTheStoredKeyIsUnusable` が、古い鍵のassertionを経由せず新規登録へ進んだとして失敗した。398 Unit＋UI3件＋probeの存在は揃い、追加skipや欠落はなかった。実装はKeychainの保存statusを捨てているため、署名/Keychainの影響が候補だが、OSStatusの直接測定はなく因果は未確定。失敗を消す再実行やassertionの弱化はしていない。

事前mock起動＋別コマンドは19分10秒。対照VMのbuild/bootも遅かったため、差の全てを事前起動削除やコマンド統合の効果に割り当てない。追加の独立比較はしていない。

## build・Simulator・テストの内訳

| 実行 | queue秒 | 初回build秒 | boot秒 | 事前warm秒 | gateのUnit/UIコマンド秒 | Unit本体秒 | UI/probe本体秒 |
|---|---:|---:|---:|---:|---:|---:|---:|
| 新規VM・UI3件・統合コマンド1回目 | 3.0 | 159.034 | 50.941 | 0.000 | 331.858 | 26.712 | 86.176 |
| 新規VM・UI3件・事前mock起動/別コマンド | 3.0 | 289.036 | 164.300 | 276.594 | 311.693 | 34.776 | 159.820 |
| 新規VM・UI3件・統合コマンド2回目 | 3.0 | 163.368 | 56.232 | 0.000 | 331.475 | 27.536 | 90.369 |
| 故障2件検出＋準備済みUI9件・1回目 | 6.0 | 167.558 | 52.180 | 0.000 | 490.379 | 23.962 | 431.332 |
| 新規VM・UI3件・署名省略 | 3.0 | 158.078 | 110.603 | 0.000 | 256.821 | 25.035 | 84.242 |
| 新規VM・UI0件・1回目 | 4.0 | 185.268 | 57.405 | 0.000 | 245.085 | 26.055 | 0.000 |
| 準備済みUI9件・2回目 | 4.0 | 171.005 | 53.876 | 0.000 | 488.925 | 25.406 | 427.955 |
| 新規VM・UI0件・2回目 | 2.0 | 168.454 | 55.052 | 0.000 | 174.583 | 25.382 | 0.000 |

コマンド秒は実時間。本体秒はxcresultの各case durationの合計で、コマンドの起動/準備/終了処理を含まない。統合コマンドのUnitとUIの別々のコマンド時間は存在しないため、本体時間を併記した。各export、artifact保存、後処理もjob終了までの時間に含む。全コマンド・phase開始/終了は隣のJSONにある。

UI0のxcresult export/照合等の後処理にも20.037秒、71.315秒の揺れがあった。2つのxcresulttoolコマンドを個別には計時していないため、これを全てJSON変換自体の費用とはしない。検証完了からjob終了までは別途46.721秒、47.029秒かかり、上の9分29.5秒には含めた。次の測定ではexportの個別時刻と、梱包/link時のI/O・メモリも記録する必要がある。

## 準備済みworkerの測定条件

- 故障2件検出＋準備済みUI9件・1回目: equivalentな1行のsource editから、rebuild 45.563秒、全Unit＋UI9件 490.379秒、export完了まで8分57.0秒、artifact/後処理を含むjob終了まで9分12.6秒。runner内でそれ以前に12分09.4秒を使用。
- 準備済みUI9件・2回目: equivalentな1行のsource editから、rebuild 204.299秒、全Unit＋UI9件 488.925秒、export完了まで11分34.4秒、artifact/後処理を含むjob終了まで11分52.1秒。runner内でそれ以前に6分26.9秒を使用。

1回目はbaselineの後に2つの故障をbuild/testしており、2回目は最初のbuildとbaselineの2 Unitだけを準備に使う。どちらも同じ1行の等価変更だが、事前のcompiler cacheの温まり方は同一ではない。compiler cacheと通常の増分buildを独立に比較していない。別VMへcompiler cacheを永続化する処理はない。

増分buildは45.563秒から204.299秒へ増えた。build timingのLdは2.727→96.373秒、Package Python phaseは16.809→46.767秒。SwiftCompileは8.379→4.706秒であり、増加をSwiftソースのコンパイルやcacheだけの原因とはしない。task秒は並行作業を含むため、足し合わせてwall秒にはしない。I/O/メモリ等の根本原因は未計測である。

等価変更はcommitせず、working treeのpatchとしてartifactに保存し最後に復元した。これは実際の新しいHEADのmerge checkではない。初回のqueue/build/boot/installを集計から隠して達成としたものではなく、job全体と区間を併記した測定である。実際のagent workerへの組込み、Linuxでの結果取得とcheck公開までの一連の時間は未測定。

## 省略しても守れた性質と残すUI

| 意図的な故障 | 既存のUnit/結合テスト | 検出結果 |
|---|---|---|
| 記録だけの間にも入力をbusyにする | `ReplyTailQueueTests/testSendDuringPrivateTailQueuesWithoutStoppingTheRecord` | 期待したXCTAssertFalseで失敗。test command 33.825秒、本体0.888秒 |
| 未提出を残したセットを早く閉じる | `WorkbookRulesTests/testSetCapturedInThreePhotosIsGradedAsOneSet` | 期待したXCTAssertTrueで失敗。test command 25.125秒、本体0.169秒 |

baselineは両方Passed。2つの意図的失敗を「アプリ成功」には数えない。復元後は全Unit＋scroll UI9件＋probeがPassed/既知skipの完全一致だった。2故障での検出は、その性質をUnitへ寄せる根拠になる。全ての故障や、UI操作の接続まで置換できた証明とはしない。

UI3件は記録中の送信、ready状態での進む、ready前後と再訪の表示/遷移を残した。UI9件は最初のdrag、指を離した後のjump、数式上の縦/横gesture、返信到着時の読位置、段を進めた追従、長文40往復＋送信/scroll20回等を残した。全56件について、各試行のPassed/NotSelected、除外理由、置換条件、欠落・余分・結果変化をJSONに保存した。

5件の短縮置換は全assertionの対応が終わるまで元UIを関連変更時に残す。複数画像のStore受渡し、再起動保存等の結合テストの不足、専用環境のUI10件、既知29 Unit skip、keyboardなし時の後半return、画像/滑らかさをassertしていない箇所は残課題。過去の2workerでのslider/Journey失敗も解決扱いしない。

## 検証した仮説の採否

| 仮説 | 判断 |
|---|---|
| 変更に無関係なUIを外し、全Unit＋対象UIにする | 採用候補。UI3件/0件のcold実行とUI9件のwarm実行を測定。自動の意味判定は未実装 |
| 同じ機能の内部ロジックをUnitで守る | 2つの具体的故障を検出。画面の結線はUIを維持。5件全ての置換は未完了 |
| 毎回mock起動してからUnitとUIを別々に起動する | 今回の対照は遅い。優先しない。ただし単一要因の因果比較ではない |
| 準備済みの作業workerで1回検証する | 優先して組込みを検討。時間窓と初回準備を分けた実測であり、通常gateの平均達成とは未判定 |
| Simulator署名を外す | Unitが失敗したため採用しない |
| 同一VMで2 Simulator workers | 既知の複製/UI失敗があり今回再採用しない。別VM分割の引数は用意したが未実測 |
| 同じHEADの成功証拠を別の門で照合する | raw artifactによるoffline試作が動作。外部iOS再実行の置換は未組込み |
| 軽いtest host、モジュール依存グラフ、cross-source結果再利用 | 次の設計候補。実装・時間短縮・安全性の実証はしていない |

## 使用量・保存したもの

今回の選択後のmacOS実験は8 jobs、runner合計 **108.450分**。失敗の署名省略と故障検出の準備も含み、VMごとの開始〜終了を合計した。これは料金明細ではない。前の全件夜間実験12 jobs・332.82分とは別集計。実験固有のmatrix待ちを通常のmerge時間へ足していない。各回のqueueは表に記録した。

実測の最大同時macOSは2 VM。選択gate全体はUnit/UI/probe計3220件で、2987 Passed・232既知skip・1 Failed。baselineの2 Unit×2回と意図的故障2件はこの件数と別に保存した。今回実行した製品UIは重複を除いて12件であり、全56件を今回実行した意味ではない。

全試行のraw xcresult、コマンド、source patch、Unit398件/対象UIの完全照合、artifact ID/hash、run/commitは [JSON](selected-final-20261022.json) とrunのartifactに保存。artifactは7日保持。通常CI/main/PR #39/配信は未変更。実験用push triggerを外して終了し、追加の長時間実行は開始しない。

`sourceCommit` は比較元の `d3fe8a59acffe7fe21f87941e6f9863047813e8e`。実際のcheckoutは各 `measurement.commit` で、warm quality試行には記録したworking-treeのpatchもある。Python側の完全性/失敗/欠落/出所/HEAD照合等27テストが成功した。自動の意味選択・通常CIへの組込みを完了したという意味ではない。

[exact-HEAD照合の試作結果](selected-receipt-proof-20261022.json) / [日常CIへの組込み案と未実装の境界](selected-daily-design-20261022.md) / [全UIの選択・除外判断](ui-scope-decisions-20261022.md)
