# 選択したCIの初回実測 — 2026-10-22

全Unit398件とreply_tail_contractのUI3件、実験設定probe1件を実行した。

| 構成 | 作成からcheck完了 | 待ち | runner | Unit | 製品UI | 再実行 |
|---|---:|---:|---:|---|---|---:|
| 事前install/launchなし・1コマンド | 599秒（9分59秒） | 3秒 | 596秒 | 369 Passed /29既知skip | 3 Passed /0skip /0failed | 0 |

build159.03秒、boot要求7.16秒、boot完了待ち43.79秒、Unit+UIコマンド331.86秒。テスト本体合計112.89秒（製品UI84.55秒、probe1.63秒、残りがUnit）。コマンド内の準備・終了等に約219秒ある。事前warmを外せばその時間が全て消える、という結果にはなっていない。

harnessでの検証完了は01:10:46 UTC、GitHub job完了は01:11:14 UTC。599秒の算出には後者を使い、artifact保存・post-action・job終了まで含む。比較相手のjob終了はこの構成単独のmerge判定には加えない。1回の成功で平均10分や低い失敗率を達成したとは言わない。

398件すべてのUnit識別子/結果を前の成功時と照合し、UI3件とprobeの欠落・新規skip・失敗・重複・余分なテストも拒否した。結果チェックの7本のテストと、既存の実xcresultに対する照合も通過した。probeは製品の品質検証として数えない。

[run](https://github.com/DigiLog-lab/struis-ios/actions/runs/39703205685) / [commit](https://github.com/DigiLog-lab/struis-ios/commit/5df4eb2d6dc824b49218410510882a4224583c56)

次は同じアプリ/Unit/UIでdirect-combinedをもう1回測る。最初のwarm対照が続いている間は空いた1台だけを使い、同時macOS合計を2台以下に保つ。対照終了待ちを作らない別の実験concurrency groupを使う。追加されたseparate-VM割当機能は既定1台では使わず、反復する範囲を変えない。

通常CI/main/PR #39/配信は未変更。平均・最大は反復が揃ってから計算する。
