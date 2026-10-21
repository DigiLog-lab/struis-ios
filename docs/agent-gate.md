# Issueエージェントの手元検証とReadyの門

方針の定義は [verification-and-delivery-policy.md](verification-and-delivery-policy.md) に従います。この文書は仕組みの説明です。

## 流れ

1. `agent.yml` のmacOS workerで全項目を実装する。人の指示は新規セッション、中断だけ保存したセッションを再開する。
2. `agentctl items` → `item-complete ID --note ...` で各項目の完了を記録する。本文の番号付き／チェックボックス項目と、権限のある人のコメントを対象にする。本文・コメントの全文はrequest snapshotに保持し、項目本文が変われば完了を無効にする。
3. `request-pr` は1つのDraft PRを作成・更新する。WIPのpushでは門を起動しない。
4. 全項目完了後、commit・pushし、`local-verify` を流す。ビルドは1回、全 `striusTests` と、`ui_test_plan.py` の必須E2E＋差分UIを `test-without-building` で実行する(カメラのテストも含む)。
5. `xcresulttool get test-results tests --format json` で実行名・結果・時間を取得する。空の結果、失敗、期待失敗、実行中のHEAD変更は成功にしない。既存の外部入力不足によるskipは実行記録に残す。記録・依頼・項目を完全なチェックポイントとして保存する。
6. `ready` は全項目完了・remoteと同じHEAD・そのSHAと依頼に対応する手元検証成功を確認し、PR本文へ実行一覧・結果・時間を記載する。Draftを外して `repository_dispatch`(`agent-gate`)で制御ジョブを起こし、macOS workerを終了する。人がGitHubでDraftを外した場合も、制御ジョブが最新チェックポイントを同じ手順で検証する。
7. 制御ジョブ(`agent.yml` の `control`、Linux)がXcode CloudのPR Gateを起動する。Xcode CloudがHTTP 4xxで開始を断った場合(今月の時間切れなど)は、mainの `ios.yml` へ対象の厳密なSHAを渡す。どちらの場合もLinuxの `agent-tests.yml` を明示的に実行する。
8. 制御ジョブは門の実行中、1分ごとに結果を照合して待つ(最長 `gateWatchMinutes` 分)。Xcode Cloudのcheck run・commit status、`iOS`／`Agent tests` の完了、1時間ごとの照合でも同じ照合を行う。緑ならcommit statusを `success` にして同じIssueのrouteを起こし、完了を記録する(macOSは使わない)。赤ならDraftへ戻し、失敗したHEAD・元の依頼・結果だけを渡してmacOS workerを起こす。修正後も全体の手元検証をやり直す。

門とは別の診断として、同じリポジトリのPRに `ios-verify` ラベルを付けた時だけGitHubのiOS検証を実行できる。checkoutはPRのHEAD SHAを明示し、署名・配信は行わない。ラベルを付けたままpushしても再起動しない。

Ready後のHEAD変更・Draft化・closeで古い結果を無効にする。Xcode Cloud APIは開始時にcommit SHAを指定できず、ブランチ参照を指定する。そのため開始時と完了時に `sourceCommit.commitSha` を照合し、異なるSHAを合格にしない。別workflowの結果も採用しない。Cloudの完了判定は全体のstatusだけでなく、実際のTEST actionとテスト結果一覧も照合する。手元の全単体・選択UIから除外表の分だけを引いたメソッドが欠けている場合、0件の場合、期待失敗がある場合は合格にしない。

Xcode Cloud／予備iOSの開始が応答の不明な通信エラーで終わった場合は、同じビルドを二重に起動しないよう、Draftへ戻して開始エラーをIssueへ記録する。HTTP 4xxの応答はビルドが作られていないので、予備へ切り替える。Readyへの変更がまだ確認できない段階は `ready-pending` とし、変更直後にrunnerが失われても復旧ジョブが実際のPRを確かめ、ReadyならLinuxで引き継ぐ。門の結果待ちは中断の連続3回の自動再開を消費しない。

## 権限と、エージェントが変えられないもの

| ジョブ | 主な権限 | 役割 |
|---|---|---|
| `worker`(macOS) | `contents: write`、`issues: write`、`pull-requests: write`、`actions: read` | 実装・手元検証・Ready。起動は `repository_dispatch` |
| `control`(Linux) | `statuses: write`、`actions: write`、`pull-requests: write` と Appleのキー | 門の起動・照合、commit status、workerを起こす、依頼に応じたXcode Cloudのビルド |
| `checkpoint-gc`・`cleanup`(Linux) | `actions: write` | チェックポイントのArtifactとDerivedData cacheの削除 |

- workerは `actions: write` を持たないので、門を決める実行のRe-run・取消・Artifactの削除ができない。
- workerは `statuses: write` を持たないので、門の結果のcommit status `Struis / Ready gate` を書けない。依頼の完了・修正の開始は、保存先の記録とこのstatusの両方が一致した時だけ行う(保存先は、どの `agent.yml` のジョブからも書けるため)。
- 門の起動回数は、保存先のカウンタと、そのIssueのPRのcommitに付いた起動のstatusの数の大きい方で数える。statusは消せない。
- Appleのキーは `control` だけに渡す。

## 保存・復元・削除

1回の保存の部品(セッション、dirty diff、未追跡ファイル、未push commit bundle、項目、検証記録、依頼、run情報)を、workerの実行のArtifact `agent-ckpt-{Issue}-{run}-{attempt}-{時刻}-{乱数}` 1つにまとめる。各部品のSHA-256とmanifestを作り、アップロード後だけ保存先の `sessions/{Issue}/workspace.json` を `If-Match`(初回は `If-None-Match`)で更新する。Artifactの保存には、JavaScriptのactionにだけ渡される資格情報が要るので、`actions/github-script` で作業フォルダの権限0600のファイル(`$AGENT_HOME/actions-runtime.json`)に書き出して使う(`artifacts.py`)。

定期保存とfinalizeはロックを共有する。別runnerとの競合ではCASに負けた側がポインタを上書きしない。作業ファイルが保存中に変わった場合、定期保存は前の完全な記録を保持する。Claudeの追記中JSONLは完全な行までを保存する。復元前に、Artifactがmainの `agent.yml` の実行で作られたこと、全部品のhash、remoteを検証し、remoteが変わっていたら上書きせず停止する。保存期間を過ぎたArtifactは、復元できない旨を出して止まる。

最新と1つ前を保持し、それより古いものはworkerの後の `checkpoint-gc` が消す。作られてから10分未満で、ポインタがまだ指していないArtifactは消さない。完了・Issue close・PR close/mergeのときは先にポインタをtombstoneにしてから全部を消し、遅い保存が復活させるのを防ぐ。取りこぼしは1時間ごとの照合で拾い、最後は保存期間14日で消える。

Ready要求には依頼・項目・手元検証の3つのJSONを元のバイト列のまま複写し、チェックポイントのSHA-256と照合する。これにより、定期保存と終了時保存の後に元のArtifactが消えても、門の開始と赤からの修正に必要な記録は失われない。

DerivedData cacheは `agent-derived-v1-{branch SHA256先頭16文字}-...` です。native cacheとは別のprefixを使い、PR close/mergeのLinuxジョブはこのprefixのcacheだけを削除する。

## 設定

外部の設定は要らない。値は `scripts/agent/gate-config.json` に置き、mainのコードとして読む。

| キー | 値 | 用途 |
|---|---|---|
| `backend` | `xcode-cloud` | 門の既定。`github` にすると常に予備で流す |
| `xcodeCloudPrGateWorkflowId` | `FD7B155C-3973-4DA5-A0A1-A6886411C5D3` | PR Gate |
| `xcodeCloudReleaseWorkflowId` | `32273285-7cf2-44cf-8e31-cc0385650439` | Release |
| `appStoreConnectAppId` | `6771995650` | Cloudの実行へのリンク |
| `gateMaxAttempts` | 3 | 1つのIssueで門を起動できる回数 |
| `gateWatchMinutes` | 95 | 制御ジョブが門の結果を待つ最長時間 |
| `checkpointSeconds` | 900 | 定期バックアップの間隔 |
| `checkpointRetentionDays` | 14 | チェックポイントのArtifactの保存期間 |

既存のSecrets(`APP_STORE_CONNECT_PRIVATE_KEY`・`KEY_ID`・`ISSUER_ID`)をそのまま使う。デプロイ済みのWorker・R2の設定は変えない。

## 依頼に応じたXcode Cloudのビルド

`repository_dispatch` の `xcode-cloud`(`client_payload`: `workflow` が `release` か `pr-gate`、`branch`、`issue`)で、制御ジョブがビルドを起動し、終わるまで待って結果をsummaryとIssueに書く。Release(TestFlight内部配信)はmainからだけ起動できる。エージェントは `agentctl cloud-build release` で依頼する。

## Cloudのworkflowの設定

PR Gateは手動開始、Clean OFF、必須TEST actionでscheme `StruisPRGate`。Releaseはscheme `StruisRelease` で全テスト＋内部配布用archive、post-actionで内部TestFlightのstagingグループへ配る。設定の再現には `configure_cloud.py` を使える(既定は差分の表示だけで、ビルドは起動しない)。

```sh
python3 scripts/agent/configure_cloud.py --source-workflow EXISTING_ID
python3 scripts/agent/configure_cloud.py --source-workflow EXISTING_ID --apply
```
