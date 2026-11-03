# 通信と端末内の保存

端末側の学習処理は`strius/Engine`、保存は`strius/Ledger`、実AIの要求は`strius/Runtime/Claude`から追えます。配信本文とサーバーの実装はこのリポジトリに含まれません。

## 通信先と送信の契機

| 通信先 | 契機と送信項目 | ソース |
|---|---|---|
| `https://api-struis.digiloglab.com` | 起動・設定からの配信更新。manifest・prompt・schema・Skill等をGETします。認証必須構成はBearer、認証任意構成は`X-Struis-App-Key`を用います。使用量報告(下の節)もここへ送ります | [ServerConfig](../strius/Networking/ServerConfig.swift)、[ServerAssetSource](../strius/Delivery/AssetCache.swift)、[UsageReporter](../strius/State/UsageReporter.swift) |
| `auth-struis.digiloglab.com` | Struisのアカウントログイン、認証更新・ログアウト。Auth0のWeb認証を使います。公開client IDは秘密値ではありません | [Auth0Config](../strius/Auth/Auth0Config.swift)、[AuthStore](../strius/Auth/AuthStore.swift) |
| `https://api.anthropic.com` | 実AIのすべてのターン。学習者の入力、会話の履歴、配信指示、必要な学習記録、添付画像・資料から読み取った内容、tool結果、要求モデルとeffort等をMessages API(`/v1/messages`)へHTTPSで送り、SSEで受け取ります。端末から直接送り、Struisのサーバーは経由しません。実機はApp Attestで正規のStruisアプリであることを示し(`/v1/oauth/app-attest/challenge`・`/v1/oauth/app-attest/register`・`/v1/oauth/token`)、Anthropicが発行する期限付きのtokenをBearerにします。端末にAPIキーは置きません。利用料はStruisのAnthropicワークスペースに請求されます。Info.plistの`NSPinnedDomains`でこのホストの証明書の発行元を固定しています | [ClaudeTurnRunner](../strius/Runtime/Claude/ClaudeTurnRunner.swift)、[ClaudeUpstream](../strius/Runtime/Claude/ClaudeUpstream.swift)、[AppAttestClient](../strius/Runtime/Claude/AppAttestClient.swift)、[TurnComposer](../strius/Engine/TurnComposer.swift) |
| Apple App Attest | Claudeを初めて使う時、端末の鍵の生成とattestationでAppleのサーバーと通信します(DeviceCheckの仕組み) | [AppAttestClient](../strius/Runtime/Claude/AppAttestClient.swift) |
| iCloud(CloudKit)のプライベートデータベース | 設定の「iCloud 同期」がオン(既定)の時、学習記録とファイルを利用者自身のiCloudへ送り、同じApple IDの端末から取り込みます。下の「iCloud 同期」の節を参照してください。Struisのサーバーは経由しません | [ICloudSync](../strius/Sync/ICloudSync.swift)、[CloudKitSyncTransport](../strius/Sync/CloudKitSyncTransport.swift) |
| App Store(StoreKit) | 料金プランの商品の読み込み、購入、契約状態の受け取り。Appleのサーバーと通信します | [SubscriptionStore](../strius/State/SubscriptionStore.swift) |

設定の「利用規約」「プライバシーポリシー」は`https://struis.digiloglab.com/terms`・`/privacy`を外部のブラウザで開きます。アプリ自身は取得しません。

以前は端末内のCodex(OpenAI)を使い、ChatGPTのログインと`127.0.0.1`の中継を経由していました。この経路は削除し、OpenAI・ChatGPTのホストへは通信しません。

StruisのAPI base URLは`STRUIS_API_BASE_URL`で上書きできます(手元のサーバー`http://127.0.0.1:4040`等)。AnthropicのURLはDEBUGビルドだけ`STRUIS_ANTHROPIC_BASE_URL`で上書きでき、検証用の模擬サーバー(`scripts/e2e/fake_anthropic.py`)に向けます。DEBUGのSimulatorはApp Attestを使えないため、`STRUIS_DEBUG_ANTHROPIC_KEY_FILE`のAPIキーで送ります。端末向けのビルドにはこの経路が入りません。これらの手元のHTTPサーバーのため、Info.plistは`NSAllowsLocalNetworking`を有効にしています。端末の設定と依存を変更したビルドについて、上の既定値だけで通信先が限定されるとは扱えません。プロンプトから実行されるPython等の通信能力を含め、公開ソースが提供するのは実装を追えることです。

端末の単元・会話・答案の主要経路は台帳と`ClaudeTurnRunner`を使用します。チャット、会話の分岐、下調べの子ターン、単元・一枚・採点、タイムライン(出題・採点・見直し・赤ペン・知識グラフ)、オンボーディング(採点・計画)のすべてがこの経路です。モデルが求めたtoolは端末で実行します(`NativeToolRouter`。shell・Python・rgは`StruisExec`拡張、台帳の問い合わせ、資料の読み取り)。[APIEndpoint](../strius/Networking/APIEndpoint.swift)・[APIClient](../strius/Networking/APIClient.swift)には従来のserverメッセージ、画像・PDF upload、Learning Feed、realtime等の経路も残ります。それらの経路を使う場合は本文、添付ファイル、upload情報、学習イベント等がStruisサーバーへ送られます。実際の呼出元は各Feature・Stateから確認できます。Struisアカウント認証の有無は`StruisAuthRequired`で決まり、認証任意構成ではbootstrapの個人アカウント取得も行いません。

## 使用量報告

[UsageReporter](../strius/State/UsageReporter.swift)は既定でオフです。設定の「使用量を送る」がオン、かつStruisアカウント認証が必須の構成で、完了・失敗・中断したターンの許可された統計だけを`POST /v1/device-runtime/usage`へ送ります。

送信対象はtask type、status、requested/resolved/actual modelとeffort、elapsed milliseconds、既知のtoken countersです。allowlist外のキー、本文、コマンド、path、写真、エラー内容はこの報告から除きます。actual model/effortを観測できない場合はnullを保持し、要求値から推定して埋めません。この設定はAIターンそのものの送信を止める設定ではありません。

台帳の`turns.executions`には、実行ごとのトークン数(`turn_tokens`: 入力・キャッシュ読み出し・キャッシュ書き込み・出力)と、公開価格からの概算料金(`estimated_cost_usd`)を記録します。設定の「開発者向け」(TestFlight とプロトタイプだけ)に今月の合計を表示します。概算は請求額そのものではありません。

## iCloud 同期

同じApple IDのiPhoneとiPadで、学習データを利用者自身のiCloud(CloudKitのプライベートデータベース、コンテナ`iCloud.com.digiloglab.strius`)だけを使って同期します。自前のサーバーは置きません。方式は`CKSyncEngine`で、自動同期はオフにして、起動時・前面に戻った時・台帳に書いた直後(送信のあとに取り込み)・前面にいる間は数分おきに同期します。プッシュ通知は使いません。設定の「iCloud 同期」で、オン／オフ、状態(iCloudにサインインしていない、最後に同期した時刻、未送信の件数、保留中の件数)、「iCloud のデータを消して、この端末の内容で上げ直す」を扱います。

同期するもの: `ledger_events`の行(会話・単元・採点・進捗・タイムラインを含む。`codex_account`を除く)と、`Application Support/Struis/`の`captures/`・`attachments/`・`memory/`のファイル(`LedgerArchive.fileRoots`のうち`diagnostics`以外)。同期しないもの: `codex_account`の行、Claudeに送る会話の履歴(`claude_conversations`・`claude_conversation_messages`の表と`conversation-images/`)、`thread-context.json`、App Attestの鍵とtoken、Keychain・UserDefaultsの中身、`learning-feed-v2.sqlite3`。別の端末で会話を続けると履歴が無いため、`recent_thread_history.md`を渡して新しいスレッドで続けます。

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

## 保存先

| 場所 | 内容 | ソース |
|---|---|---|
| アプリ私有`Application Support/Struis/ledger.sqlite` | 会話、単元、例題、演習、採点、進捗、イベントと実行監査。iCloud 同期の保留(`sync_pending`)・送信状態(`sync_files`・`sync_tombstones`)も持ちます | [Ledger](../strius/Ledger/Ledger.swift)、[LedgerSchema](../strius/Ledger/LedgerSchema.swift) |
| 同`ledger.sqlite`の`claude_conversations`・`claude_conversation_messages` | Claudeに送り直す会話の履歴(Messagesの形のまま。署名付きのthinkingも残します)。移行`v6-claude-conversations`で作ります。`ledger_events`の外の表なので、iCloud 同期と台帳の書き出しには入りません。単元を削除すると、その会話の行も消します | [ClaudeConversationStore](../strius/Runtime/Claude/ClaudeConversationStore.swift)、[Ledger](../strius/Ledger/Ledger.swift) |
| 同`conversation-images/<sha256>.<ext>` | 会話の履歴の画像。表にはファイル名だけを残し、送る時に読み戻します | [ClaudeConversationStore](../strius/Runtime/Claude/ClaudeConversationStore.swift) |
| 同`captures/`・`attachments/`・`memory/`・`assets/` | 取り込んだ画像等、添付、canonical学習memory、sha256を照合する配信cache | [StruisPaths](../strius/Ledger/Ledger.swift)、[AssetCache](../strius/Delivery/AssetCache.swift) |
| 同`sync/engine-state.json`・`backups/` | `CKSyncEngine`の状態(変更token)、台帳をiCloudの内容で置き換える前のZIP(1つだけ) | [CloudKitSyncTransport](../strius/Sync/CloudKitSyncTransport.swift)、[LedgerSync](../strius/Sync/LedgerSync.swift) |
| App Group `group.com.digiloglab.struis.runtime`のruntime領域 | Exec workerが使うhome・workspace、ターンへ渡した添付・context・toolファイル、会話ごとの渡し済みの控え`thread-context.json`(この端末だけ)。バックアップ対象外 | [NativeRuntimePaths](../NativeRuntime/Shared/RuntimeProtocol.swift)、[WorkspaceStager](../strius/Runtime/WorkspaceStager.swift)、[ThreadContextStore](../strius/Runtime/ThreadContextStore.swift) |
| Keychain・UserDefaults | Struisアカウント認証、App Attestの鍵のIDとAnthropicのtoken(この端末だけに保存し、鍵そのものはSecure Enclaveから出ません)、オンボーディング回答や設定等 | [AuthStore](../strius/Auth/AuthStore.swift)、[AppAttestClient](../strius/Runtime/Claude/AppAttestClient.swift)、[OnboardingProfile](../strius/Features/Onboarding/OnboardingProfile.swift) |

会話の履歴が無い会話(以前のCodexのスレッド、別の端末の会話、書き出しから戻した台帳)と、直近の要求の入力が244,800トークン以上になった会話は、新しいスレッドで`struis_context/recent_thread_history.md`を渡して続けます(`ClaudeTurn.missingHistoryNote`)。

以前の端末内Codexのデータ(アプリ私有の`Application Support/StruisRuntime/codex`とApp Groupの`codex`。ChatGPTの認証、rollout、state)は、起動時に削除します(`HyotanBoot.removeRetiredCodexData`)。台帳の`codex_thread_id`の列と`codex_account`の表は互換のため名前を変えていません。`codex_account`の行は引き続きiCloudへ送りません。

台帳・写真・canonical memoryはアプリ私有領域にあり、device backupの対象です。旧runtimeのworkspaceは既存データを保全して移します。保存形式・識別子は独立配置前のものを維持しています。Exec workerとのOS sandbox境界とworkspace capabilityは別の仕組みで、任意native code全体の隔離をこの説明だけで保証しません。

## 公開ソースで確認できる範囲

配信名、hash検証、cache、読込先、ターンへ渡す処理、AI要求の組み立て、応答検証、台帳更新は公開コードから追えます。サーバーがその時点で返すprompt・schema・Skillの本文と、サーバー・AIサービス内の保存・運用は非公開の範囲です。このリポジトリは、それら閲覧できない内容まで検証できるとするものではありません。
