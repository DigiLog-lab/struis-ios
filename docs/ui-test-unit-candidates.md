# UI テストを単体テストに移す候補(提案、未承認)

- 作成: 2026-10-21
- 状態: 提案。移すかどうかは Tomochika が決める。決まるまで、どのテストも変えない。
- 根拠: Xcode Cloud の PR Gate 158 の1本ごとの時間(UI テスト56本、5台の複製で並列)と、各テストの中身。

## 結論

移しても、門の待ち時間はほとんど縮みません。全部移して約220秒(UI テストの合計1,852秒の12%)減りますが、門の待ち時間は一番遅い複製で決まります(158 では438秒)。減る分が複製に散れば約45秒、一番遅い複製に集まっても最大約110秒です。さらに、`WorkbookLongConversationUITests` は1クラスで210秒かかる必須の E2E なので、UI テストの部分はこれより短くなりません。門の時間の大半は、Xcode Cloud のテスト用マシンの準備と後処理です([xcode-cloud.md](xcode-cloud.md))。

移す理由があるのは、時間ではなく確かめ方です。下の候補は、判定の中身が論理(状態機械・保存・採点)で、単体テストの方が直接確かめられます。

## 候補

「分ける」は、論理を単体テストに移し、画面でしか分からない部分を短い UI テストとして残すものです。秒は PR Gate 158 での時間です。

| UI テスト | 秒 | 単体テストで確かめる対象 | すでにある単体テスト | 減る秒数 |
|---|---|---|---|---|
| `WorkbookSplitGradingUITests/testPhotosAddUpToOneSetResult` | 91 | `WorkbookMachine.applyGradingResult`・`captureView`、`WorkbookSetProgressSection.partialTitle`、`WorkbookSetProgressDTO.positionsText` | `WorkbookRulesTests.testSetCapturedInThreePhotosIsGradedAsOneSet`(途中の題名は失敗した一枚の分岐だけ) | 約41 |
| `WorkbookSplitGradingCloseSetUITests/testCloseSetWithFoundProblems` | 74 | `WorkbookMachine.closeSet` | `WorkbookRulesTests.testClosingWithMissingProblemsGradesWhatWasFound` | 約27 |
| `WorkbookSplitGradingBatchUITests/testBatchOfPhotosGradedAsOneAnswer` | 86 | `WorkbookStore.submitCapture(pages:context:)` に2ページ | 見つからない | 約5 |
| `ReplyTailUITests/testAdvanceAppearsWhileReadyReplyIsRecording` | 71 | 記録の途中の「先に進む」 | `ReplyTailQueueTests.testExampleReadyIsRecordedBeforeTheTailFinishes` | 約28 |
| `ReplyTailUITests/testQuestionSheetSendsWhileReplyIsRecording` | 60 | 記録の途中の送信の順番 | `ReplyTailQueueTests.testSendDuringPrivateTailQueuesWithoutStoppingTheRecord` | 約30 |
| `WorkbookSubunitLayoutUITests/testExampleAdvanceAppearsOnlyAfterModelMarksReady` | 43 | `WorkbookSubunitView.showsAdvance`、`LearnerText.extractWorkbookExampleReady` | `WorkbookSubunitLayoutTests.testAdvanceIsHiddenInExampleStageUntilModelMarksReady` ほか | 38〜43 |
| `WorkbookSubunitLayoutUITests/testSendingCollapsesExampleBar` | 20 | `WorkbookExampleBarState` | `WorkbookSubunitLayoutTests.testExampleBarCollapsesOnLearnerActivityAndReopensByTap` | 約18 |
| `ChatImmediateImageSendUITests/testTwoImagesPersistAfterRelaunch` | 34 | `ChatStore.send`・`storeAttachments` を、台帳を開き直して読む | 見つからない | 約12 |
| `WorkbookSubunitLayoutUITests/testUnitCardShowsCorrectOverNAndNothingForUntouched` | 9 | `WorkbookSubunitProgress` | `WorkbookSubunitLayoutTests` の単元カードの3本 | 約7 |
| `DeviceLedgerSettingsUITests/testExportLedgerAndUsageToggleDefaultOff` | 22 | `SettingsStore.exportLedger`、`LedgerArchive` | `LedgerTests.testArchiveExportImportRoundTrip`(使用量の既定オフは無い) | 約4 |
| `ConversationExportUITests/testCopyConversation` | 19 | 書き出しの文(今は `ChatView` のボタンの中にあり、関数になっていない) | 見つからない | 約2 |
| `DeviceRuntimeUITests/testRuntimeBootsAndDeviceCodeLoginStarts` | 68 | `DeviceRuntime.ensureRunning`、`CodexAccountRuntime.startDeviceLogin` | 実認証が要り門では skip | 0〜10(起動の時間は単体テストにも残る) |

分割採点の3クラスを、短い UI テスト1本(束ねて撮る → 途中の結果 → 撮り足し → 締める)にまとめると、合計251秒が約92秒になります。

## 移す対象ではないが、門に入れておくか決めること

| テスト | 秒 | 内容 |
|---|---|---|
| `ImmersionSceneChatUITests/testJourneyWalkthroughForRecording` | 通る時約84 | 録画用の通し。中身は同じクラスの2本と重なる |
| `striusUITestsLaunchTests/testLaunch` | 計44(4回) | 起動して画面写真を撮るだけで判定は無い。構成ごとに4回走る |
| `Issue10ScreenshotUITests` の2本 | 計88 | 目的は画面写真。判定の中身は単体テストと重なる |
| `WorkbookE2EFixesUITests/testSetCaptureOpensResultAndPassShowsImmediately` | 66 | 起動を2回している(約10秒) |
| `striusUITests/testExample` | 7 | 雛形のまま |

## 移さないもの

必須の E2E(`scripts/ci/ui-test-plan.json` の `pr`)と、画面でしか分からないもの(配置・重なり、ジェスチャー、スクロール、キーボード、カメラ、画面の移動、大きい文字)は UI テストのままにします。
