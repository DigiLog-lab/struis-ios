# PR ごとに回す UI テストの選び方(案)

Issue #22 の項目 6 と引き継ぎ(`docs/handoff-2026-10-17.md`)の 2.3 の **案** です。決めるのは人です。PR #24 がマージされた後、決まった内容を `scripts/ci/ui-test-plan.json` の `pr` と `paths` に入れます(この文書は設定ではありません。CI はこれを読みません)。

## 前提(PR #24 の `ui_test_plan.py` の動き)

- `pr`: PR で必ず実行するテストクラス。`pr` が無ければ PR でも全部実行する(今の動き)。
- `paths`: `{"変更ファイルの glob": [テストクラス, ...]}`。glob は `fnmatch` なので `*` は `/` もまたぐ。
- 「全部実行」の指定は無い。共通部分の変更で全部を回すには、全クラスを並べる必要がある。
- 変更した UI テストのファイル自身も、`paths` に書かなければ選ばれない。
- リリースブランチ(`release/*`)は常に全部。

## PR で必ず実行するクラス(`pr`)

### 当面(項目 6 の前)

学習の流れを通す既存のテストを含むクラスにします。

| 流れ | 今あるテスト | 所要(秒、#24 の実測値) |
|---|---|---|
| 単元作成 → 類題の採点・全問正解 → 次へ | `WorkbookE2EFixesUITests/testOnboardingLeadsToFirstUnitAndIsNotShownAgain`、`testSetCaptureOpensResultAndPassShowsImmediately`、`DeviceWorkbookUITests/testSetGenerationCaptureAndGradingOnDevice` | 126 + 100 + 66 |
| 質問シートでの会話と読み返し | `DeviceChatUITests/testQuestionTurnWithMockModel` | 41 |
| 誤答の解説とやり直し | **無い**(項目 6 で新しく書く) | — |

`pr` はクラス単位なので、`WorkbookE2EFixesUITests` の長い会話のテスト(240 秒)も一緒に走ります。3 台に分けると最も遅い組は約 4 分(長い会話の 1 件)です。

```json
"pr": ["DeviceChatUITests", "DeviceWorkbookUITests", "WorkbookE2EFixesUITests"]
```

### 項目 6 の後

E2E 3 本を 1 つのクラス(仮に `LearningFlowE2ETests`)にまとめ、`pr` をそれだけにします。

```json
"pr": ["LearningFlowE2ETests"]
```

## 変更ファイルとテストクラスの対応(`paths`)

考え方: 画面の部品を直したら、その部品を指で触る・描くテストのクラスを足す。どの画面も通る部分(起動・台帳・状態・デザイン・テストの共通部分)は全クラスを足す。

| 変更したファイル | 足すクラス |
|---|---|
| `strius/Features/Chat/ChatTimeline.swift`、`MessageBubble.swift`、数式(`NativeMathText`・`KaTeXMathText`・`MathTextLayout`・`MathSourceNormalizer`・`MathPlainText`・`StruisMarkedSpans`) | `ChatScrollStabilityUITests`、`WorkbookSubunitLayoutUITests`、`ReplyTailUITests`、`Issue10ScreenshotUITests` |
| `strius/Features/Chat/ChatCamera.swift`、`AttachmentIntake.swift` | `ChatCameraUITests`、`ChatImmediateImageSendUITests` |
| `strius/Features/Chat/ChatView.swift`、`ChatComposer.swift`、`ChatStore.swift` | `DeviceChatUITests`、`ReplyTailUITests`、`ChatImmediateImageSendUITests`、`ConversationExportUITests`、`striusUITests` |
| `strius/Features/Chat/LearningEpisode*`、`LearningFeed*`、`LearningProgressSheet.swift` | `ReplyTailUITests`、`ImmersionSceneChatUITests`、`striusUITests` |
| `strius/Features/ImmersionLab/**` | `ImmersionSceneChatUITests` |
| `strius/Features/Onboarding/**`、`strius/Features/Workbook/UnitCreation*`、`UnitCatalog.swift`、`WorkbookProposalCard.swift` | `WorkbookE2EFixesUITests` |
| `strius/Features/Workbook/WorkbookSubunit*`、`WorkbookExampleWait.swift`、`WorkbookQuestionScreen.swift` | `WorkbookSubunitHeaderUITests`、`WorkbookSubunitLayoutUITests`、`ReplyTailUITests`、`ChatScrollStabilityUITests` |
| `strius/Features/Workbook/` の採点まわり(`WorkbookCaptureFlow`・`WorkbookGradingStage`・`WorkbookAnswerRegions`・`WorkbookVerdictView`・`WorkbookSetView`・`WorkbookProblemView`・`WorkbookTriageView`)、`strius/Features/ProblemCatalog/**` | `WorkbookSplitGradingUITests`、`Issue10ScreenshotUITests` |
| `strius/Features/Workbook/WorkbookHomeView.swift`、`WorkbookUnitView.swift`、`WorkbookComponents.swift` | `WorkbookHomeUITests`、`UnitDeletionUITests`、`WorkbookSubunitLayoutUITests` |
| `strius/Features/Workbook/WorkbookStore.swift` | `Workbook*` の全クラス |
| `strius/Features/Settings/**` | `DeviceLedgerSettingsUITests`、`DeviceRuntimeUITests` |
| `strius/Runtime/**`、`NativeRuntime/**` | `DeviceRuntimeUITests`、`DeviceChatUITests`、`ReplyTailUITests` |
| `strius/Ledger/**` | `DeviceLedgerSettingsUITests`、`ChatImmediateImageSendUITests`、`UnitDeletionUITests` |
| `strius/App/**`、`strius/striusApp.swift`、`strius/State/**`、`strius/Engine/**`、`strius/Design/**`、`strius/DTO/**`、`strius.xcodeproj/**`、`striusUITests/UITestSupport.swift` | 全クラス |
| `striusUITests/<クラス名>.swift` | そのクラス |

`pr` のクラス(上の 3 つ)は対応に書かなくても毎回走るので、表からは省いています。

### 設定に入れる形

```json
{
  "shards": 3,
  "pr": ["DeviceChatUITests", "DeviceWorkbookUITests", "WorkbookE2EFixesUITests"],
  "paths": {
    "strius/Features/Chat/ChatTimeline.swift": ["ChatScrollStabilityUITests", "WorkbookSubunitLayoutUITests", "ReplyTailUITests", "Issue10ScreenshotUITests"],
    "strius/Features/Chat/MessageBubble.swift": ["ChatScrollStabilityUITests", "WorkbookSubunitLayoutUITests", "ReplyTailUITests", "Issue10ScreenshotUITests"],
    "strius/Features/Chat/*Math*.swift": ["ChatScrollStabilityUITests", "WorkbookSubunitLayoutUITests", "ReplyTailUITests", "Issue10ScreenshotUITests"],
    "strius/Features/Chat/StruisMarkedSpans.swift": ["ChatScrollStabilityUITests", "WorkbookSubunitLayoutUITests", "ReplyTailUITests", "Issue10ScreenshotUITests"],
    "strius/Features/Chat/ChatCamera.swift": ["ChatCameraUITests", "ChatImmediateImageSendUITests"],
    "strius/Features/Chat/AttachmentIntake.swift": ["ChatCameraUITests", "ChatImmediateImageSendUITests"],
    "strius/Features/Chat/ChatView.swift": ["ReplyTailUITests", "ChatImmediateImageSendUITests", "ConversationExportUITests", "striusUITests"],
    "strius/Features/Chat/ChatComposer.swift": ["ReplyTailUITests", "ChatImmediateImageSendUITests", "ConversationExportUITests", "striusUITests"],
    "strius/Features/Chat/ChatStore.swift": ["ReplyTailUITests", "ChatImmediateImageSendUITests", "ConversationExportUITests", "striusUITests"],
    "strius/Features/Chat/Learning*": ["ReplyTailUITests", "ImmersionSceneChatUITests", "striusUITests"],
    "strius/Features/ImmersionLab/*": ["ImmersionSceneChatUITests"],
    "strius/Features/Workbook/WorkbookSubunit*": ["WorkbookSubunitHeaderUITests", "WorkbookSubunitLayoutUITests", "ReplyTailUITests", "ChatScrollStabilityUITests"],
    "strius/Features/Workbook/WorkbookExampleWait.swift": ["WorkbookSubunitHeaderUITests", "WorkbookSubunitLayoutUITests", "ReplyTailUITests", "ChatScrollStabilityUITests"],
    "strius/Features/Workbook/WorkbookQuestionScreen.swift": ["WorkbookSubunitHeaderUITests", "WorkbookSubunitLayoutUITests", "ReplyTailUITests", "ChatScrollStabilityUITests"],
    "strius/Features/Workbook/WorkbookCaptureFlow.swift": ["WorkbookSplitGradingUITests", "Issue10ScreenshotUITests"],
    "strius/Features/Workbook/WorkbookGradingStage.swift": ["WorkbookSplitGradingUITests", "Issue10ScreenshotUITests"],
    "strius/Features/Workbook/WorkbookAnswerRegions.swift": ["WorkbookSplitGradingUITests", "Issue10ScreenshotUITests"],
    "strius/Features/Workbook/WorkbookVerdictView.swift": ["WorkbookSplitGradingUITests", "Issue10ScreenshotUITests"],
    "strius/Features/Workbook/WorkbookSetView.swift": ["WorkbookSplitGradingUITests", "Issue10ScreenshotUITests"],
    "strius/Features/Workbook/WorkbookProblemView.swift": ["WorkbookSplitGradingUITests", "Issue10ScreenshotUITests"],
    "strius/Features/Workbook/WorkbookTriageView.swift": ["WorkbookSplitGradingUITests", "Issue10ScreenshotUITests"],
    "strius/Features/ProblemCatalog/*": ["WorkbookSplitGradingUITests", "Issue10ScreenshotUITests"],
    "strius/Features/Workbook/WorkbookHomeView.swift": ["WorkbookHomeUITests", "UnitDeletionUITests", "WorkbookSubunitLayoutUITests"],
    "strius/Features/Workbook/WorkbookUnitView.swift": ["WorkbookHomeUITests", "UnitDeletionUITests", "WorkbookSubunitLayoutUITests"],
    "strius/Features/Workbook/WorkbookComponents.swift": ["WorkbookHomeUITests", "UnitDeletionUITests", "WorkbookSubunitLayoutUITests"],
    "strius/Features/Workbook/WorkbookStore.swift": ["WorkbookHomeUITests", "WorkbookSplitGradingUITests", "WorkbookSubunitHeaderUITests", "WorkbookSubunitLayoutUITests"],
    "strius/Features/Settings/*": ["DeviceLedgerSettingsUITests", "DeviceRuntimeUITests"],
    "strius/Runtime/*": ["DeviceRuntimeUITests", "ReplyTailUITests"],
    "NativeRuntime/*": ["DeviceRuntimeUITests", "ReplyTailUITests"],
    "strius/Ledger/*": ["DeviceLedgerSettingsUITests", "ChatImmediateImageSendUITests", "UnitDeletionUITests"],
    "strius/App/*": ["ALL"],
    "strius/striusApp.swift": ["ALL"],
    "strius/State/*": ["ALL"],
    "strius/Engine/*": ["ALL"],
    "strius/Design/*": ["ALL"],
    "strius/DTO/*": ["ALL"],
    "strius.xcodeproj/*": ["ALL"],
    "striusUITests/UITestSupport.swift": ["ALL"],
    "striusUITests/ChatCameraUITests.swift": ["ChatCameraUITests"]
  }
}
```

- `"ALL"` は今の `ui_test_plan.py` には無い指定です。ここでは「全クラスを並べる」の略として書いています。入れ方は 2 つ: (a) 設定に全クラスを並べる(クラスが増えるたびに足す必要がある)、(b) `ui_test_plan.py` に `"ALL"` を足す(`scripts/ci/` の変更なので人が行う)。(b) を勧めます。
- `striusUITests/<クラス名>.swift` は 1 行ずつ書くか、(b) と同じく「変更した UI テストのファイルのクラスは足す」を `ui_test_plan.py` に入れるかです。これも後者を勧めます。上の JSON では例として 1 行だけ書いています。

## この案での UI テストの時間(見積もり)

上の JSON(`"ALL"` は全 24 クラスに展開)を PR #24 の `ui_test_plan.py --matrix --tier pr` に、#24 の実測値(`durations`)と一緒に渡した結果です。ビルドと Simulator の準備は含みません。

| PR で変更したファイル | 選ばれる UI テスト | 最も遅い組(3 台) |
|---|---|---|
| `docs/` だけ | 10 件(`pr` の 3 クラス) | 約 4.0 分 |
| `strius/Features/Workbook/WorkbookStore.swift` | 22 件 | 約 8.0 分 |
| `strius/Features/Chat/NativeMathText.swift` | 27 件 | 約 11.8 分 |
| `strius/State/` など共通部分 | 57 件(全部) | 約 18.6 分 |

共通部分を変えた PR は、ビルドを足すと 20 分に収まりません。PR ごとの CI を 20 分にするのは、項目 4(起動の回数を減らす)と項目 5(画面が要らない確認を単体テストへ移す)で全部入りが縮んでからになります。

## 決めてほしいこと

1. 当面の `pr` を上の 3 クラスにするか(長い会話の 240 秒を含みます)。
2. `"ALL"` と「変更したテストのファイル自身」を `ui_test_plan.py` に足すか、設定に並べるか。
3. 全部入りを回す場所: `release/*` へのマージ時だけか、加えて 1 日 1 回 main でも回すか(引き継ぎ 2.3)。
