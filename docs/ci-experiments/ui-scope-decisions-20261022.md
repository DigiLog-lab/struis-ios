# Struis UIテストの取捨選択 — 2026-10-22

## 判断

日常のmerge判定に全UIを常時必須とはしない。守る挙動をunit・結合・必要な実画面操作に分け、変更が影響する検証を選ぶ。既存UI56件の全件について今回判断した。これは判断の保存であり、通常CIに適用した結果や平均10分を実測した結果ではない。

前の夜間比較は56件を回す高速化を主に測っており、依頼されていた取捨選択を完了していなかった。本書がその不足を埋める。従来レポートの36分51秒の全件直列構成を、日常merge構成の採用結論とはしない。

確認したアプリ/テストの元ソース: `d3fe8a59acffe7fe21f87941e6f9863047813e8e`。実験ブランチ親: `ada0edfa37f07b00e8bc94b2b7f40888e408866a`。通常CI/main/PR #39/配信に変更を加えない。追加macOS実行なし。

| 判断 | 件数 | 適用条件 |
|---|---:|---|
| 関連変更時だけ | 35 | 毎回必須を外し、下のrerun条件に影響する変更時に維持 |
| 代替完成後に置換 | 5 | 代替が動き、assertionの割当と故障検出比較が終わるまで元UIを関連変更時に維持 |
| merge判定から除外 | 2 | 機能の判定がない起動テンプレート。起動クラッシュの検出は含むため、既定起動の変更時には同じ起動構成の機能検証を選ぶ |
| 目視・録画用へ | 3 | 録画/画像の人の確認が必要なときに使う。自動の品質保証として計上しない |
| 環境を用意した専用検証 | 10 | 夜間は10件ともSkipped。検証に必要な環境を用意する。Passed扱いしない |
| 操作ツール・品質判定外 | 1 | 外部操作命令の代行。回帰テストの成功件数に含めない |

常時必須のUI一覧は空。各PRで実行UIが0本になる場合を認める。コード変更時のUnit/結合テストは当面全体を維持する（夜間は398件中369 Passed、29 Skipped）。論理だけの変更をUIで重ねて検証しない。共有の状態・形式・通知・操作の契約に影響した場合は、それを使う機能を選ぶ。

## 省略と置換の具体的な判断

- 分割採点の累積・途中締切・後からの提出・二重計上は既存WorkbookRulesTestsに寄せる。撮り足し/締切ボタンからStoreへの接続と表示は短いUIで残す。2つの長いUIの置換はその準備後。
- 記録中の追加送信・順序・中断なし・永続化は既存ReplyTailQueueTestsに寄せる。実画面で送信できることとready前後の進む操作を短い2つのUIにまとめる。現在の3本は準備が終わるまで関連変更で維持。
- 複数写真の削除/提出はUI固有なのでBatch UIを維持する。WorkbookStore.submitCapture(pages:)で全ページの枚数/順序/内容が保存され、採点側へ渡る結合テストが足りない。現状のunitだけで代替済みと扱わない。
- 長文会話は毎回必須から外す。長文描画・数式・scroll・メッセージ更新等の変更時には20回の実操作を維持する。
- 没頭の録画Journeyは前半をAskFromSceneThenReturnToSameCanvas、後半をExploreRequiresManipulationThenFullCycleCompletesが検証するので日常gateから外す。2workerでのslider欠落とJourney失敗の記録は消さず、関連するcycle検証の未解決事項として保持。
- Issue10の数式スクリーンショットとAdvanceBandは、名前が示す描画/遮蔽を自動判定していない。Passedからその品質が自動保証されたとは数えない。該当変更では画像の目視、または将来の自動画像/操作検証が必要。Issue10の個別問題の再撮影・一覧への復帰には固有のassertionがあるため、画像用という名前だけで外さない。

## 変更例ごとの対象

以下は条件を満たす変更例の確定した対象。自動の依存解析は未実装。複数の契約を変えたら対象を合併する。ファイル名だけで意味の変化を判定したことにはしない。

| 変更例 | UI本数 | 選ぶUI | 過去2回のtest bodyの合計秒 |
|---|---:|---|---:|
| 実験の説明文だけ。アプリ/テスト/fixture/設定/生成資産は同一。 | 0 | なし | 0 |
| WorkbookRulesの採点境界条件。DTO/action/stage/保存形式/画面への通知契約は変わらない。 | 0 | なし | 0 |
| WorkbookSubunitHeaderの開閉ジェスチャ・状態保持の変更。共通会話/デザインは変更なし。 | 2 | `WorkbookSubunitHeaderUITests/testHeaderCollapsesBySwipePersistsAndReopensByTap`、`WorkbookSubunitHeaderUITests/testHorizontalDragOnHeaderDoesNotToggle` | 35.543 |
| 背景記録と追加送信/ready通知の契約を変更。 | 3 | `ReplyTailUITests/testQuestionSheetSendsWhileReplyIsRecording`、`ReplyTailUITests/testAdvanceAppearsWhileReadyReplyIsRecording`、`WorkbookSubunitLayoutUITests/testExampleAdvanceAppearsOnlyAfterModelMarksReady` | 70.65 |
| 没頭シーンの候補・質問/復帰・介入と完走を変更。 | 3 | `ImmersionSceneChatUITests/testAskFromSceneThenReturnToSameCanvas`、`ImmersionSceneChatUITests/testChangeCandidateOpensCandidatePicker`、`ImmersionSceneChatUITests/testExploreRequiresManipulationThenFullCycleCompletes` | 53.765 |
| 会話のscroll/数式ジェスチャ/差分更新に影響する変更。 | 9 | `ChatScrollStabilityUITests/testConversationDoesNotJumpAfterTheFingerLifts`、`ChatScrollStabilityUITests/testDragStartingOnMathBubbleScrollsTheConversation`、`ChatScrollStabilityUITests/testFirstDragAfterOpeningFollowsTheFinger`、`ChatScrollStabilityUITests/testHorizontalSwipeInSubunitConversationStaysOnTheConversation`、`ChatScrollStabilityUITests/testOverflowingDisplayMathStillScrollsSideways`、`ChatScrollStabilityUITests/testReadingBackIsNotPulledWhenTheReplyArrives`、`WorkbookLongConversationUITests/testLongSubunitConversationDoesNotFreeze`、`striusUITests/testHorizontalSwipesKeepTheSingleChatPage`、`WorkbookSubunitLayoutUITests/testAdvanceScrollsToTheNewStageReply` | 452.295 |

秒数はoptimized-mock-warm 2回の各テスト本体時間の平均を足した参考値。選択後のxcodebuildコマンド時間ではなく、待ち行列・build・Simulator準備・テストプロセス起動・再実行を含まない。0 UIも平均10分達成の実測ではない。

profileの条件・Unit対象・拡大条件は隣のJSONのprofilesに保存。巨大なChatView.swiftには入力・添付・スクロール等が同居するため、そのファイルに触れたという理由だけで狭いprofileへ割り当てない。該当部分の依存/契約が読めなければ対象を確定する作業が必要。自動化する際はその部品を分割し、機能の境界とテスト対象を一致させる。

## 全56件の判断表

参照する条件には、該当する共有デザイン・資産・DTO・依存の接続の変更も含む。未登録のproduction pathや未割当のassertionを黙って省略しない。元のpath selectorでは30のproduction Swift pathが未対応だった。これは影響判定の不足であり、このJSONから依存グラフが完成したとは言えない。

| テスト | 判断 | 守る挙動・再実行する変更 | 理由/置換の条件 | mock-warm本体秒 |
|---|---|---|---|---:|
| `ChatCameraUITests/testCameraAndChatPreservation` | 関連変更時だけ | カメラ開閉/取消で既存会話・入力欄の位置と内容を保つ。変更: ChatCamera、カメラの共通表示、向き、添付入口、会話レイアウト | この操作・画面・接続に影響する変更時に実行する。無関係な変更では実行しない。 | 77.892 |
| `ChatCameraUITests/testCameraRotationAndReopening` | 関連変更時だけ | 回転後のpreview/shutter/cancelの位置・操作と再度開く動作。変更: ChatCamera、カメラの共通表示、向き、添付入口、会話レイアウト | この操作・画面・接続に影響する変更時に実行する。無関係な変更では実行しない。 | 62.058 |
| `ChatImmediateImageSendUITests/testCancelWhileCaptureIsFinishing` | 関連変更時だけ | 撮影完了より先の取消で遅れて添付が復活しない。変更: ChatCamera、添付公開のタイミング、ChatStoreの添付保存、送信・復元経路 | この操作・画面・接続に影響する変更時に実行する。無関係な変更では実行しない。 | 25.927 |
| `ChatImmediateImageSendUITests/testSendImmediatelyAfterCameraAttachment` | 関連変更時だけ | 撮影完了前に添付を公開せず、完了直後の送信で履歴へ反映する。変更: ChatCamera、添付公開のタイミング、ChatStoreの添付保存、送信・復元経路 | この操作・画面・接続に影響する変更時に実行する。無関係な変更では実行しない。 | 28.679 |
| `ChatImmediateImageSendUITests/testTwoImagesPersistAfterRelaunch` | 関連変更時だけ | 2枚の送信画像が会話に表示され、アプリ再起動後も残る。変更: ChatCamera、添付公開のタイミング、ChatStoreの添付保存、送信・復元経路 | ChatStore.send/storeAttachments→台帳を開き直す結合テストの不足を補える。ただし再起動画面の表示・画像の結線のUIは別に残す。現時点では関連変更時に現行UIを維持。 | 46.124 |
| `ChatPhysicalImageSendUITests/testPhysicalCameraImmediateSend` | 環境を用意した専用検証 | 実機カメラから実送信・再起動復元。変更: 実機カメラ、画像送信・認証・実runtime | この操作・画面・接続に影響する変更時に実行する。無関係な変更では実行しない。 条件: Test skipped - 実機の撮影・本番送信を明示的に許可した検証でのみ実行 | 0.125 |
| `ChatScrollStabilityUITests/testConversationDoesNotJumpAfterTheFingerLifts` | 関連変更時だけ | 指を離してから会話が2ptを超えて跳ばない。変更: 会話スクロール、数式の表示部品、メッセージ差分更新、共有レイアウト | この操作・画面・接続に影響する変更時に実行する。無関係な変更では実行しない。 | 69.526 |
| `ChatScrollStabilityUITests/testDragStartingOnMathBubbleScrollsTheConversation` | 関連変更時だけ | 数式の吹き出し上から縦ドラッグしても会話が動く。変更: 会話スクロール、数式の表示部品、メッセージ差分更新、共有レイアウト | この操作・画面・接続に影響する変更時に実行する。無関係な変更では実行しない。 | 38.721 |
| `ChatScrollStabilityUITests/testFirstDragAfterOpeningFollowsTheFinger` | 関連変更時だけ | 開いた直後の最初のドラッグから会話が動く。変更: 会話スクロール、数式の表示部品、メッセージ差分更新、共有レイアウト | この操作・画面・接続に影響する変更時に実行する。無関係な変更では実行しない。 | 22.636 |
| `ChatScrollStabilityUITests/testHorizontalSwipeInSubunitConversationStaysOnTheConversation` | 関連変更時だけ | 小単元の横操作で入力欄が横へずれず、旧分岐ページに入らない。変更: 会話スクロール、数式の表示部品、メッセージ差分更新、共有レイアウト | この操作・画面・接続に影響する変更時に実行する。無関係な変更では実行しない。 | 15.934 |
| `ChatScrollStabilityUITests/testOverflowingDisplayMathStillScrollsSideways` | 関連変更時だけ | 幅の大きい表示数式は横へスクロールできる。変更: 会話スクロール、数式の表示部品、メッセージ差分更新、共有レイアウト | この操作・画面・接続に影響する変更時に実行する。無関係な変更では実行しない。 | 32.259 |
| `ChatScrollStabilityUITests/testReadingBackIsNotPulledWhenTheReplyArrives` | 関連変更時だけ | 読み返し中の位置が応答完了で引き戻されない。変更: 会話スクロール、数式の表示部品、メッセージ差分更新、共有レイアウト | この操作・画面・接続に影響する変更時に実行する。無関係な変更では実行しない。 | 37.122 |
| `ChatTypingExperienceUITests/testJapaneseCandidateSelection` | 環境を用意した専用検証 | 日本語候補・複数行・送信後クリア・キーボード状態。変更: 入力部品・IME・キーボード・送信UI | この操作・画面・接続に影響する変更時に実行する。無関係な変更では実行しない。 条件: Test skipped | 0.193 |
| `ChatTypingExperienceUITests/testJapaneseMultilineAndSend` | 環境を用意した専用検証 | 日本語候補・複数行・送信後クリア・キーボード状態。変更: 入力部品・IME・キーボード・送信UI | この操作・画面・接続に影響する変更時に実行する。無関係な変更では実行しない。 条件: Test skipped - ローカル検証サーバーを使う入力UIテスト | 0.175 |
| `ConversationExportUITests/testCopyConversation` | 関連変更時だけ | 書き出し画面からコピーし入力欄に貼り付ける。変更: 会話書き出し、クリップボード、入力欄、関連ナビゲーション | この操作・画面・接続に影響する変更時に実行する。無関係な変更では実行しない。 | 23.004 |
| `DeviceChatUITests/testInterruptWithRealCodex` | 環境を用意した専用検証 | 実Codexを停止し、再送と再起動後の継続が成功する。変更: 質問導線、ChatStore、TurnCoordinator、応答整形、起動時の依存の接続 | この操作・画面・接続に影響する変更時に実行する。無関係な変更では実行しない。 条件: Test skipped - TEST_RUNNER_STRUIS_REAL_CODEX_AUTH が無い (実 Codex 検証は手動) | 0.133 |
| `DeviceChatUITests/testQuestionTurnWithMockModel` | 関連変更時だけ | 質問から応答まで接続され、私的ブロックが本文に漏れない。変更: 質問導線、ChatStore、TurnCoordinator、応答整形、起動時の依存の接続 | この操作・画面・接続に影響する変更時に実行する。無関係な変更では実行しない。 | 21.578 |
| `DeviceChatUITests/testQuestionTurnWithRealCodex` | 環境を用意した専用検証 | 質問から応答まで接続され、私的ブロックが本文に漏れない。変更: 質問導線、ChatStore、TurnCoordinator、応答整形、起動時の依存の接続 | この操作・画面・接続に影響する変更時に実行する。無関係な変更では実行しない。 条件: Test skipped - TEST_RUNNER_STRUIS_REAL_CODEX_AUTH が無い (実 Codex 検証は手動) | 0.15 |
| `DeviceChatUITests/testWorkbookProposalAndLookupWithRealCodex` | 環境を用意した専用検証 | 実Codexの単元提案カードから開始でき、保存済み内容を照会できる。変更: 質問導線、ChatStore、TurnCoordinator、応答整形、起動時の依存の接続 | この操作・画面・接続に影響する変更時に実行する。無関係な変更では実行しない。 条件: Test skipped - TEST_RUNNER_STRUIS_REAL_CODEX_AUTH が無い (実 Codex 検証は手動) | 0.11 |
| `DeviceLedgerSettingsUITests/testExportLedgerAndUsageToggleDefaultOff` | 関連変更時だけ | 使用量報告の既定オフ・非空台帳のimport禁止・exportと共有の導線。変更: 設定、UsageReport、台帳import/export、初期設定値 | Archive round-tripは既存LedgerTestsにあるが、使用量報告の既定オフと画面の操作は別の性質。既定値unitを補うまでは削除しない。 | 13.447 |
| `DeviceRuntimeUITests/testRuntimeBootsAndDeviceCodeLoginStarts` | 関連変更時だけ | 実ランタイム起動と接続開始を画面から確認する。変更: NativeRuntime、runtime準備・起動、アカウント接続、設定のruntime画面 | この操作・画面・接続に影響する変更時に実行する。無関係な変更では実行しない。 | 17.74 |
| `DeviceWorkbookUITests/testSetGenerationCaptureAndGradingOnDevice` | 関連変更時だけ | 問題生成から撮影確認・採点結果までの接続。変更: WorkbookStore、生成/採点Coordinator、撮影確認、問題・結果画面、関連DTO | この操作・画面・接続に影響する変更時に実行する。無関係な変更では実行しない。 | 27.306 |
| `DeviceWorkbookUITests/testSetGenerationCaptureAndGradingWithRealCodex` | 環境を用意した専用検証 | 問題生成から撮影確認・採点結果までの接続。変更: WorkbookStore、生成/採点Coordinator、撮影確認、問題・結果画面、関連DTO | この操作・画面・接続に影響する変更時に実行する。無関係な変更では実行しない。 条件: Test skipped - TEST_RUNNER_STRUIS_REAL_CODEX_AUTH が無い (実 Codex 検証は手動) | 0.093 |
| `E2EDriverUITests/testDrive` | 操作ツール・品質判定外 | 外部コマンドによる検証操作の代行。変更: 操作ツール自体の変更時/明示した手動操作 | この操作・画面・接続に影響する変更時に実行する。無関係な変更では実行しない。 | 0.081 |
| `ImmersionSceneChatUITests/testAskFromSceneThenReturnToSameCanvas` | 関連変更時だけ | シーン上で質問し、同じcanvasへ復帰してcomposerが残る。変更: ImmersionLab、シーンJSON/JS・WebView橋渡し、質問パネル、シーンへの入口 | この操作・画面・接続に影響する変更時に実行する。無関係な変更では実行しない。 | 18.604 |
| `ImmersionSceneChatUITests/testChangeCandidateOpensCandidatePicker` | 関連変更時だけ | 候補変更のボタンが実際に候補選択を開く。変更: ImmersionLab、シーンJSON/JS・WebView橋渡し、質問パネル、シーンへの入口 | この操作・画面・接続に影響する変更時に実行する。無関係な変更では実行しない。 | 12.836 |
| `ImmersionSceneChatUITests/testExploreRequiresManipulationThenFullCycleCompletes` | 関連変更時だけ | タップでは進めずslider介入で進み、転移と終了まで到達する。変更: ImmersionLab、シーンJSON/JS・WebView橋渡し、質問パネル、シーンへの入口 | 同一VM2workerの再測定でslider欠落によりFailed。成功した直列6試行とは分けて保持し、関連変更の判定対象から外さない。原因と並列実行の可否は未解決。 | 22.325 |
| `ImmersionSceneChatUITests/testJourneyWalkthroughForRecording` | 目視・録画用へ | 質問/復帰と、再起動後の介入から終了までを録画用に通す。変更: ImmersionLab、シーンJSON/JS・WebView橋渡し、質問パネル、シーンへの入口 | 前半はAskFromSceneThenReturnToSameCanvas、再起動後の後半はExploreRequiresManipulationThenFullCycleCompletesで検証。録画用sleepを含む。2workerでの失敗記録は保持し、専用のcycleテストでも起きたslider欠落は未解決として残す。 | 56.147 |
| `Issue10ScreenshotUITests/testProblemCaptureAndAllCorrectResult` | 関連変更時だけ | 個別問題を撮り直し結果から問題一覧へ戻る。変更: WorkbookProblemView、retry/return-to-setの導線、結果画面、撮影経路 | この操作・画面・接続に影響する変更時に実行する。無関係な変更では実行しない。 | 45.915 |
| `Issue10ScreenshotUITests/testReplyRendersMathRightAfterGeneration` | 目視・録画用へ | 背景記録中と応答完了後の画像を残す（数式自体は自動判定しない）。変更: WorkbookProblemView、retry/return-to-setの導線、結果画面、撮影経路 | 記録中/完了の状態をassertして画像を残すが、数式の描画自体をassertしていない。MathRenderingTestsはglyph等を検証する。生成直後の実画面の数式は目視のままなので、自動検証済みとは扱わない。 | 31.85 |
| `LearningProgressUITests/testInspectActualReplyProgress` | 環境を用意した専用検証 | 実返信から進行詳細・コピー・復帰を操作する。変更: LearningProgressSheet、実バックエンドの進行契約・認証 | この操作・画面・接続に影響する変更時に実行する。無関係な変更では実行しない。 条件: Test skipped - 実バックエンドURL・検証用認証・対象返信IDが必要です | 0.105 |
| `MinimumLoopE2ETests/testSendMessageAndReceiveAssistantReply` | 環境を用意した専用検証 | 実バックエンドへの認証・送信・応答完了。変更: 実バックエンドのAPI/認証・通信契約 | この操作・画面・接続に影響する変更時に実行する。無関係な変更では実行しない。 条件: Test skipped - STRUIS_E2E_ACCESS_TOKEN is required for the deployed-backend E2E | 0.089 |
| `ReplyTailUITests/testAdvanceAppearsWhileReadyReplyIsRecording` | 代替完成後に置換 | 背景記録中にも送信・段の移動を実画面から行える。変更: ChatStore、TurnCoordinator、記録中の状態通知、送信/進むの表示・操作 | この操作・画面・接続に影響する変更時に実行する。無関係な変更では実行しない。 条件: ready前後と背景記録中の状態を実状態fixtureで用意し、進むボタンを実際に操作する短いUIを残す / stage3遷移・記録完了・prefetchと永続化は既存結合テストで実行する | 20.351 |
| `ReplyTailUITests/testQuestionSheetSendsWhileRecordingWithRealCodex` | 環境を用意した専用検証 | 背景記録中にも送信・段の移動を実画面から行える。変更: ChatStore、TurnCoordinator、記録中の状態通知、送信/進むの表示・操作 | この操作・画面・接続に影響する変更時に実行する。無関係な変更では実行しない。 条件: Test skipped - TEST_RUNNER_STRUIS_REAL_CODEX_AUTH が無い (実 Codex 検証は手動) | 0.308 |
| `ReplyTailUITests/testQuestionSheetSendsWhileReplyIsRecording` | 代替完成後に置換 | 背景記録中にも送信・段の移動を実画面から行える。変更: ChatStore、TurnCoordinator、記録中の状態通知、送信/進むの表示・操作 | この操作・画面・接続に影響する変更時に実行する。無関係な変更では実行しない。 条件: 既存の制御可能なtail fixtureから送信可能・停止ボタンでない・入力が受け付けられるUIを残す / 順序・完了・中断なし・台帳保存の全assertionを既存結合テストで実行する | 25.452 |
| `UnitDeletionUITests/testLargeTextConfirmationAndCancel` | 関連変更時だけ | 大きな文字でも削除の確認を操作でき、取消で単元を保つ。変更: WorkbookHomeView、単元削除、確認ダイアログ、関連台帳イベント、文字サイズ/共有デザイン | この操作・画面・接続に影響する変更時に実行する。無関係な変更では実行しない。 | 14.746 |
| `UnitDeletionUITests/testLongPressCancelDeleteLastUnitAndEmptyState` | 関連変更時だけ | 長押し削除の取消と実行、最後の単元削除後の空状態。変更: WorkbookHomeView、単元削除、確認ダイアログ、関連台帳イベント、文字サイズ/共有デザイン | この操作・画面・接続に影響する変更時に実行する。無関係な変更では実行しない。 | 20.653 |
| `WorkbookE2EFixesUITests/testIntroductionStartsWithoutTypingAndExampleIsPinned` | 関連変更時だけ | 未入力で導入が始まり例題が固定され、開き直しても増殖しない。変更: WorkbookStore、kickoff、段遷移、単元/問題/結果画面、関連DTO・台帳イベント | この操作・画面・接続に影響する変更時に実行する。無関係な変更では実行しない。 | 15.787 |
| `WorkbookE2EFixesUITests/testSetCaptureOpensResultAndPassShowsImmediately` | 関連変更時だけ | 撮影後に結果が開き、演習の合格・直近n問・次の小単元が即表示される。変更: WorkbookStore、kickoff、段遷移、単元/問題/結果画面、関連DTO・台帳イベント | この操作・画面・接続に影響する変更時に実行する。無関係な変更では実行しない。 | 39.694 |
| `WorkbookHomeUITests/testRecentRowsStageAndCaptureButton` | 関連変更時だけ | ホームの最近の行・段表示・撮影ボタンの接続。変更: WorkbookHomeView、ホームprojection/refresh、行のナビゲーション・撮影入口 | この操作・画面・接続に影響する変更時に実行する。無関係な変更では実行しない。 | 10.121 |
| `WorkbookLongConversationUITests/testLongSubunitConversationDoesNotFreeze` | 関連変更時だけ | 長い会話で送信20回とスクロールができ、送信文が見える。変更: 長文の描画/メッセージ更新、ChatView、数式部品、スクロール、レイアウト、関連runtime/メモリ処理 | 常時必須から外す。40往復fixtureと送信/scroll20回の実操作に固有の検証価値があるため関連変更時は維持。MAX_MAIN_THREAD_STALL_MSは値の記録であり、2秒以下の自動assertとして数えない。 | 191.684 |
| `WorkbookOnboardingUITests/testOnboardingLeadsToFirstUnitAndIsNotShownAgain` | 関連変更時だけ | 初回設定から最初の単元に到達し再起動で繰り返さない。変更: OnboardingProfile/View、完了フラグ、単元生成とproposal refresh、起動・関連ナビゲーション | この操作・画面・接続に影響する変更時に実行する。無関係な変更では実行しない。 | 61.479 |
| `WorkbookSplitGradingBatchUITests/testBatchOfPhotosGradedAsOneAnswer` | 関連変更時だけ | 3枚撮影→1枚削除→残る2枚を提出・表示できる。変更: ChatCamera/WorkbookCaptureFlow、レビューと削除、WorkbookStore.submitCapture、採点へのpagePaths受け渡し | 写真の削除と提出枚数はUI固有。Store.submitCapture(pages:)→保存→採点への順序/枚数/画像内容の結合テストが未整備なので、このUIをunitで置き換えたと扱わない。関連変更時には現行の方法を残す。 | 37.982 |
| `WorkbookSplitGradingCloseSetUITests/testCloseSetWithFoundProblems` | 代替完成後に置換 | 途中締切・結果表示・後からの提出が接続される。変更: closeSet、WorkbookVerdictView、未提出表示、関連Store/DTO | この操作・画面・接続に影響する変更時に実行する。無関係な変更では実行しない。 条件: 実状態fixtureからcloseSetボタン→未提出/score/actionの反映を短いUIで残す / 追加提出の集計と二重計上防止は既存Rulesテストで実行する | 51.451 |
| `WorkbookSplitGradingUITests/testPhotosAddUpToOneSetResult` | 代替完成後に置換 | 途中の結果から撮り足し、同じセットを完成できる。変更: 分割採点、WorkbookVerdictView、撮り足し、関連Store/DTO | この操作・画面・接続に影響する変更時に実行する。無関係な変更では実行しない。 条件: partial/resultの文言・action一覧のprojectionテストを補う / 実状態fixtureから撮り足すボタン→カメラと採点結果の表示を短いUIで残す | 44.208 |
| `WorkbookSubunitHeaderUITests/testHeaderCollapsesBySwipePersistsAndReopensByTap` | 関連変更時だけ | 縦スワイプ/タップによる開閉と再起動をまたぐ保持。変更: WorkbookSubunitHeader、開閉状態の保存、ジェスチャ、共有デザイン/文字サイズ | この操作・画面・接続に影響する変更時に実行する。無関係な変更では実行しない。 | 23.213 |
| `WorkbookSubunitHeaderUITests/testHorizontalDragOnHeaderDoesNotToggle` | 関連変更時だけ | ヘッダーを横にドラッグしても開閉しない。変更: WorkbookSubunitHeader、開閉状態の保存、ジェスチャ、共有デザイン/文字サイズ | この操作・画面・接続に影響する変更時に実行する。無関係な変更では実行しない。 | 12.33 |
| `WorkbookSubunitLayoutUITests/testAdvanceBandDoesNotCoverConversation` | 目視・録画用へ | ボタン帯に吹き出しを重ねた画像を作る（遮蔽判定は目視）。変更: WorkbookSubunitView/Components、例題バー/進む/カード、キーボード、会話の追従、共有デザイン | 吹き出しをボタン帯に重ねた配置までassertする。隠れていないかはソースに目視と明記され、自動の遮蔽判定はない。該当レイアウト変更時に画像レビュー、または将来の画像差分/タップ検証を要求する。 | 10.903 |
| `WorkbookSubunitLayoutUITests/testAdvanceScrollsToTheNewStageReply` | 関連変更時だけ | 読み返し中から段を進めたとき新しい段の応答へ追従する。変更: WorkbookSubunitView/Components、例題バー/進む/カード、キーボード、会話の追従、共有デザイン | この操作・画面・接続に影響する変更時に実行する。無関係な変更では実行しない。 | 29.293 |
| `WorkbookSubunitLayoutUITests/testExampleAdvanceAppearsOnlyAfterModelMarksReady` | 代替完成後に置換 | ready前は進むを隠し、ready後は再訪しても表示され実際に進める。変更: WorkbookSubunitView/Components、例題バー/進む/カード、キーボード、会話の追従、共有デザイン | この操作・画面・接続に影響する変更時に実行する。無関係な変更では実行しない。 条件: ready前に非表示・ready後に表示と実際に進めることを上記の短いready UIに統合する / 私的ready blockが本文に出ない検証と開き直し後のready保持を代替側へ移す | 24.847 |
| `WorkbookSubunitLayoutUITests/testExampleStageBarsComposerAndFloatingAdvance` | 関連変更時だけ | 進捗/例題バーの配置・操作・保持とキーボード/進むボタンの干渉。変更: WorkbookSubunitView/Components、例題バー/進む/カード、キーボード、会話の追従、共有デザイン | ソフトキーボードが出ない場合はguardで後半をreturnするため、その実行ではキーボード後半のassertionsは未実行。1本Passedから全分岐確認済みとは言えない。 | 38.649 |
| `WorkbookSubunitLayoutUITests/testSendingCollapsesExampleBar` | 関連変更時だけ | 入力フォーカスと送信が例題バーの折り畳みに接続される。変更: WorkbookSubunitView/Components、例題バー/進む/カード、キーボード、会話の追従、共有デザイン | 既存state unitと重複しても、入力フォーカス/送信イベントが実Viewに接続される保証は固有。丸ごと削除しない。 | 19.221 |
| `WorkbookSubunitLayoutUITests/testUnitCardShowsCorrectOverNAndNothingForUntouched` | 関連変更時だけ | 単元カードの正解数/n・未着手非表示と小単元のマスへの導線。変更: WorkbookSubunitView/Components、例題バー/進む/カード、キーボード、会話の追従、共有デザイン | 数の計算は既存UnitCard3テストで確認済み。実カードのlabelと小単元tilesへの導線はこの短いUIで確認する。 | 8.866 |
| `striusUITests/testExample` | merge判定から除外 | 質問画面を横に動かしても旧ページへ遷移しない。変更: 質問シート、ChatView、横ジェスチャ、ナビゲーション | app.launchのみ。対応する機能UIが必要時に起動を含む。既定の起動条件そのものを変えた変更では専用起動検証を選ぶ。 条件: 既定起動条件を変える変更時は、同じ引数/環境の初期画面まで確かめる機能UIを対象に入れる。起動クラッシュ検出まで捨てない。 | 7.264 |
| `striusUITests/testHorizontalSwipesKeepTheSingleChatPage` | 関連変更時だけ | 質問画面を横に動かしても旧ページへ遷移しない。変更: 質問シート、ChatView、横ジェスチャ、ナビゲーション | この操作・画面・接続に影響する変更時に実行する。無関係な変更では実行しない。 | 15.12 |
| `striusUITestsLaunchTests/testLaunch` | merge判定から除外 | 起動時のスクリーンショット。変更: アプリ起動・Launch画面 | 起動して画像を添付するテンプレート。機能判定はない。複数UI構成の外観確認は必要時の目視資料として別に要求する。 条件: 既定起動条件を変える変更時は、同じ引数/環境の初期画面まで確かめる機能UIを対象に入れる。起動クラッシュ検出まで捨てない。 | 8.907 |

56件外の起動性能測定 `striusUITests/testLaunchPerformance` は既存の別枠測定を維持する。実験用のvariant注入probe2本は製品の回帰検証として数えない。

## 置換前に追加・確認するもの

1. 各元UIのassertionに対応するunit/結合/短いUIを記録する。5件のreplace_afterを、代替が未完成のまま省かない。
2. 既存の本物のWorkbookMachine/Store/Coordinator/台帳を使うfixtureを基本にし、画面に期待する値だけを直接書くfixtureで検証対象を迂回しない。
3. 2枚目破棄、追加送信で記録中断、早期締切、ready前のボタン表示の故障を意図的に入れ、短い構成でも検出できるか比較する。これはまだ未実施。既知の不具合を戻す比較も行い、見逃した検証を補う。
4. 再起動後の添付保存のStore結合テスト、usage既定オフの単体テスト、書き出し文の関数化/単体検証も追加候補。既存UI固有の操作を残す。

## 10分に向けた採用構成と未実装

日常gateの構成判断は「build + 全Unit/結合 + 影響した操作/画面だけのUI」。固定の長文・録画・全機能一巡は要求しない。自動選択、5件の代替、故障検出比較、選択後のend-to-end測定は未実装/未実施である。

mock-warm全件比較ではbuild+warm平均505秒、Unit command平均約71.7秒で、UI前でも約9分37秒。選択だけで平均10分を達成したとは言えない。次の実行時間測定は対象を選んだgateで行い、準備の共有/キャッシュ/必要なtest hostへの分割は別に測る。buildとSimulator準備の並行化が悪化した過去1試行を安易に再採用しない。

依存グラフ・実行時のテスト影響情報による自動選択・機能別test hostは未実装。selection-shadowは過去20変更と未対応pathの監査だけ。receiptは全入力が同一なdocs-only変更での再利用を検証したoffline prototypeだけであり、変更したアプリコードでの結果再利用は実装していない。

Unit 29 skip、UIの環境依存10 skip、操作ツール1 skip、ソフトキーボードなし時のUI後半returnは、検証できていない範囲として残す。直列6回の成功や各構成2回の計測から低い失敗率を保証しない。

## 根拠・結果リンク

- [元のアプリ/テストソース](https://github.com/DigiLog-lab/struis-ios/tree/d3fe8a59acffe7fe21f87941e6f9863047813e8e)
- [全件夜間比較](https://github.com/DigiLog-lab/struis-ios/actions/runs/39630297628)
- [2worker再測定と未解決失敗](https://github.com/DigiLog-lab/struis-ios/actions/runs/39653968167)
- [夜間全結果](overnight-final-20261022.md)
- [全件の判断・元ソース行・成功/skip・平均本体秒・実行条件・置換条件のJSON](ui-scope-decisions-20261022.json)

## 今回のファイル検証

元ソースのクラス/メソッドを列挙し、既存除外の起動性能1件を除く56件と夜間結果の56件が完全一致することを確認。56件すべての判断・参照ソース・観測結果・理由を記録し、代替として参照した既存unitメソッドの存在も確認した。変更例の対象から、除外/目視/操作ツールの項目が混入していないことを検査した。通常CIへの適用、選択範囲の実行、代替実装の動作確認は含まない。
