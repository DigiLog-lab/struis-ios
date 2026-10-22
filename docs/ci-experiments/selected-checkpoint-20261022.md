# 選択したCIの実測 — 2026-10-22

全Unit398件とreply_tail_contractのUI3件、実験設定probe1件を実行した。

| 構成 | 回数 | 作成からcheck完了 | Unit | 製品UI | 再実行 |
|---|---:|---:|---|---|---:|
| 事前install/launchなし・1コマンド | 2 | 599秒、630秒。平均614.5秒（10分14.5秒）、最大10分30秒 | 各369 Passed /29既知skip | 各3 Passed /0skip /0failed | 0 |
| 事前mock起動あり・別コマンド | 1 | 1150秒（19分10秒） | 369 Passed /29既知skip | 3 Passed /0skip /0failed | 0 |

全て待ち3秒。job終了まで含み、検証完了時刻だけで10分達成とはしない。3jobのrunner合計は2370秒（39.5分）。この候補の厳密な平均600秒はまだ未達。通常CIへの適用もしていない。

## 内訳

- direct1: build159.03秒、Simulator50.94秒、Unit+UI331.86秒。テスト本体112.89秒。
- direct2: build163.37秒、Simulator56.23秒、Unit+UI331.47秒。
- warm対照: build289.04秒、Simulator164.30秒、事前install/launch/ready等276.59秒、Unit97.35秒、UI214.35秒。

対照は同じアプリソースでもbuildとbootが遅かった。2要因を変えた構成比較で、全差分を事前起動削除やコマンド統合の因果効果とはしない。directでもコマンド内の準備/終了処理に約219秒が残り、事前warmの費用が全て消えたわけではない。

398件すべてのUnit識別子/結果を前の成功時と照合し、UI3件とprobeの欠落・新規skip・失敗・重複・余分なテストも拒否した。結果チェックの9本のテストと、既存の実xcresultに対する照合も通過。probeは製品の品質検証として数えない。2回の計測から低い失敗率や全PRの平均を保証しない。

## 次の仮説

scripts/agent/delivery.pyのlocal_verifyはエージェントのMacでbuild/Unit/UIを行い、scripts/agent/gate.pyが同じHEADの外部gateを開始する。準備済みworkerで一度検証した記録を制御側が確認する案を調べる。新規VMを繰り返し起動する時間を、単に集計から除外する案ではない。

[品質・準備済みVMの実験計画](selected-quality-plan-20261022.md)では、既存の速い結合テストで2つの具体的な故障を検出し、最後に準備済みVMで小さな等価ソース変更を再ビルドして全Unitと長文/scroll UI9件を実行する。後半の再検証時間と、初回の冷たい準備を含むjob全体を別に記録する。

- [最初の2構成](https://github.com/DigiLog-lab/struis-ios/actions/runs/39703205685)
- [directの2回目](https://github.com/DigiLog-lab/struis-ios/actions/runs/39704905140)
- [全測定・識別子照合・元のcommit・artifact hash](selected-checkpoint-20261022.json)

通常CI/main/PR #39/配信は未変更。全UI matrixや無限の再実行は行わない。
