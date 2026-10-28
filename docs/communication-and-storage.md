# 通信と端末内の保存

端末側の学習処理は`strius/Engine`、保存は`strius/Ledger`、実AIの要求は`strius/Runtime`から追えます。配信本文とサーバーの実装はこのリポジトリに含まれません。

## 通信先と送信の契機

| 通信先 | 契機と送信項目 | ソース |
|---|---|---|
| `https://api-struis.digiloglab.com` | 起動・設定からの配信更新。manifest・prompt・schema・Skill等をGETします。認証必須構成はBearer、認証任意構成は`X-Struis-App-Key`を用います | [ServerConfig](../strius/Networking/ServerConfig.swift)、[ServerAssetSource](../strius/Delivery/AssetCache.swift) |
| `auth-struis.digiloglab.com` | Struisのアカウントログイン、認証更新・ログアウト。Auth0のWeb認証を使います。公開client IDは秘密値ではありません | [Auth0Config](../strius/Auth/Auth0Config.swift)、[AuthStore](../strius/Auth/AuthStore.swift) |
| `https://auth.openai.com` | ChatGPTアカウントのログイン・認証token更新。アプリが呼ぶCodex account RPCから固定した上流login実装へ進みます | [DeviceRuntime](../strius/Runtime/DeviceRuntime.swift)、[固定上流login](https://github.com/openai/codex/blob/3d2ee51ca2d5db578f328aa75e20aa22c0197c9a/codex-rs/login/src/server.rs) |
| `https://chatgpt.com/backend-api/codex` | ChatGPT認証を用いる実AIターン。学習者の入力、会話の文脈、配信指示、必要な学習記録、添付画像・資料から読み取った内容、tool結果、要求モデルとeffort等がAIへ送られます | [CodexTurnRunner](../strius/Runtime/CodexTurnRunner.swift)、[TurnComposer](../strius/Engine/TurnComposer.swift)、[固定上流provider](https://github.com/openai/codex/blob/3d2ee51ca2d5db578f328aa75e20aa22c0197c9a/codex-rs/model-provider-info/src/lib.rs) |
| `https://api.openai.com/v1` | 固定Codex上流のAPI-key認証側の既定通信先です。実際の認証・provider設定によって選択されます | [固定上流provider](https://github.com/openai/codex/blob/3d2ee51ca2d5db578f328aa75e20aa22c0197c9a/codex-rs/model-provider-info/src/lib.rs) |
| `https://api.anthropic.com` | 設定の「AIモデル」でClaudeを選んだ時の実AIターン。送る内容はChatGPTの行と同じです。端末から直接送り、Struisのサーバーは経由しません。App Attestで正規のStruisアプリであることを示し(`/v1/oauth/app-attest/*`、`/v1/oauth/token`)、Anthropicが発行する1時間有効のtokenで `/v1/messages` を呼びます。端末にAPIキーは置きません。利用料はStruisのAnthropicワークスペースに請求されます | [AppAttestClient](../strius/Runtime/ClaudeProxy/AppAttestClient.swift)、[ClaudeResponsesProxy](../strius/Runtime/ClaudeProxy/ClaudeResponsesProxy.swift) |
| Apple App Attest | Claudeを初めて使う時、端末の鍵の生成とattestationでAppleのサーバーと通信します(DeviceCheckの仕組み) | [AppAttestClient](../strius/Runtime/ClaudeProxy/AppAttestClient.swift) |
| `127.0.0.1`のHTTP(Claude用) | Native CodexはResponses APIしか話さないため、Claudeのスレッドではアプリ内のプロキシをCodexのproviderにします。起動ごとのランダムなBearer tokenを持つ要求だけを受け、Messages APIに変換して上の行へ送ります | [ClaudeResponsesProxy](../strius/Runtime/ClaudeProxy/ClaudeResponsesProxy.swift)、[CodexTurnRunner](../strius/Runtime/CodexTurnRunner.swift) |
| iCloud(CloudKit)のプライベートデータベース | 設定の「iCloud 同期」がオン(既定)の時、学習記録とファイルを利用者自身のiCloudへ送り、同じApple IDの端末から取り込みます。下の「iCloud 同期」の節を参照してください。Struisのサーバーは経由しません | [ICloudSync](../strius/Sync/ICloudSync.swift)、[CloudKitSyncTransport](../strius/Sync/CloudKitSyncTransport.swift) |
| `127.0.0.1`のWebSocket | アプリ内のNative CodexとのJSON-RPC。ランダムなtransport tokenで認証し、端末内部で要求・通知を搬送します | [NativeRuntimeHost](../strius/Runtime/NativeRuntimeHost.swift)、[NativeCodex](../NativeRuntime/NativeCodex/src/lib.rs) |

StruisのAPI base URLは`STRUIS_API_BASE_URL`で上書きできます。Codexの固定上流はprovider base URLや環境による設定も持ちます。端末の設定と依存を変更したビルドについて、上の既定値だけで通信先が限定されるとは扱えません。プロンプトから実行されるPython等の通信能力を含め、公開ソースが提供するのは実装を追えることです。

端末の単元・会話・答案の主要経路は台帳とNative Codexを使用します。[APIEndpoint](../strius/Networking/APIEndpoint.swift)・[APIClient](../strius/Networking/APIClient.swift)には従来のserverメッセージ、画像・PDF upload、Learning Feed、realtime等の経路も残ります。それらの経路を使う場合は本文、添付ファイル、upload情報、学習イベント等がStruisサーバーへ送られます。実際の呼出元は各Feature・Stateから確認できます。Struisアカウント認証の有無は`StruisAuthRequired`で決まり、認証任意構成ではbootstrapの個人アカウント取得も行いません。

## 使用量報告

[UsageReporter](../strius/State/UsageReporter.swift)は既定でオフです。設定の「使用量を送る」がオン、かつStruisアカウント認証が必須の構成で、完了・失敗・中断したターンの許可された統計だけを`POST /v1/device-runtime/usage`へ送ります。

送信対象はtask type、status、requested/resolved/actual modelとeffort、elapsed milliseconds、既知のtoken countersです。allowlist外のキー、本文、コマンド、path、写真、エラー内容はこの報告から除きます。actual model/effortを観測できない場合はnullを保持し、要求値から推定して埋めません。この設定はAIターンそのものの送信を止める設定ではありません。固定Native Codexは`analytics.enabled=false`も指定します。

台帳の`turns.executions`には、実行ごとのトークン数(`turn_tokens`: 入力・キャッシュ読み出し・キャッシュ書き込み・出力)と、Claudeのモデルでは公開価格からの概算料金(`estimated_cost_usd`)を記録します。設定の「詳細設定」に今月の合計を表示します。概算は請求額そのものではありません。

## iCloud 同期

同じApple IDのiPhoneとiPadで、学習データを利用者自身のiCloud(CloudKitのプライベートデータベース、コンテナ`iCloud.com.digiloglab.strius`)だけを使って同期します。自前のサーバーは置きません。方式は`CKSyncEngine`で、自動同期はオフにして、起動時・前面に戻った時・台帳に書いた直後(送信のあとに取り込み)・前面にいる間は数分おきに同期します。プッシュ通知は使いません。設定の「iCloud 同期」で、オン／オフ、状態(iCloudにサインインしていない、最後に同期した時刻、未送信の件数、保留中の件数)、「iCloud のデータを消して、この端末の内容で上げ直す」を扱います。

同期するもの: `ledger_events`の行(会話・単元・採点・進捗・タイムラインを含む。`codex_account`を除く)と、`Application Support/Struis/`の`captures/`・`attachments/`・`memory/`のファイル(`LedgerArchive.fileRoots`のうち`diagnostics`以外)。同期しないもの: `codex_account`の行、Codexのrollout・Codex home、`thread-context.json`、App Attestの鍵とtoken、Keychain・UserDefaultsの中身、`learning-feed-v2.sqlite3`。別の端末で会話を続けるとrolloutが無いため、`recent_thread_history.md`を渡して新しいCodexスレッドで続けます。

レコードの中身はすべて`encryptedValues`(ファイルは`CKAsset`)に入れ、利用者のiCloudキーチェーンの鍵でCloudKitが暗号化します。平文のフィールドは置かず、開発者は中身を読めません。

### CloudKit のレコード

ゾーン：`Ledger`(プライベートデータベース)

| レコード型 | recordName | フィールド(すべて暗号化) |
|---|---|---|
| `LedgerEvent` | `<origin_device_id>.<origin_seq>` | `entity`(String), `entityID`(String), `kind`(String), `payload`(Bytes), `createdAt`(String), `originDevice`(String), `originSeq`(Int64), `payloadAsset`(Asset。`payload` が 900KB を超える時だけ使い、`payload` は空) |
| `LedgerFile` | パスの SHA-256(16進) | `path`(String。`captures/…` のような相対パス), `sha256`(String), `modifiedAt`(String), `file`(Asset) |

索引は張らない(`CKSyncEngine` のゾーン変更の取得だけで、検索はしない)。

### 台帳への取り込み

- 取ってきた変更は、台帳とファイルに入れ終えてから`CKSyncEngine`の状態(変更token)を`sync/engine-state.json`に保存します。取り込む前にアプリが終わった時や取り込みに失敗した時は、保存してある状態から同じ変更を取り直します。
- 外から来たイベントは`Ledger.append`を通さず、元の端末のIDと連番(`origin_device_id`, `origin_seq`。一意制約あり)を保ったまま足し、`LedgerEvent.apply`で射影に反映します。同じイベントが2回届いても結果は変わりません。自端末のイベントは`origin_device_id = device_id`、`origin_seq = seq`です(移行`sync-v1`)。`synced_seq`はCloudKitへ送り終えた印です。
- 同じ行(`entity`, `entity_id`)を2台で変えた時は、`created_at`の新しいイベントが勝ちます。同じなら`origin_device_id`の大きい方です。古いイベントは`ledger_events`に残し、射影には反映しません。自端末で書くイベントは、その行の既存のどのイベントよりも後の`created_at`にします。`memory/`等のファイルもファイル単位で`modifiedAt`の新しい方が勝ちます。他の端末がファイルを消しても、この端末で前回送った後に直したファイル(大きさ・更新時刻・SHA-256が`sync_files`の記録と違う)は消さずに送り直します。
- 知らない`entity`、復号・デコードに失敗したイベントは`sync_pending`に保留してログに残し、アプリの版が変わった時に適用し直します。
- 単元の削除は、削除した端末で物理削除したイベントとファイルのレコードをCloudKitからも消し、`unit.deleted`の事実を同期します。届いた端末でも`UnitDeletion`と同じ処理で範囲のイベントとファイルを消します。届いた端末だけが知っていた行(送る前のカードや答案など)も範囲に足して消し、足したIDは`ledger_meta`(`unit_deletion_scope.<operation_id>`)に残します。届いた`unit.deleted`の事実はそのまま保存し、送り返しません。削除のあとに届いた古いイベントは、事実の範囲と足したIDのどちらに当たっても落とします。
- 「上げ直す」はゾーン`Ledger`を消して作り直し、その端末の台帳とファイルを全部上げ直します。ほかの端末はゾーンが消されたことを検知すると、確認なしで台帳をクラウドの内容で置き換えます。置き換える前の台帳は`Application Support/Struis/backups/`にZIP(書き出しと同じ形式)で1つだけ残します。
- iCloudキーチェーンのリセット(`encryptedDataReset`、または`zoneNotFound`に`CKErrorUserDidResetEncryptedDataKey`)ではゾーンを作り直して手元の台帳を上げ直します。利用者が「設定」からデータを消した場合(`purged`)は手元を消さず、同期をオフにして状態に出します。もう一度オンにすると手元を上げ直します。
- 初回は、クラウドが空なら手元を全部上げ、手元が空ならクラウドを全部取り込み、両方にあれば上のルールで合わせます。

## 固定Codex上流の診断経路

固定上流は`https://ab.chatgpt.com/otlp/v1/metrics`のmetrics exporterと、`o33249.ingest.us.sentry.io`へのfeedback upload実装も持ちます。StruisのNativeCodexは`analytics.enabled=false`とanalytics既定オフを指定し、上流`core/src/otel_init.rs`はmetrics exporterを無効にします。log・trace exporterの既定値もNoneです。ユーザーがCodex設定へ明示的なOTLP exporterを追加した場合、その送信は別に有効になり得ます。

feedbackの生成は診断ring bufferの保持で、uploadは上流のfeedback request processorから実行されます。Struisの公開Swiftコードにはfeedback upload RPCの呼出しを含みません。上流の該当実装は[OTel設定](https://github.com/openai/codex/blob/3d2ee51ca2d5db578f328aa75e20aa22c0197c9a/codex-rs/core/src/otel_init.rs)、[feedback processor](https://github.com/openai/codex/blob/3d2ee51ca2d5db578f328aa75e20aa22c0197c9a/codex-rs/app-server/src/request_processors/feedback_processor.rs)から確認できます。ライブラリが存在することと、現在のアプリ経路で送信したことは区別します。

## 保存先

| 場所 | 内容 | ソース |
|---|---|---|
| アプリ私有`Application Support/Struis/ledger.sqlite` | 会話、単元、例題、演習、採点、進捗、イベントと実行監査。iCloud 同期の保留(`sync_pending`)・送信状態(`sync_files`・`sync_tombstones`)も持ちます | [Ledger](../strius/Ledger/Ledger.swift)、[LedgerSchema](../strius/Ledger/LedgerSchema.swift) |
| 同`captures/`・`memory/`・`assets/` | 取り込んだ画像等、canonical学習memory、sha256を照合する配信cache |
| 同`sync/engine-state.json`・`backups/` | `CKSyncEngine`の状態(変更token)、台帳をiCloudの内容で置き換える前のZIP(1つだけ) | [CloudKitSyncTransport](../strius/Sync/CloudKitSyncTransport.swift)、[LedgerSync](../strius/Sync/LedgerSync.swift) | [StruisPaths](../strius/Ledger/Ledger.swift)、[AssetCache](../strius/Delivery/AssetCache.swift) |
| アプリ私有`Application Support/StruisRuntime/codex` | Codex auth、transport token、rollout、state等。認証ファイルは0600、ディレクトリは0700で、runtime領域はバックアップ対象外 | [HyotanBoot](../strius/Runtime/HyotanBoot.swift) |
| App Group `group.com.digiloglab.struis.runtime`のruntime領域 | Exec workerが使うhome・workspace、ターンへ渡した添付・context・toolファイル | [NativeRuntimePaths](../NativeRuntime/Shared/RuntimeProtocol.swift)、[WorkspaceStager](../strius/Runtime/CodexTurnRunner.swift) |
| Keychain・UserDefaults | Struisアカウント認証、App Attestの鍵のIDとAnthropicのtoken(Claudeを使う場合。この端末だけに保存し、鍵そのものはSecure Enclaveから出ません)、オンボーディング回答や設定(使うAIモデルを含む)等。Codex authは上記私有homeのファイルです | [AuthStore](../strius/Auth/AuthStore.swift)、[OnboardingProfile](../strius/Features/Onboarding/OnboardingProfile.swift) |

台帳・写真・canonical memoryはアプリ私有領域にあり、device backupの対象です。旧runtimeからの移行は既存データを保全して行い、旧App Groupの認証は私有homeへの移行後に除去します。保存形式・識別子は独立配置前のものを維持しています。Exec workerとのOS sandbox境界とworkspace capabilityは別の仕組みで、任意native code全体の隔離をこの説明だけで保証しません。

## 公開ソースで確認できる範囲

配信名、hash検証、cache、読込先、ターンへ渡す処理、AI要求の組み立て、応答検証、台帳更新は公開コードから追えます。サーバーがその時点で返すprompt・schema・Skillの本文と、サーバー・AIサービス内の保存・運用は非公開の範囲です。このリポジトリは、それら閲覧できない内容まで検証できるとするものではありません。
