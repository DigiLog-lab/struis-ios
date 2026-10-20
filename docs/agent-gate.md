# Issueエージェントの手元検証とReadyの門

方針の定義は [verification-and-delivery-policy.md](verification-and-delivery-policy.md) に従います。土台・エージェント・workflowは同じPRでレビューします。Xcode Cloudの旧パスは修正済みとの報告を前提とし、旧障害の修正をこの変更の成果に数えません。

## 実装の流れ

1. `agent.yml` のmacOS workerで全項目を実装する。人の指示は新規セッション、中断だけ保存したセッションを再開する。
2. `agentctl items` → `item-complete ID --note ...` で各項目の完了を記録する。本文の番号付き／チェックボックス項目と、権限のある人のコメントを対象にする。本文・コメントの全文はrequest snapshotに保持し、項目本文が変われば完了を無効にする。
3. `request-pr` は1つのDraft PRを作成・更新する。WIPのpushでは門を起動しない。
4. 全項目完了後、commit・pushし、`local-verify` を流す。ビルドは1回、全 `striusTests` と、`ui_test_plan.py` の必須E2E＋差分UIを `test-without-building` で実行する。手元ではカメラの除外を適用しない。
5. `xcresulttool get test-results tests --format json` で実行名・結果・時間を取得する。空の結果、失敗、期待失敗、実行中のHEAD変更は成功にしない。既存の外部入力不足によるskipは実行記録に残す。記録・依頼・項目を完全なチェックポイントとして発行する。
6. `ready` は全項目完了・remoteと同じHEAD・そのSHAと依頼に対応する手元検証成功を確認し、PR本文へ実行一覧・結果・時間を記載する。Draftを外して `agent-gate.yml` をmainからdispatchし、macOS workerを終了する。人がGitHubでDraftを外す場合も、最新チェックポイントを同じスクリプトで検証する。
7. Linuxの門コントローラーがXcode Cloudを起動する。残り時間不足時はmainの `ios.yml` へ対象の厳密なSHAを渡す。両方ともLinuxの `agent-tests.yml` を明示的に実行する。PRイベント抑止に依存しない。
8. `check_run.completed`／`workflow_run.completed` と5分ごとの定期照合で結果を取得する。門が緑なら同じIssueのrouteを起こして完了を記録する（追加のmacOSは使わない）。赤ならDraftへ戻し、失敗したHEAD・元の依頼・結果だけを渡してmacOS workerを起こす。修正後も全体の手元検証をやり直す。

Ready後のHEAD変更・Draft化・closeで古い結果を無効にします。Xcode Cloud APIは開始時にcommit SHAを指定できず、ブランチ参照を指定します。そのため開始前後と完了時に `sourceCommit.commitSha` を照合し、異なるSHAを合格にしません。別workflowの結果も採用しません。
Cloudの完了判定は全体のstatusだけでなく、実際のTEST actionとテスト結果一覧も照合します。手元の全単体・選択UIから除外manifest分だけを引いたメソッドが欠けている場合、0件の場合、期待失敗がある場合は合格にしません。失敗したテストとビルドissueを修正workerへ渡し、Appleのキーは渡しません。

門の開始POSTが途中で失敗した場合は、自動で同じビルドを起動し直しません。Draftへ戻して開始エラーをIssueへ記録します。テストの赤からの修正と、API／設定エラーを区別します。門の結果待ちは中断の連続3回の自動再開を消費しません。

## 保存・復元・削除

`sessions/{Issue}/checkpoints/{run}-{attempt}-{時刻}-{乱数}/` に、セッション、dirty diff、未追跡ファイル、未push commit bundle、項目、検証記録、依頼、run情報を保存します。無変更・push済みのときもセッションと記録を保存します。各部品のSHA-256とmanifestを作り、全アップロード後だけ `workspace.json` を `If-Match`（初回は `If-None-Match`）で更新します。

定期保存とfinalizeはロックを共有します。別runnerとの競合ではCASに負けた側がポインタを上書きしません。作業ファイルが保存中に変わった場合、定期保存は前の完全な記録を保持します。Claudeの追記中JSONLは完全な行までを保存します。復元前に全componentのhashとremoteを検証し、remoteが変わっていたら上書きせず停止します。

最新と1つ前を保持し、それより古いcheckpointを削除します。新しい保存の途中のオブジェクトを消さないよう、削除には公開済みポインタと時刻の条件を付けます。完了・closeのときは先にポインタをtombstoneにしてから削除し、遅い保存が復活させるのを防ぎます。

Workerの永続オブジェクト削除APIは `DELETE /v1/checkpoints/{Issue}` だけです。`sessions/{Issue}/checkpoints/` 以外のキーは指定できません。`gates/` はmainの `agent-gate.yml` だけが書けます。workerは読めますが結果を書き換えられません。multipart経由の書き込みも同じ制限です。

DerivedData cacheは `agent-derived-v1-{branch SHA256先頭16文字}-...` です。native cacheとは別のprefixを使い、PR close/mergeのLinuxジョブはこのprefixのcacheだけを削除します。定期照合で失われたcloseイベントも補います。

## 運用に必要な設定

このPRはコードを追加します。下表の外部設定・Workerのデプロイ・実環境の検証は、コミットしただけでは適用されません。

| 設定 | 用途・値 |
|---|---|
| `AGENT_GATE_MAX_ATTEMPTS` | **未決**。門1回の実測後に正の整数を設定する。未設定ならReadyを拒否する。Issue単位の累計を保ち、PRを作り直しても回避しない |
| `XCODE_CLOUD_PR_GATE_WORKFLOW_ID` | 修正済みCloud workflowをPR Gateとして設定したID |
| `APP_STORE_CONNECT_APP_ID` | Cloud実行のリンクに使うアプリID |
| `APP_STORE_CONNECT_PRIVATE_KEY` / `KEY_ID` / `ISSUER_ID` | 既存Secrets。AppleキーはLinuxコントローラーだけに渡す。macOSエージェントには渡さない |
| `AGENT_GATE_BACKEND` | 既定 `xcode-cloud`。予備を明示的に使う場合は `github` |
| `XCODE_CLOUD_REMAINING_MINUTES` / `AGENT_GATE_ESTIMATED_MINUTES` | 両方設定した場合、残りが見積もり未満ならGitHubへ切り替える。残り時間の自動取得方法は未決。未設定時に残り時間を推測しない |
| `AGENT_CHECKPOINT_SECONDS` | 既定900秒（仮） |
| `AGENT_CHECKPOINT_RETENTION_DAYS` | 既定14日（仮） |
| `AGENT_R2_LIFECYCLE_ENABLED` | lifecycle自動照合を有効にする時だけ `true` |
| `CLOUDFLARE_ACCOUNT_ID` / `AGENT_R2_LIFECYCLE_API_TOKEN` | lifecycleの更新権限を持つアカウント変数／専用Secret。cleanupのLinuxジョブだけに渡す |

Workerは既存のデプロイ手順で更新します。新しいallowed workflowとgate書き込み制限を先に適用してください。
マージ条件に使うcommit statusの名前は `Struis / Ready gate` です。既存のrequired checksが旧iOS workflowを要求している場合は、新しい門の運用を確認したうえでリポジトリ設定を合わせます。

Cloudの設定は、既存の動くworkflowのID・Xcode/macOS版・Simulator destinationを流用できます。

```sh
python3 scripts/agent/configure_cloud.py --source-workflow EXISTING_ID
# 内容を確認したうえで適用する。ビルドは起動しない。
python3 scripts/agent/configure_cloud.py --source-workflow EXISTING_ID --apply
```

PR Gateは手動開始、Clean OFF、必須TEST actionでscheme `StruisPRGate` を使用します。Releaseはscheme `StruisRelease` で全テスト＋内部配布用archiveを実行します。内部TestFlight groupへの配信post-actionはCloudの画面で設定します。コードカバレッジと録画の設定は [xcode-cloud.md](xcode-cloud.md) のとおりです。

R2のlifecycleはglobでなくprefixの一致なので、`sessions/` 全体を期限削除するとstateやpointerまで消えます。`lifecycle.py` はチェックポイントのあるIssueごとの正確なprefixにルールを作り、他のルールを保持します。使われなくなった管理対象ルールは次の照合で整理します。

```sh
python3 scripts/agent/lifecycle.py         # 現在との差分を確認
python3 scripts/agent/lifecycle.py --apply # 正確なIssue prefixだけに14日を適用
```

## 旧workflowを止める条件

以下は実測してから `true` にします。このPRでは有効にしたと見なしません。

| Repository variable | 確認後に止まるもの |
|---|---|
| `XCODE_CLOUD_RELEASE_TESTS_VERIFIED` | 夜間の全UI |
| `XCODE_CLOUD_TESTFLIGHT_VERIFIED` | main push時の旧検証・署名archive。番号はCloudの `CI_BUILD_NUMBER` へ一本化 |
| `XCODE_CLOUD_CLEAN_BUILD_VERIFIED` | 定期cold build（手動の復旧経路は残す） |

Cloudの2回実行によるキャッシュ効果、全UI、内部TestFlight、clean build、実macOSでのlocal-verify、Worker/R2への実保存・削除と自動再開は、別途実環境で確認する必要があります。この開発環境にはXcodeがありません。Python・Workerの回帰テスト、Actionsの式／構文、plan・scheme・projectの整合性をコード側の検証とします。
