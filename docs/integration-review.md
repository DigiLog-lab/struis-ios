# 統合部分のレビュー形式(App Attest / Anthropic Messages API / 直結ランナー)

2026-10-17の引き継ぎ(2.2・5.4、文書は2026-11-02に削除)の結論: 今週の実機障害 3 件(Console に Bundle ID 未登録、19 万トークン、入れ直し後の古い鍵)は UI テストでは原理的に捕まらない。原因は「各統合が取り得る状態を誰も列挙していなかった」こと。この文書は、統合ごとに **公式文書が挙げる状態を全部並べ、横にこの repo の対応箇所を書く** 形式を固定する。空欄(未対応)がそのまま課題になる。

2026-11-03 に端末内の Codex(app-server と `127.0.0.1` の中継)を外した。すべてのターンは `ClaudeTurnRunner` が Messages API を端末から直接呼ぶ。以前の表 3(Codex app-server の設定)は、直結ランナーの設定の表に置き換えた。

## 使い方

1. 回すタイミング: (a) 下の「対象ファイル」のどれかを変える prototype ビルドの前。(b) `ClaudeTurnRunner.Timeouts` や `ClaudeTranslation` の版を変えた後。(c) SwiftMath など描画側の変更では回さない(この文書の対象外)。
2. 1 行 = 公式文書が名前を付けている状態・エラー・条件 1 つ。行を増やすときは必ず「出どころ」に文書の節名か URL を書く。推測で行を作らない。表 3 は Struis 自身の設定値なので、出どころの列の代わりに値を書く。
3. 「この repo の対応箇所」は `ファイル:シンボル` で書く(例 `AppAttestClient.swift: DeviceAttestation.generateAssertion`)。grep で実在を確かめてから書く。何も扱っていなければ **未対応** と書く。部分的なら「部分: 何が足りないか」。
4. 「確認の仕方」は 単体テスト(テスト名)/ 実機 / 模擬サーバー(`scripts/e2e/fake_anthropic.py`・`STRUIS_ANTHROPIC_BASE_URL`)のどれか。実機でしか起きない状態は実機と書き、prototype の受け入れ台本に入れる。
5. 対応箇所が「未対応」の行、または確認の仕方が空の行は、そのまま Issue にする。Issue の題名はその行の「公式文書が挙げる状態」の文字列。本文に出どころと対応箇所の列を写す。
6. 対象ファイル: `strius/Runtime/Claude/*.swift`(`ClaudeTurnRunner`・`ClaudeUpstream`・`AppAttestClient`・`ClaudeRequestFormat`・`ClaudeStreamStatus`・`ClaudeMessageReader`・`ClaudeUsageLog`・`ClaudeConversationStore`)、`strius/Runtime/NativeToolRouter.swift`、`strius/Runtime/ModelProvider.swift`。
7. 表の行は消さない。対応が入ったら対応箇所の列を書き換え、確認の仕方にテスト名を足す。
8. レビューはエージェントでも人でもよい。エージェントに渡すときはこの文書と上の対象ファイルだけを文脈に与え、「表の各行について対応箇所を grep で確かめ、違っていたら直せ」と指示する。
9. 出どころの確認日: Apple 文書・Anthropic 文書は 2026-10-17 に取得。

## 表 1: Apple App Attest(DeviceCheck)

コード: `strius/Runtime/Claude/AppAttestClient.swift`、テスト: `striusTests/Runtime/ClaudeAppAttestTests.swift`。Anthropic 側の呼び先は `https://api.anthropic.com` の `v1/oauth/app-attest/challenge`・`v1/oauth/app-attest/register`・`v1/oauth/token`。Apple の文書は `DCError.Code`(https://developer.apple.com/documentation/devicecheck/dcerror-swift.struct/code)と「Establishing your app's integrity」(https://developer.apple.com/documentation/devicecheck/establishing-your-app-s-integrity)。

App Attest の失敗(`AppAttestClient.Failure` と `com.apple.devicecheck.error` の NSError)は、`ClaudeTurn.ask` が送り直さずにターンの失敗にする。理由は `ClaudeTurnRunner.describe` で実行監査の `error` に残る。

| 公式文書が挙げる状態 | 出どころ(文書の節/URL) | この repo の対応箇所 | 確認の仕方(単体テスト / 実機 / 模擬サーバー) |
|---|---|---|---|
| `isSupported == false`(端末が App Attest 非対応。Simulator はここに入る) | Establishing…「Check for availability」 | `AppAttestClient.swift: register` → `Failure.unsupported`。経路の選択は `ClaudeUpstream.swift: ClaudeUpstream.init(session:)`(nil → `ClaudeTurn.run` が `ModelProviderError.claudeUnavailable`)、`ModelProvider.swift: ClaudeAccess.isAvailable`、`ModelProviderError.claudeUnavailable`(画面の文言) | 単体: 未対応(`Attestation.isSupported=false` のテストが無い)。Simulator で DEBUG の API キーを外して起動すると実際に通る経路 |
| `DCError.unknownSystemFailure`(token を作れない等の一般の失敗) | DCError.Code | 部分: `generateKey`/`attestKey` で出た場合は `DeviceAttestation` が写さず NSError のまま `ClaudeTurn.ask` の `catch` に届き、`domain == "com.apple.devicecheck.error"` でターンの失敗にする。`generateAssertion` で出た場合は `DeviceAttestation.generateAssertion` が `Failure.keyUnusable` にして鍵を作り直す(Apple の指針「serverUnavailable 以外は鍵を捨てる」に合わせた) | 単体: 未対応(unknownSystemFailure を注入するテストが無い)。実機 |
| `DCError.featureUnsupported`(DeviceCheck がこの端末で使えない) | DCError.Code | 上の `isSupported` と同じ。`DeviceAttestation` の 3 メソッドからは NSError のまま → ターンの失敗 | 単体: 未対応 |
| `DCError.invalidInput`(渡したデータの形式が不正。実機では入れ直し後の assertion で Code=2 として出た) | DCError.Code。引き継ぎ 2.2・6 | `AppAttestClient.swift: DeviceAttestation.generateAssertion`(`error.code != .serverUnavailable` → `Failure.keyUnusable`)→ `refresh` の `catch Failure.keyUnusable` → `ensureKey(replacing:)` で Keychain の ID と token を消して `register` | 単体: `testReinstalledDeviceRegistersANewKeyWhenTheStoredKeyIsUnusable`。実機: 同じ variant を削除→再インストール→最初のターン |
| `DCError.invalidKey`(App Attest の鍵を使えない) | DCError.Code | 同上(`generateAssertion` の catch は `serverUnavailable` 以外を全部 `keyUnusable` にする) | 単体: 同上(テストは `keyUnusable` を投げる stub で代用。DCError の code 別には分けていない) |
| `DCError.serverUnavailable`(attestation 中に Apple のサーバーへ届かない。**同じ鍵で後で再試行**せよ) | DCError.Code、Establishing…「Certify the key pairs as valid」 | 部分: `generateAssertion` では catch から外して NSError のまま投げ、ターンの失敗になる(送り直さない)。`attestKey` で出た場合、鍵 ID は `register` が成功するまで保存しないので次回は **新しい鍵** で始める(Apple の「同じ鍵で再試行」とは違う。鍵の数が増える) | 単体: 未対応。実機: 機内モードで初回登録 |
| 鍵は再インストール・端末移行・バックアップ復元で消える。鍵 ID だけが永続ストレージに残る | Establishing…「Start over on reinstallation」「Create a key pair」 | `AppAttestClient.swift: keychainSet`(`kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`、同期しない)。消えた鍵の検出は上の invalidInput/invalidKey の行 | 単体: `testReinstalledDevice…`(Keychain に古い ID、鍵なし、token 期限切れの状態を作る)。実機: 入れ直し |
| 鍵 ID は保存しないと二度と取れない(登録が通ってから保存) | Establishing…「Create a key pair」 | `AppAttestClient.swift: register`(`keychainSet(Data(newKey.utf8), "\(clientID)#key-id")` は `requireSuccess` の後) | 単体: `testRegistersOnceThenMintsWithTheBoundAssertion` |
| attestation(初回、`attestKey`)と assertion(以後、`generateAssertion`)は別物。assertion はチャレンジを含む clientDataHash に署名 | Establishing…「Certify…」「Assert your app's validity」 | `AppAttestClient.swift: register`(attestKey + `v1/oauth/app-attest/register`)、`mint`(generateAssertion + `v1/oauth/token`)、`assertionClientDataHash` | 単体: `testRegistersOnce…`、`testAssertionBindingMatchesTheVersionedLayout` |
| チャレンジは 1 回限り・16 バイト以上・サーバー発行 | Establishing…「Certify the key pairs as valid」 | `AppAttestClient.swift: fetchChallenge`(`v1/oauth/app-attest/challenge`。`pendingChallenge` を先に使う、残り 15 秒未満は取り直す)、`ingest`(`next_challenge`) | 単体: `testRegistersOnce…`(`next_challenge` の再利用を確かめる) |
| サーバー側の検証で attestation が拒まれる(この app の場合: Anthropic Console の App integration に **Team ID + Bundle ID** が無い。prototype の `com.digiloglab.strius.preview.sNN` は variant ごとに登録が要る) | Establishing…「Your server deems the app instance to be valid if…」。引き継ぎ 2.2・6 | `AppAttestClient.swift: register` → `requireSuccess(status, endpoint: "register")` → `Failure.requestFailed(endpoint: "register", status:)` → ターンの失敗。文言は `Failure.errorDescription`(「Claude を使う準備に失敗しました(register HTTP <status>)」) | 単体: 未対応(`register` の非 2xx のテストが無い)。実機: **新しい variant(Bundle ID)を作るたびに 1 回**。受け入れ台本に入れる |
| assertion がサーバーに拒まれる(token 交換 401。期限切れ・競合したチャレンジも同じ) | (Anthropic 側の仕様。`mint` のコメント) | `AppAttestClient.swift: mint`(401 → `Failure.keyInvalidated`)→ `refresh`(もう 1 回、続けて拒まれたら 10 分に 1 回まで鍵を作り直す `lastKeyReplacement`) | 単体: 未対応(401 の経路のテストが無い) |
| token 交換のレート制限(429 + Retry-After) | (Anthropic 側) | `AppAttestClient.swift: mint`(`mintCooldownUntil`、`Failure.rateLimited`)→ ターンの失敗 | 単体: 未対応 |
| Messages API が token を 401 で拒む(失効・取り消し) | Anthropic errors(401 authentication_error) | `ClaudeTurnRunner.swift: ClaudeTurn.ask`(`status == 401`、`.appAttest`、`!retriedToken` → `attest.invalidate(token:clientID:)` して 1 回だけ送り直す。`reason: auth_retry`) | 単体: `testRegistersOnce…` の後半(invalidate → 登録済みの鍵で mint)。`ask` の送り直し自体: 未対応 |
| App Clip / 拡張では非対応、鍵はユーザーごとに 1 つ | Establishing…「Important」 | 該当なし(App Attest を使うのは本体アプリだけ、端末 1 ユーザー) | — |

## 表 2: Anthropic Messages API(端末から直接)

コード: `strius/Runtime/Claude/ClaudeTurnRunner.swift`(`ClaudeTurn.ask`・`body`・`exchange`)、`ClaudeUpstream.swift`(送り先・認証・`ClaudeRequestAttempt`)、`ClaudeStreamStatus.swift`、`ClaudeMessageReader.swift`、`ClaudeRequestFormat.swift`(`ClaudeTranslation`)、`ClaudeUsageLog.swift`。文書: errors(https://platform.claude.com/docs/en/api/errors)、prompt caching(https://platform.claude.com/docs/en/build-with-claude/prompt-caching)、streaming(https://platform.claude.com/docs/en/build-with-claude/streaming)。HTTP の失敗は変換せず、`ClaudeTurn.ask` が status ごとに送り直すかターンの失敗にするかを決める。

| 公式文書が挙げる状態 | 出どころ(文書の節/URL) | この repo の対応箇所 | 確認の仕方 |
|---|---|---|---|
| 400 `invalid_request_error`(他の 4xx にも使われる) | errors「HTTP errors」 | `ClaudeTurn.ask`: 本文に diagnostics → `includeDiagnostics = false` で送り直し(`reason: diagnostics_retry`)、thinking → `stripThinking`(`ClaudeThinkingRejection.classify`、署名不一致は `ThreadContextStore` に記憶して以後も外す)、grammar/schema → `schemaInInstructions`。それ以外はターンの失敗 | 単体: `ClaudeCostTests.testThinkingRejectionsSeparateSignatureMismatchFromOtherErrors`、`ClaudeTurnRunnerTests.testStructuredTurnSendsTheSchemaAsOutputFormatAndMovesItIntoTheInstructionsWhenRejected`。diagnostics・thinking の送り直し: 未対応 |
| 401 `authentication_error` | errors | `ClaudeTurn.ask`(App Attest 経路は token を捨てて 1 回だけ送り直す。API キー経路はターンの失敗) | 単体: 表 1 の最後から 2 行目 |
| 402 `billing_error` | errors | ターンの失敗(個別の扱いなし) | 未対応 |
| 403 `permission_error` | errors | ターンの失敗(個別の扱いなし) | 未対応 |
| 404 `not_found_error`(モデル名の誤りはここ) | errors | ターンの失敗。モデル名は `ClaudeModels`・`TimelineModels` | 未対応 |
| 409 `conflict_error` | errors | ターンの失敗 | 未対応 |
| 413 `request_too_large` | errors | 送る前に止める: `ClaudeUpstream.maxRequestBytes`(20 MiB)を超える本文は送らず、要求の記録に `status: oversized` を残してターンの失敗にする | 単体: `ClaudeTurnRunnerTests.testRequestSizeCapSitsBelowAnthropicsLimitAndAboveNormalTurns` |
| 429 `rate_limit_error`(+ `retry-after`) | errors | **送り直さない**(ターンの失敗)。`retry-after` は読むが、使うのは 5xx の待ちだけ | 未対応(テストなし)。模擬: `fake_anthropic.py` の `faults` で 429 |
| 500 `api_error` | errors | `ClaudeTurn.ask`(5xx は `Timeouts.requestRetries` 回まで送り直す。待ちは `backoff`) | 模擬: `faults` の `http` 500 |
| 504 `timeout_error`(長い要求は streaming を使え) | errors「Long requests」 | 常に `stream: true`(`ClaudeTurn.body`)。`ClaudeUpstream.init` の `timeoutIntervalForRequest = 600` / `Resource = 3_600`。504 自体は 5xx として送り直す | 単体: 未対応 |
| 529 `overloaded_error` | errors | HTTP の 529 は 5xx と同じく送り直す。ストリーム内の `overloaded_error` は送り直さない(`ClaudeTurn.ask` の `type != "overloaded_error"`) | 模擬: `faults` の `http` 529・`sse_error` |
| エラー本文の形(`error.type`・`error.message`・`request_id`、`request-id` ヘッダ) | errors「Error shapes」「Request id」 | `ClaudeTurn.exchange`(`error.type`/`message` を読む)。`request_id`・`request-id` ヘッダは **未対応**(台帳に残らない。サポート問い合わせに要る) | 未対応 |
| ストリーム中の `error` イベント(200 の後に来る。例 overloaded_error) | streaming「Error events」、errors | `ClaudeStreamStatus.consume` の `case "error"` → `errorType`。`ClaudeTurn.ask` が `status: "stream_error"` で記録し、overloaded 以外は `Timeouts.streamRetries` 回まで送り直す | 単体: `ClaudeCostTests.testStreamErrorsAndRejectedRequestsAreNotBilled`(記録のみ)。模擬: `faults` の `sse_error` |
| `message_stop` 無しで切れる | (文書には無い。実装上の状態) | `ClaudeTurn.exchange` → `.ended`、`ClaudeTurn.ask`(`status: stream_ended`、`Timeouts.streamRetries` 回まで送り直す) | 模擬: `faults` の `drop` |
| ストリームが止まる(何も届かない) | (文書には無い。実装上の状態) | `ClaudeTurn.watchStream`: 答えを書き始めた後に `Timeouts.messageStall` 届かなければ止まった答え(続く会話・下調べの子は `streamRetries` の範囲で送り直し、1 回で終わるターンはターンごと 1 回送り直す)。何も届かないまま `Timeouts.streamIdle` で通信の失敗として `requestRetries` の範囲で送り直す | 模擬: `faults` の `stall` |
| `ping`・未知のイベント型は無視せよ | streaming「Other events」 | `ClaudeStreamStatus.consume` の `default`、`ClaudeMessageReader.consume` | 単体: 未対応(明示のテストなし) |
| `message_delta.usage` は累積値。`message_start.usage` に入力側 | streaming「Basic streaming request」 | `ClaudeStreamStatus.readUsage`(上書き)、`rawUsage` | 単体: `ClaudeCostTests.testThinkingTokensAreRecordedOnlyWhenClaudeReportsThem` |
| `stop_reason`: `end_turn` / `tool_use` / `max_tokens` / `stop_sequence` / `refusal` / `pause_turn` / `model_context_window_exceeded` | streaming → Stop reasons | `ClaudeTurn.ask`(refusal・max_tokens・context window → ターンの失敗)、`ClaudeRequestAttempt.status(stopReason:)`。`pause_turn` は記録(`paused`)だけで、続きを要求しない | `pause_turn`: 未対応 |
| cache TTL は 5 分(既定)と 1 時間(`ttl: "1h"`) | prompt caching「1-hour cache duration」 | `ClaudeTranslation.cacheControl(ttl:)`、`tailCacheTTL(kind:)`(`chat`・`thread_fork` は 1h、他は 5m。下調べの子は 5m)、`ClaudeTurn.system`(system に 1h)、`ClaudeTurn.body`(末尾は top-level `cache_control`) | 単体: `ClaudeCostTests.testTailTTLFollowsTheTaskGroupAndTheFixedInstructionsAreCachedForAnHour` |
| 長い TTL は短い TTL より前に置く。最後のブロックに別 TTL の明示 `cache_control` があると自動キャッシュは 400 | prompt caching「Mixing different TTLs」「Automatic prompt caching」 | system=1h が先、末尾は top-level。messages は必ずこのターンの入力を含むので、system が最後のブロックになることは無い | 単体: 同上(順序)。400 の経路: 未対応 |
| 明示 breakpoint は最大 4、自動が 1 つ使う。超えると 400 | prompt caching「Automatic…」 | 版 2: 明示 1(system)+ 自動 1。版 4(`ClaudeTranslation.tutorSystem`): 明示 2(基本指示と今日の記録の最後)+ 道具の後の続きの要求だけ自動 1(`marksTail`) | 単体: `ClaudeCostTests.testTimelineThreadsStartOnVersionFourAndMarkTheTailOnlyAfterATool` |
| 最小キャッシュ長(512〜4096 トークン、モデルによる)未満はキャッシュされずエラーも出ない | prompt caching「Cache limitations」 | 未対応(`cache_state: cold` としか残らない) | 未対応 |
| `usage` の `cache_creation_input_tokens`・`cache_read_input_tokens`・`cache_creation.ephemeral_5m/1h_input_tokens` | prompt caching「Tracking cache performance」 | `ClaudePricing.Tokens.init(usage:assumedWriteTTL:)`(内訳が無い時は TTL を仮定、`write_split: estimated`)、`ClaudeRequestAttempt.finish`(台帳 `tokens.cache_read`・`prompt_total`) | 単体: `testPricingSplitsCacheWritesByTTLAndUsesTheModelThatAnswered`、`testCacheStateSeparatesExpiryFromChangedRequests` |
| キャッシュが無効になる変更(tools → system → messages の順、thinking・effort・tool_choice・画像の増減) | prompt caching「What invalidates the cache」 | `ClaudeTurnRunner.threadProfile`(instructions/tools/schema/effort/thinking のハッシュを `ThreadContextStore.Profile` に固定)、`ClaudeCacheDiagnosis.state`(`*_changed` / `expired` / `cold`)。tools は `ClaudeToolNames(sorted: true)` で名前順に固定 | 単体: `testCacheStateSeparates…`、`ClaudeRequestFormatTests.testToolsAreFlattenedAndSortedByTheirClaudeNames` |
| 料金倍率(5m 書き 1.25x、1h 書き 2x、読み 0.05x〜0.1x) | prompt caching「Pricing」 | `ClaudePricing.tables`(モデル別の実額)、`ClaudePricing.cost` | 単体: `testPricingSplits…`、`testHaikuTierIsChosenPerRequestFromTheWholePrompt` |
| `max_tokens` と context window | Messages API | `ClaudeRequestFormat.maxTokens = 64_000`。要約(compaction)はしない。直近の要求の入力が `ClaudeModelInfo.autoCompactTokenLimit`(244,800)以上になった会話は、次のターンで新しいスレッドに移り `recent_thread_history.md` で続ける(`ClaudeTurnRunner.resumes`・`ClaudeTurn.openConversation`) | 単体: `ClaudeTurnRunnerTests.testMissingHistoryContinuesOnANewThreadWithTheHistoryNote` |

## 表 3: 直結ランナーの設定(端末内)

コード: `strius/Runtime/Claude/ClaudeTurnRunner.swift`(`ClaudeTurnRunner.Timeouts`・`ClaudeTurn.body`・`ClaudeTurn.ask`)、`ClaudeUpstream.swift`、`ClaudeRequestFormat.swift`。送り直しの回数は以前の Codex の設定(`request_max_retries 4`・`stream_max_retries 2`・`stream_idle_timeout_ms 300000`)に合わせた。

| 設定 | 値 | この repo の対応箇所 | 確認の仕方 |
|---|---|---|---|
| 対象のターン | チャット、分岐(`thread_fork`。モデルを呼ばず履歴を写す)、下調べの子(`struis_delegate`)、`workbook_unit`・`workbook_set`・`workbook_grading`、`timeline_batch`・`timeline_grading`・`timeline_review`・`timeline_marks`・`timeline_graph`、`onboarding_grading`・`onboarding_plan` | `ClaudeTurnRunner.run`・`fork`、`ClaudeTurn`(`child` は `DelegationWatcher.Child`) | 単体: `ClaudeTurnRunnerTests.testForkCopiesTheHistoryUpToTheTurnAndResendsAgentsForItsFolder`、`testPlansSavedWithAnyProviderRunAsClaude` |
| ターンの期限 | `max(minimumTurnS = 300, plan.limits.turnTimeoutS)` 秒。下調べの子は `childTurnS = 300` 秒 | `Timeouts.minimumTurnS`・`childTurnS`、`TurnDeadline` | 未対応(値の固定テストなし) |
| 止まった答え | 答えを書き始めた後 `messageStall = 120` 秒 | `Timeouts.messageStall`、`ClaudeTurn.watchStream` | 模擬: `faults` の `stall` |
| 何も届かない | `streamIdle = 300` 秒で通信の失敗として扱う | `Timeouts.streamIdle` | 模擬: 同上 |
| 要求の送り直し(5xx・529・通信の失敗) | `requestRetries = 4`。待ちは 200ms から倍々、前後 10% のゆらぎ。`retry-after` があればそれ | `Timeouts.requestRetries`、`ClaudeTurn.backoff` | 模擬: `faults` の `http` |
| ストリームの送り直し(途中で切れた・`error` イベント。overloaded は除く) | `streamRetries = 2` | `Timeouts.streamRetries` | 模擬: `faults` の `drop`・`sse_error` |
| その他の送り直し | schema を指示文へ移す・thinking を外す・diagnostics を外す・App Attest の token を取り直す(1 回)。どれも回数に数えない | `ClaudeTurn.ask`(`ClaudeRequestReason` の `schema_retry`・`thinking_strip_retry`・`diagnostics_retry`・`auth_retry`) | 表 2 の 400・401 の行 |
| 出力の上限 | `max_tokens = 64_000` | `ClaudeRequestFormat.maxTokens` | 未対応 |
| thinking | `{"type": "adaptive", "display": "summarized"}`。effort は `output_config.effort`(`none`・`minimal` は `low`) | `ClaudeTurn.body`、`ClaudeRequestFormat.effort` | 単体: `ClaudeRequestFormatTests.testEffortMapsThePlanValuesToClaude` |
| tools | 端末の tool を `ClaudeToolNames` で `struis__exec_command` 等に直し、名前順。`tool_choice: auto`。`view_image` を足す | `NativeToolRouter.definitions(for:)`・`lookupDefinitions`、`ClaudeTurn.viewImageTool` | 単体: `testToolsAreFlattenedAndSortedByTheirClaudeNames` |
| 変換方式の版 | 2(既定)。`timeline_batch`・`timeline_grading`・`timeline_review`・`timeline_marks` は 4 | `ClaudeTranslation.current`・`tutor`・`tutorKinds`・`version(kind:)` | 単体: `testTimelineThreadsStartOnVersionFourAndMarkTheTailOnlyAfterATool` |
| cache の印 | system に 1h。末尾の TTL は `chat`・`thread_fork` が 1h、他は 5m。版 4 は system の 2 か所に 1h、末尾は道具の後の続きの要求だけ 5m | `ClaudeTranslation.tailCacheTTL`・`tutorSystem`・`marksTail` | 単体: `testTailTTLFollows…` |
| cache diagnostics | `diagnostics.previous_message_id` を送り、拒まれたら外す | `ClaudeTurn.body`、`ClaudeCacheDiagnosis` | 単体: `testCacheStateSeparates…` |
| 要求本文の上限 | 20 MiB。画像 1 枚は 5 MiB | `ClaudeUpstream.maxRequestBytes`、`ClaudeRequestFormat.maxImageBytes` | 単体: `testRequestSizeCap…`、`testImageBlocksAcceptOnlySupportedTypesWithinTheLimit` |
| URLSession | ephemeral、`timeoutIntervalForRequest = 600`、`timeoutIntervalForResource = 3_600`、`anthropic-version: 2023-06-01` | `ClaudeUpstream.init`・`request(data:route:)` | 単体: `ClaudeAppAttestTests.testUpstreamSendsTheBearerTokenToAnthropic` |
| 会話の履歴 | 台帳の `claude_conversations`・`claude_conversation_messages`(`ledger_events` の外。同期・書き出しなし)。画像は `conversation-images/<sha256>.<ext>` | `ClaudeConversationStore` | 単体: `testImagesAreStoredAsFilesAndRestoredForTheNextRequest`、`testStoppedTurnLeavesTheAbortMarkAndClosesOpenToolCalls` |
| 新しいスレッドへ移る条件 | 履歴が無い、または直近の入力が 244,800 トークン以上 | `ClaudeModelInfo.autoCompactTokenLimit`、`ClaudeTurn.openConversation`・`missingHistoryNote` | 単体: `testMissingHistoryContinues…` |
| 1 ターン内の要求回数(continuation / validation_repair の繰り返し) | 上限なし(期限で止まる) | `ClaudeTurn.loop`、`ClaudeRequestReason`(分類のみ) | 未対応(引き継ぎ 3.6) |

## この週に起きた 3 件がどの行で捕まったか

| 障害(引き継ぎ 2.2) | 捕まえる行 | その行があれば何が起きたか |
|---|---|---|
| Bundle ID が Anthropic Console に未登録で、prototype の最初のターンが `register HTTP 4xx` で落ちた | 表 1「サーバー側の検証で attestation が拒まれる(Console に Team ID + Bundle ID が無い)」 | 対応箇所は `Failure.requestFailed` だけで、確認の仕方が「実機、新しい variant ごと」。variant を増やす手順(引き継ぎ 6)に「Console 登録」が必須項目として入り、ビルド前に気づく。単体テストが無いので行は Issue になる |
| 1 要求 19 万トークン(当時の Codex の `apps` が既定 on で、MCP tool が全文で入った) | 当時の表 3(Codex の設定)。Codex を外した今は該当しない | 今の要求の tools は `NativeToolRouter` の定義だけ(表 3「tools」)。要求ごとの `prompt_total` は台帳の `requests[]` で見る |
| 入れ直し後、Keychain の鍵 ID が残り Secure Enclave の鍵が無く、`DCError.invalidInput(2)` で止まった | 表 1「`DCError.invalidInput`」「`DCError.invalidKey`」「鍵は再インストール・移行・復元で消える」 | 修正前は `generateAssertion` の DCError が NSError のまま失敗になり、鍵を作り直さなかった(対応箇所が **未対応**)。行の確認の仕方「同じ variant を削除→再インストール→最初のターン」が受け入れ台本に入る |

残っている未対応のうち、実機でしか起きないものは表 1 の `serverUnavailable`(機内モードで初回登録)。表 2 の 429 は模擬サーバーで再現できる。これらは Issue にして Phase 3.5(理由の表示)と 3.6(要求上限)に紐づける。

## 今回の記入で見つかった未対応(そのまま Issue の題名にする)

表の行から「未対応」だけを抜き出したもの。番号は優先順(実機で起きる順)。

1. 表 1「サーバー側の検証で attestation が拒まれる(Console に Team ID + Bundle ID が無い)」: `register` の非 2xx の単体テストが無い。variant 追加手順に Console 登録を必須化。
2. 表 2「429 `rate_limit_error`」: `ClaudeTurn.ask` は 429 を送り直さず、`retry-after` も 5xx の待ちにしか使わない。`retry-after` 分待って送り直すかの判断と、status ごとの扱いの単体テストが要る。
3. 表 2「エラー本文の `request_id` / `request-id` ヘッダ」: 台帳に残らない。`ClaudeRequestAttempt.finish` に 1 項目足せば済む。
4. 表 1「`DCError.serverUnavailable`」: Apple は同じ鍵で後で再試行と言うが、`attestKey` 失敗時は鍵 ID を保存しないので次回は新しい鍵になる。鍵の数が増えるだけで動作はするが、Apple の指針との差として記録。
5. 表 1「`isSupported == false`」「`unknownSystemFailure`」「`featureUnsupported`」: `Attestation` stub でそれぞれを注入する単体テストが無い。
6. 表 2「`pause_turn`」: 記録だけで続きを要求しない。server tool を使っていない今は起きないが、行として残す。
7. 表 2「最小キャッシュ長未満」: `cache_state: cold` と区別できない。短い要求(下調べの子など)の `cold` が期限切れか未達かを分けるには、`prompt_total` と最小長の比較を `ClaudeCacheDiagnosis.state` に足す。
8. 表 3「ターンの期限」「出力の上限」: `Timeouts` の既定値と `maxTokens` を固定する単体テストが無い。
9. 表 3「1 ターン内の要求回数」: 上限が無い(引き継ぎ 3.6)。

## 出どころの一覧(取得日 2026-10-17)

- Apple `DCError.Code`: https://developer.apple.com/documentation/devicecheck/dcerror-swift.struct/code(5 つ: `featureUnsupported`・`invalidInput`・`invalidKey`・`serverUnavailable`・`unknownSystemFailure`)
- Apple「Establishing your app's integrity」: https://developer.apple.com/documentation/devicecheck/establishing-your-app-s-integrity(`isSupported`、`serverUnavailable` だけ同じ鍵で再試行、再インストール・移行・復元で鍵が消える)
- Anthropic errors: https://platform.claude.com/docs/en/api/errors(400/401/402/403/404/409/413/429/500/504/529、`request_id`、長い要求は streaming)
- Anthropic prompt caching: https://platform.claude.com/docs/en/build-with-claude/prompt-caching(5m/1h、順序、breakpoint 4 つ、最小長、usage の内訳、無効化の表、料金倍率)
- Anthropic streaming: https://platform.claude.com/docs/en/build-with-claude/streaming(イベント型、`error` イベント、`ping`・未知の型、`message_delta.usage` は累積)
- 以前の表 3 は OpenAI Codex `rust-v0.153.4` のソースを出どころにしていた(Codex を外したので削除)。
