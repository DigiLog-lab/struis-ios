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
| `https://api.anthropic.com/v1/messages` | 設定の「AIモデル」でClaudeを選んだ時の実AIターン。送る内容はChatGPTの行と同じで、学習者が入れたAnthropicのAPIキーで直接送ります。Struisのサーバーは経由しません | [ClaudeResponsesProxy](../strius/Runtime/ClaudeProxy/ClaudeResponsesProxy.swift)、[ClaudeRequestTranslator](../strius/Runtime/ClaudeProxy/ClaudeRequestTranslator.swift) |
| `127.0.0.1`のHTTP(Claude用) | Native CodexはResponses APIしか話さないため、Claudeのスレッドではアプリ内のプロキシをCodexのproviderにします。起動ごとのランダムなBearer tokenを持つ要求だけを受け、Messages APIに変換して上の行へ送ります | [ClaudeResponsesProxy](../strius/Runtime/ClaudeProxy/ClaudeResponsesProxy.swift)、[CodexTurnRunner](../strius/Runtime/CodexTurnRunner.swift) |
| `127.0.0.1`のWebSocket | アプリ内のNative CodexとのJSON-RPC。ランダムなtransport tokenで認証し、端末内部で要求・通知を搬送します | [NativeRuntimeHost](../strius/Runtime/NativeRuntimeHost.swift)、[NativeCodex](../NativeRuntime/NativeCodex/src/lib.rs) |

StruisのAPI base URLは`STRUIS_API_BASE_URL`で上書きできます。Codexの固定上流はprovider base URLや環境による設定も持ちます。端末の設定と依存を変更したビルドについて、上の既定値だけで通信先が限定されるとは扱えません。プロンプトから実行されるPython等の通信能力を含め、公開ソースが提供するのは実装を追えることです。

端末の単元・会話・答案の主要経路は台帳とNative Codexを使用します。[APIEndpoint](../strius/Networking/APIEndpoint.swift)・[APIClient](../strius/Networking/APIClient.swift)には従来のserverメッセージ、画像・PDF upload、Learning Feed、realtime等の経路も残ります。それらの経路を使う場合は本文、添付ファイル、upload情報、学習イベント等がStruisサーバーへ送られます。実際の呼出元は各Feature・Stateから確認できます。Struisアカウント認証の有無は`StruisAuthRequired`で決まり、認証任意構成ではbootstrapの個人アカウント取得も行いません。

## 使用量報告

[UsageReporter](../strius/State/UsageReporter.swift)は既定でオフです。設定の「使用量を送る」がオン、かつStruisアカウント認証が必須の構成で、完了・失敗・中断したターンの許可された統計だけを`POST /v1/device-runtime/usage`へ送ります。

送信対象はtask type、status、requested/resolved/actual modelとeffort、elapsed milliseconds、既知のtoken countersです。allowlist外のキー、本文、コマンド、path、写真、エラー内容はこの報告から除きます。actual model/effortを観測できない場合はnullを保持し、要求値から推定して埋めません。この設定はAIターンそのものの送信を止める設定ではありません。固定Native Codexは`analytics.enabled=false`も指定します。

## 固定Codex上流の診断経路

固定上流は`https://ab.chatgpt.com/otlp/v1/metrics`のmetrics exporterと、`o33249.ingest.us.sentry.io`へのfeedback upload実装も持ちます。StruisのNativeCodexは`analytics.enabled=false`とanalytics既定オフを指定し、上流`core/src/otel_init.rs`はmetrics exporterを無効にします。log・trace exporterの既定値もNoneです。ユーザーがCodex設定へ明示的なOTLP exporterを追加した場合、その送信は別に有効になり得ます。

feedbackの生成は診断ring bufferの保持で、uploadは上流のfeedback request processorから実行されます。Struisの公開Swiftコードにはfeedback upload RPCの呼出しを含みません。上流の該当実装は[OTel設定](https://github.com/openai/codex/blob/3d2ee51ca2d5db578f328aa75e20aa22c0197c9a/codex-rs/core/src/otel_init.rs)、[feedback processor](https://github.com/openai/codex/blob/3d2ee51ca2d5db578f328aa75e20aa22c0197c9a/codex-rs/app-server/src/request_processors/feedback_processor.rs)から確認できます。ライブラリが存在することと、現在のアプリ経路で送信したことは区別します。

## 保存先

| 場所 | 内容 | ソース |
|---|---|---|
| アプリ私有`Application Support/Struis/ledger.sqlite` | 会話、単元、例題、演習、採点、進捗、イベントと実行監査 | [Ledger](../strius/Ledger/Ledger.swift)、[LedgerSchema](../strius/Ledger/LedgerSchema.swift) |
| 同`captures/`・`memory/`・`assets/` | 取り込んだ画像等、canonical学習memory、sha256を照合する配信cache | [StruisPaths](../strius/Ledger/Ledger.swift)、[AssetCache](../strius/Delivery/AssetCache.swift) |
| アプリ私有`Application Support/StruisRuntime/codex` | Codex auth、transport token、rollout、state等。認証ファイルは0600、ディレクトリは0700で、runtime領域はバックアップ対象外 | [HyotanBoot](../strius/Runtime/HyotanBoot.swift) |
| App Group `group.com.digiloglab.struis.runtime`のruntime領域 | Exec workerが使うhome・workspace、ターンへ渡した添付・context・toolファイル | [NativeRuntimePaths](../NativeRuntime/Shared/RuntimeProtocol.swift)、[WorkspaceStager](../strius/Runtime/CodexTurnRunner.swift) |
| Keychain・UserDefaults | Struisアカウント認証、AnthropicのAPIキー(Claudeを使う場合)、オンボーディング回答や設定(使うAIモデルを含む)等。Codex authは上記私有homeのファイルです。APIキーはCodexの設定・スレッド・台帳には書きません | [AuthStore](../strius/Auth/AuthStore.swift)、[OnboardingProfile](../strius/Features/Onboarding/OnboardingProfile.swift) |

台帳・写真・canonical memoryはアプリ私有領域にあり、device backupの対象です。旧runtimeからの移行は既存データを保全して行い、旧App Groupの認証は私有homeへの移行後に除去します。保存形式・識別子は独立配置前のものを維持しています。Exec workerとのOS sandbox境界とworkspace capabilityは別の仕組みで、任意native code全体の隔離をこの説明だけで保証しません。

## 公開ソースで確認できる範囲

配信名、hash検証、cache、読込先、ターンへ渡す処理、AI要求の組み立て、応答検証、台帳更新は公開コードから追えます。サーバーがその時点で返すprompt・schema・Skillの本文と、サーバー・AIサービス内の保存・運用は非公開の範囲です。このリポジトリは、それら閲覧できない内容まで検証できるとするものではありません。
