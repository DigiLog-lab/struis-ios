# 統合部分のレビュー形式(App Attest / Anthropic Messages API / Codex app-server)

引き継ぎ(`docs/handoff-2026-10-17.md` 2.2・5.4)の結論: 今週の実機障害 3 件(Console に Bundle ID 未登録、19 万トークン、入れ直し後の古い鍵)は UI テストでは原理的に捕まらない。原因は「各統合が取り得る状態を誰も列挙していなかった」こと。この文書は、統合ごとに **公式文書が挙げる状態を全部並べ、横にこの repo の対応箇所を書く** 形式を固定する。空欄(未対応)がそのまま課題になる。

## 使い方

1. 回すタイミング: (a) 下の「対象ファイル」のどれかを変える prototype ビルドの前。(b) `NativeRuntime/Scripts/build-codex.py` の Codex pin(いま `rust-v0.153.4`)を上げた後。(c) SwiftMath など描画側の変更では回さない(この文書の対象外)。
2. 1 行 = 公式文書が名前を付けている状態・エラー・条件 1 つ。行を増やすときは必ず「出どころ」に文書の節名か URL、または Codex のソースのパスを書く。推測で行を作らない。
3. 「この repo の対応箇所」は `ファイル:シンボル` で書く(例 `AppAttestClient.swift: DeviceAttestation.generateAssertion`)。grep で実在を確かめてから書く。何も扱っていなければ **未対応** と書く。部分的なら「部分: 何が足りないか」。
4. 「確認の仕方」は 単体テスト(テスト名)/ 実機 / 模擬サーバー(`StubAnthropic`・`StubAnthropicAuth`・`STRUIS_ANTHROPIC_BASE_URL`)のどれか。実機でしか起きない状態は実機と書き、prototype の受け入れ台本に入れる。
5. 対応箇所が「未対応」の行、または確認の仕方が空の行は、そのまま Issue にする。Issue の題名はその行の「公式文書が挙げる状態」の文字列。本文に出どころと対応箇所の列を写す。
6. pin を上げたときは、表 3 の「出どころ」のソースパスを新しい tag で開き直し、行の有無(enum の増減、既定値の変更)を確かめてから対応箇所を見直す。
7. 対象ファイル: `strius/Runtime/ClaudeProxy/*.swift`、`strius/Runtime/NativeToolRouter.swift`、`strius/Runtime/CodexTurnRunner.swift`(`applyProvider`)、`strius/Runtime/ModelProvider.swift`、`NativeRuntime/NativeCodex/src/lib.rs`、`NativeRuntime/Scripts/build-codex.py`。
8. 表の行は消さない。対応が入ったら対応箇所の列を書き換え、確認の仕方にテスト名を足す。
9. レビューはエージェントでも人でもよい。エージェントに渡すときはこの文書と上の対象ファイルだけを文脈に与え、「表の各行について対応箇所を grep で確かめ、違っていたら直せ」と指示する。
10. 出どころの確認日: Apple 文書・Anthropic 文書は 2026-10-17 に取得。Codex は tag `rust-v0.153.4` のソース(`docs/config.md` は同 tag では hooks の節しかないので、ソースを出どころにする)。

## 表 1: Apple App Attest(DeviceCheck)

コード: `strius/Runtime/ClaudeProxy/AppAttestClient.swift`、テスト: `striusTests/Runtime/ClaudeAppAttestTests.swift`。Apple の文書は `DCError.Code`(https://developer.apple.com/documentation/devicecheck/dcerror-swift.struct/code)と「Establishing your app's integrity」(https://developer.apple.com/documentation/devicecheck/establishing-your-app-s-integrity)。

| 公式文書が挙げる状態 | 出どころ(文書の節/URL) | この repo の対応箇所 | 確認の仕方(単体テスト / 実機 / 模擬サーバー) |
|---|---|---|---|
| `isSupported == false`(端末が App Attest 非対応。Simulator はここに入る) | Establishing…「Check for availability」 | `AppAttestClient.swift: register` → `Failure.unsupported`。経路の選択は `ClaudeResponsesProxy.swift: ClaudeUpstream.init(session:)`(nil → `ClaudeRelay.run` が 401 `claude_unavailable`)、`ModelProvider.swift: ClaudeAccess.isAvailable`、`ModelProviderError.claudeUnavailable`(設定画面の文言) | 単体: 未対応(`Attestation.isSupported=false` のテストが無い)。Simulator で DEBUG の API キーを外して起動すると実際に通る経路 |
| `DCError.unknownSystemFailure`(token を作れない等の一般の失敗) | DCError.Code | 部分: `generateKey`/`attestKey` で出た場合は `DeviceAttestation` が写さず NSError のまま `ClaudeRelay.run` の `catch` に届き、`domain == "com.apple.devicecheck.error"` で 400 `app_attest` を返す。`generateAssertion` で出た場合は `DeviceAttestation.generateAssertion` が `Failure.keyUnusable` にして鍵を作り直す(Apple の指針「serverUnavailable 以外は鍵を捨てる」に合わせた) | 単体: 未対応(unknownSystemFailure を注入するテストが無い)。実機 |
| `DCError.featureUnsupported`(DeviceCheck がこの端末で使えない) | DCError.Code | 上の `isSupported` と同じ。`DeviceAttestation` の 3 メソッドからは NSError のまま → `ClaudeRelay.run` 400 `app_attest` | 単体: 未対応 |
| `DCError.invalidInput`(渡したデータの形式が不正。実機では入れ直し後の assertion で Code=2 として出た) | DCError.Code。引き継ぎ 2.2・6 | `AppAttestClient.swift: DeviceAttestation.generateAssertion`(`error.code != .serverUnavailable` → `Failure.keyUnusable`)→ `refresh` の `catch Failure.keyUnusable` → `ensureKey(replacing:)` で Keychain の ID と token を消して `register` | 単体: `testReinstalledDeviceRegistersANewKeyWhenTheStoredKeyIsUnusable`。実機: 同じ variant を削除→再インストール→最初のターン |
| `DCError.invalidKey`(App Attest の鍵を使えない) | DCError.Code | 同上(`generateAssertion` の catch は `serverUnavailable` 以外を全部 `keyUnusable` にする) | 単体: 同上(テストは `keyUnusable` を投げる stub で代用。DCError の code 別には分けていない) |
| `DCError.serverUnavailable`(attestation 中に Apple のサーバーへ届かない。**同じ鍵で後で再試行**せよ) | DCError.Code、Establishing…「Certify the key pairs as valid」 | 部分: `generateAssertion` では catch から外して NSError のまま投げ、`ClaudeRelay.run` が 400 `app_attest`(Codex は再試行しない)。`attestKey` で出た場合、鍵 ID は `register` が成功するまで保存しないので次回は **新しい鍵** で始める(Apple の「同じ鍵で再試行」とは違う。鍵の数が増える) | 単体: 未対応。実機: 機内モードで初回登録 |
| 鍵は再インストール・端末移行・バックアップ復元で消える。鍵 ID だけが永続ストレージに残る | Establishing…「Start over on reinstallation」「Create a key pair」 | `AppAttestClient.swift: keychainSet`(`kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`、同期しない)。消えた鍵の検出は上の invalidInput/invalidKey の行 | 単体: `testReinstalledDevice…`(Keychain に古い ID、鍵なし、token 期限切れの状態を作る)。実機: 入れ直し |
| 鍵 ID は保存しないと二度と取れない(登録が通ってから保存) | Establishing…「Create a key pair」 | `AppAttestClient.swift: register`(`keychainSet(Data(newKey.utf8), "\(clientID)#key-id")` は `requireSuccess` の後) | 単体: `testRegistersOnceThenMintsWithTheBoundAssertion` |
| attestation(初回、`attestKey`)と assertion(以後、`generateAssertion`)は別物。assertion はチャレンジを含む clientDataHash に署名 | Establishing…「Certify…」「Assert your app's validity」 | `AppAttestClient.swift: register`(attestKey + `v1/oauth/app-attest/register`)、`mint`(generateAssertion + `v1/oauth/token`)、`assertionClientDataHash` | 単体: `testRegistersOnce…`、`testAssertionBindingMatchesTheVersionedLayout` |
| チャレンジは 1 回限り・16 バイト以上・サーバー発行 | Establishing…「Certify the key pairs as valid」 | `AppAttestClient.swift: fetchChallenge`(`pendingChallenge` を先に使う、残り 15 秒未満は取り直す)、`ingest`(`next_challenge`) | 単体: `testRegistersOnce…`(`next_challenge` の再利用を確かめる) |
| サーバー側の検証で attestation が拒まれる(この app の場合: Anthropic Console の App integration に **Team ID + Bundle ID** が無い。prototype の `com.digiloglab.strius.preview.sNN` は variant ごとに登録が要る) | Establishing…「Your server deems the app instance to be valid if…」。引き継ぎ 2.2・6 | `AppAttestClient.swift: register` → `requireSuccess(status, endpoint: "register")` → `Failure.requestFailed(endpoint: "register", status:)` → `ClaudeRelay.run` の `catch` で 400 `app_attest`(本文に `register HTTP <status>`)。画面には出ない(引き継ぎ 3.5 で予定) | 単体: 未対応(`register` の非 2xx のテストが無い)。実機: **新しい variant(Bundle ID)を作るたびに 1 回**。受け入れ台本に入れる |
| assertion がサーバーに拒まれる(token 交換 401。期限切れ・競合したチャレンジも同じ) | (Anthropic 側の仕様。`mint` のコメント) | `AppAttestClient.swift: mint`(401 → `Failure.keyInvalidated`)→ `refresh`(もう 1 回、続けて拒まれたら 10 分に 1 回まで鍵を作り直す `lastKeyReplacement`) | 単体: 未対応(401 の経路のテストが無い)。模擬: `StubAnthropicAuth` で 401 を返す |
| token 交換のレート制限(429 + Retry-After) | (Anthropic 側) | `AppAttestClient.swift: mint`(`mintCooldownUntil`、`Failure.rateLimited`)→ `ClaudeRelay.run` が 429 で返す | 単体: 未対応 |
| Messages API が token を 401 で拒む(失効・取り消し) | Anthropic errors(401 authentication_error) | `ClaudeResponsesProxy.swift: ClaudeRelay.run`(`status == 401 … !retriedToken` → `attest.invalidate(token:)` して 1 回だけ送り直す) | 単体: `testRegistersOnce…` の後半(invalidate → 登録済みの鍵で mint) |
| App Clip / 拡張では非対応、鍵はユーザーごとに 1 つ | Establishing…「Important」 | 該当なし(Struis は本体アプリのみ、端末 1 ユーザー) | — |

## 表 2: Anthropic Messages API(端末内プロキシ経由)

コード: `strius/Runtime/ClaudeProxy/ClaudeResponsesProxy.swift`(`ClaudeRelay`)、`ClaudeRequestTranslator.swift`、`ClaudeStreamTranslator.swift`、`ClaudeUsageLog.swift`。文書: errors(https://platform.claude.com/docs/en/api/errors)、prompt caching(https://platform.claude.com/docs/en/build-with-claude/prompt-caching)、streaming(https://platform.claude.com/docs/en/build-with-claude/streaming)。Codex に返す status は `ClaudeRelay.codexStatus`: 429→429、401/403→401、400/404/413/422→400、5xx/529→503、他→502。Codex 側の扱いは表 3 の「再試行」の行。

| 公式文書が挙げる状態 | 出どころ(文書の節/URL) | この repo の対応箇所 | 確認の仕方 |
|---|---|---|---|
| 400 `invalid_request_error`(他の 4xx にも使われる) | errors「HTTP errors」 | `ClaudeRelay.run`: 本文に diagnostics → `includeDiagnostics=false` で送り直し(`reason: diagnosticsRetry`)、thinking → `stripThinking`(`ClaudeThinkingRejection.classify`、署名不一致はスレッドに記憶)、grammar/schema → `schemaInInstructions`。それ以外は `codexStatus` で 400 | 単体: `ClaudeCostTests.testThinkingRejectionsSeparateSignatureMismatchFromOtherErrors`、`ClaudeProxyTests.testOversizedSchemaCanMoveIntoTheInstructions`(変換のみ)。送り直しのループ自体のテスト: 未対応 |
| 401 `authentication_error` | errors | `ClaudeRelay.run`(App Attest 経路は token を捨てて 1 回だけ送り直す。API キー経路は 401 のまま) | 単体: 表 1 の最後から 2 行目 |
| 402 `billing_error` | errors | `ClaudeStreamTranslator.responsesErrorCode`(`billing_error` → `insufficient_quota`)。HTTP では `codexStatus` の default → 502 | 単体: 未対応 |
| 403 `permission_error` | errors | `codexStatus` → 401 として Codex へ(個別の扱いなし) | 未対応(テストなし) |
| 404 `not_found_error`(モデル名の誤りはここ) | errors | `codexStatus` → 400。モデル名は `assets.model("astra", provider:)` の配信値 | 未対応 |
| 409 `conflict_error` | errors | `codexStatus` default → 502 | 未対応 |
| 413 `request_too_large` | errors | `codexStatus` → 400(送らずに止める上限は無い。引き継ぎ 3.6)。プロキシ自身の受信上限は `ProxyConnection.receive` の 64 MiB で 413 | 未対応(要求サイズ上限) |
| 429 `rate_limit_error`(+ `retry-after`) | errors | `ClaudeRelay.run`(`Retry-After` を写して 429)。**Codex 側は 429 を再試行しない**(表 3) | 未対応(テストなし) |
| 500 `api_error` | errors | `codexStatus` → 503(Codex が HTTP 段で再試行) | 未対応 |
| 504 `timeout_error`(長い要求は streaming を使え) | errors「Long requests」 | 常に `stream: true`(`ClaudeRequestTranslator.translate`)。`ClaudeUpstream.init` の `timeoutIntervalForRequest = 600` / `Resource = 3_600`。504 自体は `codexStatus` → 503 | 単体: 未対応 |
| 529 `overloaded_error` | errors | `codexStatus` → 503、code `server_is_overloaded`(`responsesErrorCode`)。Codex は HTTP 段で `request_max_retries` 回だけ再試行し、その後は `ServerOverloaded` で止める(表 3) | 単体: `ClaudeProxyTests.testFinalAnswerCustomToolAndFailures`(ストリーム内の overloaded のみ) |
| エラー本文の形(`error.type`・`error.message`・`request_id`、`request-id` ヘッダ) | errors「Error shapes」「Request id」 | `ClaudeRelay.run`(`error.type`/`message` を読む)。`request_id`・`request-id` ヘッダは **未対応**(台帳に残らない。サポート問い合わせに要る) | 未対応 |
| ストリーム中の `error` イベント(200 の後に来る。例 overloaded_error) | streaming「Error events」、errors | `ClaudeStreamTranslator.consume` の `case "error"` → `response.failed`、`errorType`。`ClaudeRelay.run` が `status: "stream_error"` で記録 | 単体: `testFinalAnswerCustomToolAndFailures` |
| `message_stop` 無しで切れる | (文書には無い。実装上の状態) | `ClaudeStreamTranslator.streamEnded`、`ClaudeRelay.run`(`stream_ended`) | 単体: 同上(`truncated`) |
| `ping`・未知のイベント型は無視せよ | streaming「Other events」 | `ClaudeStreamTranslator.consume` の `default` | 単体: 未対応(明示のテストなし) |
| `message_delta.usage` は累積値。`message_start.usage` に入力側 | streaming「Basic streaming request」 | `ClaudeStreamTranslator.readUsage`(上書き)、`rawUsage` | 単体: `testStreamWithThinkingCommentaryToolCallAndUsage` |
| `stop_reason`: `end_turn` / `tool_use` / `max_tokens` / `stop_sequence` / `refusal` / `pause_turn` / `model_context_window_exceeded` | streaming → Stop reasons | `ClaudeStreamTranslator.finish`(refusal → `invalid_prompt`、max_tokens → `response.incomplete`、context window → `context_length_exceeded`)、`ClaudeRelay.status(stopReason:)`。`pause_turn` は記録だけで Codex には `completed` を返す(続きを要求しない) | 単体: `testStreamWith…`、`testFinalAnswer…`。`pause_turn`: 未対応 |
| cache TTL は 5 分(既定)と 1 時間(`ttl: "1h"`) | prompt caching「1-hour cache duration」 | `ClaudeTranslation.cacheControl(ttl:)`、`tailCacheTTL(kind:)`(chat 系 1h、単発 5m)、`ClaudeRequestTranslator.translate`(system に 1h、末尾は top-level `cache_control`) | 単体: `ClaudeCostTests.testVersionTwoCachesTheFixedInstructionsForAnHourAndTheTailByTaskGroup` |
| 長い TTL は短い TTL より前に置く。最後のブロックに別 TTL の明示 `cache_control` があると自動キャッシュは 400 | prompt caching「Mixing different TTLs」「Automatic prompt caching」 | `translate`(system=1h が先、末尾は top-level)。system が最後のブロックになることは無い(messages が空なら "Continue." を足す) | 単体: 同上(順序)。400 の経路: 未対応 |
| 明示 breakpoint は最大 4、自動が 1 つ使う。超えると 400 | prompt caching「Automatic…」 | `translate` は明示 1(system)+ 自動 1 | — |
| 最小キャッシュ長(512〜4096 トークン、モデルによる)未満はキャッシュされずエラーも出ない | prompt caching「Cache limitations」 | 未対応(`cache_state: cold` としか残らない) | 未対応 |
| `usage` の `cache_creation_input_tokens`・`cache_read_input_tokens`・`cache_creation.ephemeral_5m/1h_input_tokens` | prompt caching「Tracking cache performance」 | `ClaudePricing.Tokens.init(usage:assumedWriteTTL:)`(内訳が無い時は TTL を仮定、`write_split: estimated`)、`ClaudeStreamTranslator.readUsage`、`ClaudeRelay.Attempt.finish`(台帳 `tokens.cache_read`・`prompt_total`) | 単体: `testPricingSplitsCacheWritesByTTLAndUsesTheModelThatAnswered`、`testCacheStateSeparatesExpiryFromChangedRequests` |
| キャッシュが無効になる変更(tools → system → messages の順、thinking・effort・tool_choice・画像の増減) | prompt caching「What invalidates the cache」 | `CodexTurnRunner.threadProfile`(instructions/tools/schema/effort/thinking のハッシュを `ThreadContextStore.Profile` に固定)、`ClaudeCacheDiagnosis.state`(`*_changed` / `expired` / `cold`)。新スレッドで `cache_read 0` になる原因は未調査(引き継ぎ 2.2、6.1) | 単体: `testCacheStateSeparates…`、`testVersionTwoSendsTheSameBytesForTheSameContent`。原因: 未対応 |
| 料金倍率(5m 書き 1.25x、1h 書き 2x、読み 0.05x〜0.1x) | prompt caching「Pricing」 | `ClaudePricing.tables`(モデル別の実額)、`ClaudePricing.cost` | 単体: `testPricingSplits…`、`testHaikuTierIsChosenPerRequestFromTheWholePrompt` |
| `max_tokens` と context window | Messages API | `ClaudeRequestTranslator.Options.maxTokens = 64_000`、`ClaudeModelInfo.contextWindow = 272_000`(Codex に渡す。Claude の実上限とは別) | 単体: 未対応 |

## 表 3: Codex app-server の設定(端末内)

コード: `NativeRuntime/NativeCodex/src/lib.rs`(起動時の `CliConfigOverrides`)、`strius/Runtime/NativeToolRouter.swift: configuration`(スレッドごとの `config`)、`strius/Runtime/CodexTurnRunner.swift: applyProvider`、`strius/Runtime/ClaudeProxy/ClaudeResponsesProxy.swift: providerConfig`。出どころは tag `rust-v0.153.4` の `codex-rs/` 配下のパス。

| 公式文書が挙げる状態 | 出どころ(ソースのパス) | この repo の対応箇所 | 確認の仕方 |
|---|---|---|---|
| `features.apps`: 既定 **true**(stable)。ChatGPT にサインインしていると `codex_apps` MCP の全コネクタ tool を要求に入れる | `features/src/lib.rs`(`key: "apps", default_enabled: true`)、`core/src/mcp_tool_exposure.rs` | `NativeToolRouter.swift: configuration`(`features.apps = false`)、`DelegationWatcher.swift`(下調べの子にも false) | 単体: `ClaudeCostTests.testCodexConfigurationDisablesAppsPluginsAndBundledSkills`。実機: ChatGPT ログイン済みで台帳の `prompt_total` ≈ 3 万 |
| `features.plugins`: 既定 true | `features/src/lib.rs`(`key: "plugins"`) | 同上(`features.plugins = false`) | 同上 |
| `features.tool_suggest`: 既定 true。apps と plugins が両方 on のときだけ効く | `features/src/lib.rs`(`key: "tool_suggest"`)、`core/src/tools/spec_plan.rs: tool_suggest_enabled` | 同上(`features.tool_suggest = false`) | 同上 |
| `features.shell_tool` / `code_mode` / `multi_agent` / `shell_snapshot`、`agents.enabled`、`skills.bundled.enabled` | `features/src/lib.rs`、`core/src/config/mod.rs` | `lib.rs: hyotan_codex_start`(`raw_overrides`: shell_tool/code_mode/code_mode_host/shell_snapshot/multi_agent/multi_agent_v2 = false、`agents.enabled=false`、`analytics.enabled=false`)、`NativeToolRouter.configuration`(`features.code_mode.direct_only_tool_namespaces: ["struis"]`、`skills.bundled.enabled=false`) | 単体: 同上(configuration のみ)。`lib.rs` の override: 未対応(Linux の replica で `thread/start` の tool 一覧を見る手順は引き継ぎ 6) |
| 未知のモデルは fallback metadata: `context_window 272_000`、`effective_context_window_percent 95`、`auto_compact_token_limit None`、**`supports_search_tool: false`**。Warning イベント「Model metadata for … not found」を出す | `models-manager/src/model_info.rs`(`used_fallback_model_metadata: true` の構造体)、`core/src/session/turn_context.rs: maybe_emit_model_warnings_for_turn` | `CodexTurnRunner.applyProvider`(`model_context_window`・`model_auto_compact_token_limit` を明示。`ClaudeModelInfo`)。`supports_search_tool` は設定で変えられない → apps/plugins を切ることで回避。Warning イベントの受け取り: **未対応** | 単体: 未対応(`applyProvider` のテストなし) |
| MCP tool の露出: `search_tool_enabled`(= `supports_search_tool && namespace_tools`)なら `Deferred`(名前だけ)、でなければ `Direct`(全文) | `core/src/mcp_tool_exposure.rs`(`let exposure = if search_tool_enabled { Deferred } else { Direct }`)、`core/src/tools/spec_plan.rs: search_tool_enabled` | Claude のモデルでは常に Direct。MCP サーバーをつながない(apps=false、`CODEX_HOME` はアプリ管理で `mcp_servers` 無し)ことで露出ゼロ。Struis 自身の tool は `dynamicTools`(`NativeToolRouter.definitions`)で MCP ではない | 単体: `testCodexConfiguration…`。実機: 台帳 `prompt_total` |
| `model_providers.<id>.base_url` / `wire_api = "responses"` / `experimental_bearer_token` / `requires_openai_auth` | `model-provider-info/src/lib.rs`(`ModelProviderInfo`) | `ClaudeResponsesProxy.providerConfig`、`CodexTurnRunner.applyProvider`(`config["model_providers.\(providerID)"]`、`modelProvider`) | 単体: `ClaudeProxyTests.testProxyRejectsWrongTokenAndRelaysTheStream`(プロキシ側)。`applyProvider`: 未対応 |
| `request_max_retries`(既定 4)、`stream_max_retries`(既定 5)、`stream_idle_timeout_ms`(既定 300 000) | `model-provider-info/src/lib.rs`(`DEFAULT_*`) | `providerConfig`(4 / 2 / 300 000) | 単体: 未対応(値の固定テストなし) |
| 再試行の判定: HTTP 段は `retry_429: false, retry_5xx: true, retry_transport: true`(`request_max_retries` 回)。その後 `is_retryable()`: `InvalidRequest`(400)・`RetryLimit`(429)・`ServerOverloaded`(503 + `server_is_overloaded`)・`ContextWindowExceeded`・`UsageLimitReached` は **再試行しない**。`UnexpectedStatus`(401/403/404/413 など)・`InternalServerError`・`Stream`・`Timeout` は `stream_max_retries` 回 | `model-provider-info/src/lib.rs`(`ApiRetryConfig`)、`codex-client/src/retry.rs: RetryOn::should_retry`、`codex-api/src/api_bridge.rs: map_api_error`、`protocol/src/error.rs: is_retryable`、`core/src/session/turn.rs`(`max_retries` のループ) | `ClaudeRelay.codexStatus`(再試行させたくない失敗 = App Attest・変換失敗は 400)。**注意**: `ClaudeRelay.run` のコメント「混雑は 429」と `ClaudeRelay.codexStatus` は Codex が 429 を再試行する前提だが、この pin では 429 は `RetryLimit` で即失敗。529 → 503 は HTTP 段で 4 回だけ | 単体: 未対応(status 変換 `codexStatus` のテストなし)。模擬: `STRUIS_ANTHROPIC_BASE_URL` で 429/529 を返す |
| `response.failed` の `error.code`: `context_length_exceeded` → ContextWindowExceeded、`insufficient_quota` → QuotaExceeded、`rate_limit_exceeded` → RateLimitExceeded(再試行)、`server_is_overloaded`、`invalid_prompt` | `codex-api/src/sse/responses.rs` | `ClaudeStreamTranslator.responsesErrorCode`、`finish`(refusal → `invalid_prompt`、context window → `context_length_exceeded`) | 単体: `testFinalAnswerCustomToolAndFailures`、`testStreamWith…` |
| 自動 compaction: `model_auto_compact_token_limit`(未設定ならモデル既定)、`model_auto_compact_token_limit_scope`(既定 total)。compaction の要求も provider に飛ぶ | `core/src/config/mod.rs`、`core/src/compact.rs`(`stream_max_retries` を使う) | `applyProvider`(`ClaudeModelInfo.autoCompactTokenLimit = 244_800`)、`CodexTurnRunner`(`contextCompaction` item → 台帳 `compactions[]`・進捗表示、終了後 `contextStore.forgetMemory`)、`ClaudeRequestLog.classify`(`request_kind == "compaction"` → `.compaction`) | 単体: `ClaudeCostTests.testRequestsAreGroupedPerTurnAndClassified`。compaction 回数の上限・計器: 未対応(引き継ぎ 5.1) |
| 1 ターン内の要求回数(continuation / validation_repair の繰り返し)に上限が無い | (Codex の仕様というより Struis の運用。引き継ぎ 2.2) | `ClaudeRequestReason`(分類のみ) | 未対応(引き継ぎ 3.6) |
| Codex pin の更新で enum・既定値が変わる | `NativeRuntime/Scripts/build-codex.py`(`rust-v0.153.4`) | この文書の表 3 を更新する(使い方 6) | pin 変更の PR で表 3 の差分を必須にする |

## この週に起きた 3 件がどの行で捕まったか

| 障害(引き継ぎ 2.2) | 捕まえる行 | その行があれば何が起きたか |
|---|---|---|
| Bundle ID が Anthropic Console に未登録で、prototype の最初のターンが `register HTTP 4xx` で落ちた | 表 1「サーバー側の検証で attestation が拒まれる(Console に Team ID + Bundle ID が無い)」 | 対応箇所は `Failure.requestFailed` だけで、確認の仕方が「実機、新しい variant ごと」。variant を増やす手順(引き継ぎ 6)に「Console 登録」が必須項目として入り、ビルド前に気づく。単体テストが無いので行は Issue になる |
| 1 要求 19 万トークン(`apps` が既定 on、Claude は未知モデルで `supports_search_tool: false` → MCP tool が `Direct` で全文) | 表 3「`features.apps` 既定 true」+「未知のモデルは fallback metadata」+「MCP tool の露出」 | 「既定 true」を書いた時点で「切っているか」を確認する行になる。切る前の状態では対応箇所が **未対応** で、ChatGPT ログイン済みの実機で `prompt_total` を見る確認が要求される。GPT 経路では遅延されて表に出ない理由も「露出」の行で説明できる |
| 入れ直し後、Keychain の鍵 ID が残り Secure Enclave の鍵が無く、`DCError.invalidInput(2)` で止まった | 表 1「`DCError.invalidInput`」「`DCError.invalidKey`」「鍵は再インストール・移行・復元で消える」 | 修正前は `generateAssertion` の DCError が NSError のまま 400 になり、鍵を作り直さなかった(対応箇所が **未対応**)。行の確認の仕方「同じ variant を削除→再インストール→最初のターン」が受け入れ台本に入る |

残っている未対応のうち、実機でしか起きないものは表 1 の `serverUnavailable`(機内モードで初回登録)と表 2 の 429/529(Codex が再試行しない件)。これらは Issue にして Phase 3.5(理由の表示)と 3.6(要求上限)に紐づける。

## 今回の記入で見つかった未対応(そのまま Issue の題名にする)

表の行から「未対応」だけを抜き出したもの。番号は優先順(実機で起きる順)。

1. 表 1「サーバー側の検証で attestation が拒まれる(Console に Team ID + Bundle ID が無い)」: `register` の非 2xx の単体テストが無い。variant 追加手順に Console 登録を必須化。
2. 表 3「再試行の判定」: `ClaudeRelay.codexStatus` と `run` のコメントは Codex が 429 を再試行する前提だが、`rust-v0.153.4` の `RetryOn { retry_429: false }` と `is_retryable()` の `RetryLimit => false` で 429 は即失敗。529 → 503 も HTTP 段の 4 回まで。`codexStatus` の単体テストと、429 のときにプロキシ側で `Retry-After` 分待つかの判断が要る。
3. 表 2「エラー本文の `request_id` / `request-id` ヘッダ」: 台帳に残らない。`ClaudeRelay.Attempt.finish` に 1 項目足せば済む。
4. 表 3「未知のモデルの Warning イベント」: `CodexTurnRunner` が `EventMsg::Warning` を読んでいない。台帳に残せば「Codex が Claude を未知のモデルとして扱っている」ことが実機の記録から分かる。
5. 表 1「`DCError.serverUnavailable`」: Apple は同じ鍵で後で再試行と言うが、`attestKey` 失敗時は鍵 ID を保存しないので次回は新しい鍵になる。鍵の数が増えるだけで動作はするが、Apple の指針との差として記録。
6. 表 1「`isSupported == false`」「`unknownSystemFailure`」「`featureUnsupported`」: `Attestation` stub でそれぞれを注入する単体テストが無い。
7. 表 2「413 `request_too_large`」: 送る前の要求サイズ上限が無い(引き継ぎ 3.6 と同じ)。
8. 表 2「`pause_turn`」: Codex には `completed` を返すので、Claude が続きを求めても次の要求が出ない。server tool を使っていない今は起きないが、行として残す。
9. 表 2「最小キャッシュ長未満」: `cache_state: cold` と区別できない。短い要求(下調べの子など)の `cold` が期限切れか未達かを分けるには、`prompt_total` と最小長の比較を `ClaudeCacheDiagnosis.state` に足す。
10. 表 3「`applyProvider`・`providerConfig` の値」: `request_max_retries 4 / stream_max_retries 2 / stream_idle_timeout_ms 300000`・`model_context_window 272000`・`model_auto_compact_token_limit 244800` を固定する単体テストが無い。pin を上げたときに差分が出る場所なので、値を固定しておく。

## 出どころの一覧(取得日 2026-10-17)

- Apple `DCError.Code`: https://developer.apple.com/documentation/devicecheck/dcerror-swift.struct/code(5 つ: `featureUnsupported`・`invalidInput`・`invalidKey`・`serverUnavailable`・`unknownSystemFailure`)
- Apple「Establishing your app's integrity」: https://developer.apple.com/documentation/devicecheck/establishing-your-app-s-integrity(`isSupported`、`serverUnavailable` だけ同じ鍵で再試行、再インストール・移行・復元で鍵が消える)
- Anthropic errors: https://platform.claude.com/docs/en/api/errors(400/401/402/403/404/409/413/429/500/504/529、`request_id`、長い要求は streaming)
- Anthropic prompt caching: https://platform.claude.com/docs/en/build-with-claude/prompt-caching(5m/1h、順序、breakpoint 4 つ、最小長、usage の内訳、無効化の表、料金倍率)
- Anthropic streaming: https://platform.claude.com/docs/en/build-with-claude/streaming(イベント型、`error` イベント、`ping`・未知の型、`message_delta.usage` は累積)
- Codex `rust-v0.153.4`(`git clone --depth 1 --branch rust-v0.153.4 https://github.com/openai/codex.git`):
  - `codex-rs/features/src/lib.rs`: `apps`・`plugins`・`tool_suggest`・`shell_tool` の `default_enabled: true`
  - `codex-rs/core/src/mcp_tool_exposure.rs`: `ToolExposure::{Deferred, Direct, Hidden}`、`search_tool_enabled` で分岐
  - `codex-rs/core/src/tools/spec_plan.rs`: `search_tool_enabled`(`supports_search_tool && namespace_tools`)、`tool_suggest_enabled`
  - `codex-rs/models-manager/src/model_info.rs`: fallback metadata(`context_window 272_000`、`supports_search_tool: false`)
  - `codex-rs/core/src/session/turn_context.rs`: `maybe_emit_model_warnings_for_turn`
  - `codex-rs/model-provider-info/src/lib.rs`: `DEFAULT_REQUEST_MAX_RETRIES 4`、`DEFAULT_STREAM_MAX_RETRIES 5`、`DEFAULT_STREAM_IDLE_TIMEOUT_MS 300_000`、`ApiRetryConfig { retry_429: false, retry_5xx: true, retry_transport: true }`
  - `codex-rs/codex-client/src/retry.rs`: `RetryOn::should_retry`
  - `codex-rs/codex-api/src/api_bridge.rs`: `map_api_error`(400 → `InvalidRequest`、429 → `RetryLimit`、500 → `InternalServerError`、503 + `server_is_overloaded` → `ServerOverloaded`、他 → `UnexpectedStatus`)
  - `codex-rs/codex-api/src/sse/responses.rs`: `response.failed` の `error.code` の判定
  - `codex-rs/protocol/src/error.rs`: `CodexErr::is_retryable`
  - `codex-rs/core/src/session/turn.rs`: `stream_max_retries` のループと `ContextWindowExceeded`・`UsageLimitReached` の早期 return
  - 同 tag の `docs/config.md` は hooks の節だけなので、設定キーの出どころにはソースを使う。公開の config reference(https://learn.chatgpt.com/docs/config-file/config-reference)は版が明記されていないため補助扱い。
