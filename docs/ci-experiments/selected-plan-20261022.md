# 選択したテストで平均10分を目指す追加実験

2026-10-22。UI全件の高速化ではなく、前の判断表のprofileを実際に実行する。今回の追加実行は、新たに依頼された仮説検証の範囲。

## 最初の比較

対象は reply_tail_contract のUI3件、全Unit398件、実験設定確認probe1件。Unitは369 Passed/29 Skipped、UIは3 Passed、probeは1 Passedを期待する。成功件数だけでなく398件すべてのUnitの識別子/結果と、選択したUIの識別子/結果を確認する。新たなskip・欠落・追加・重複・失敗を成功扱いしない。probeを製品の品質検証としては数えない。

1. selected-warm-separate: 既存のmock設定による事前install/launchを行い、Unitと選択UIを別々のxcodebuildで実行。
2. selected-direct-combined: 事前のinstall/launchを行わず、Unitと選択UIを1回のxcodebuildで実行。

同じソース・Native cache・runner種別、同時最大2台、各job25分、コマンドtimeoutあり、自動再試行なし。2workerでSimulatorを複製する実験ではない。事前buildとSimulator bootは直列のまま。

この初回は2要因を変えた構成比較で、結果だけからそれぞれの因果効果を断定しない。必要な次の少数比較でdirect-separateを入れ、事前起動とコマンド統合のどちらが効くか切り分ける。追加のfull matrixや全UI実行は行わない。

## 仮説

- H1: 事前install/launchの削除で合計も短くなる。既存ログの1例ではbootstatus終了から次のstepまで約162秒。単にその時間が最初のテストへ移るなら効果なし。
- H2: Unitと選択UIの1コマンド化で、xcodebuildの再初期化とSimulator準備の重複を減らせる。実行対象の欠落をxcresultで拒否する。
- H3: 小さな機能変更は全Unit+必要な数本のUIで10分以内を狙える。3件のprofileで実測し、ヘッダー2件や論理だけ0件の時間はその実測と混同しない。
- H4: scroll/長文が必要な変更には9件のprofileが残る。最初の準備時間を見て、必要なら独立した2台への分割を限定比較する。同一VM2workerの失敗を、独立VMでの分割が失敗する証拠としない。
- H5: テスト選択の品質は既存の故障を検出できることでも確かめる。現在5件の置換は未実装で、元の3件をこの実験では省いていない。並行して代替に必要な結合テストと故障ケースを絞る。

## 計測

workflow作成→job待ち→checkout/cache→build→Simulator boot→任意warm→Unit/UI→検証→artifact保存→job完了を記録する。harnessのdecisionReadyAtは途中の検証完了時刻であり、GitHubのcheck完了時刻ではない。平均10分の判定にはGitHubのjob完了までを使う。2本比較全体のworkflow完了時刻を、各構成単独の通常merge時間と混同しない。

build/boot/install/launch/ready待ち/Unit/UI/xcresultの各ログと結果をartifactへ保存する。平均・最大・合計runner分、失敗・skip・欠落と再実行回数を残す。失敗を隠さず、アプリの失敗を成功するまで繰り返さない。

## 適用範囲

experiment/ci-overnight-20261022の新しい実験workflowと測定scriptだけ。通常CI/main/PR #39/配信/秘密情報を変更しない。workflowのpush triggerはこの実験workflowファイル自体の変更だけに限定し、結果docsのcommitでは実験を起動しない。実験後にpush triggerを外す。
