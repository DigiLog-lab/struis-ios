# Xcode Cloud のテストプランと実測

方針は [verification-and-delivery-policy.md](verification-and-delivery-policy.md)、制御と権限は [agent-gate.md](agent-gate.md)。

## workflow

| 名前 | ID | scheme | 内容 |
|---|---|---|---|
| PR Gate | `FD7B155C-3973-4DA5-A0A1-A6886411C5D3` | `StruisPRGate` | TEST(必須)。手動開始、Clean OFF、固定の iPhone 16・最新 iOS |
| Release | `32273285-7cf2-44cf-8e31-cc0385650439` | `StruisRelease` | TEST と ARCHIVE(必須)、post-action で内部 TestFlight の staging グループへ配る。手動開始、Clean OFF |

旧リポジトリのパス(`ios/strius/strius.xcodeproj`)を指す `Hyotan Native …` の4つは、手動起動だけで勝手には動かない。App Store Connect のアプリ ID は `6771995650`。

起動するのは、Ready の門の制御ジョブと、`repository_dispatch` の `xcode-cloud`(依頼に応じた Release / PR Gate)だけ(`scripts/agent/gate.py`、`cloud_dispatch.py`)。

## scheme とテストプラン

| 用途 | テストプラン | 単体テスト | UI テスト |
|---|---|---|---|
| 門 | `TestPlans/PRGate.xctestplan` | 全部 | E2E + 変更に関係するクラスから、除外表の分だけを除く。クラスを単位に並列 |
| リリース | `TestPlans/Release.xctestplan` | 全部 | 全部。直列 |

`ci_post_clone.sh` は scheme 名で用途を判断し、clone の後に main との差分からテストプランを作り直す(`scripts/ci/xcode_test_plan.py`)。差分が取れない時は、門で実行できる UI テスト全部に広げる。対象が空の時や、除外表に削除済み・重複したテストがある時は止める。チェックイン済みのプランは差分が取れない時と同じ広い対象で、UI テストを追加・改名した時は次で更新する(テストが更新漏れを検出する)。

```sh
python3 scripts/ci/xcode_test_plan.py --tier pr --output TestPlans/PRGate.xctestplan
python3 scripts/ci/xcode_test_plan.py --tier full --output TestPlans/Release.xctestplan
```

### 門の除外表

`scripts/ci/xcode-cloud-exclusions.json` は `striusUITests/testLaunchPerformance` だけ。起動時間を測る性能テストで、門では UI テストを並列に流すので値が意味を持たないため。Release と手元検証では直列で流す。

2026-10-20 の版ではカメラ画面を開く13本を「Xcode Cloud の simulator ではカメラが使えない」(旧リポジトリの記録)として除いていた。2026-10-21 に Release 154 のテスト結果を App Store Connect の API で読むと、13本のうち11本が Xcode Cloud で成功し、2本は既存の skip(実機の撮影、実 Codex)だった。simulator ではテスト用の紙の画像を使うので、カメラのテストも門に入れる。

### 並列とクラスの分け方

Xcode の並列テストはクラスを単位にシミュレーターの複製へ配る(Xcode Cloud は `-maximum-parallel-testing-workers 8` で起動する)。1つのクラスに長いテストを詰めると、そのクラスの合計が門全体の下限になる。テストの中身と判定は変えずに、入れ物のクラスだけを分けた。

| 元のクラス(Release 154 の合計) | 分けた後 |
|---|---|
| `WorkbookE2EFixesUITests`(303秒) | `WorkbookE2EFixesUITests`(導入14秒+リザルト43秒)、`WorkbookLongConversationUITests`(20往復187秒)、`WorkbookOnboardingUITests`(59秒) |
| `WorkbookSplitGradingUITests`(188秒) | `WorkbookSplitGradingUITests`(64秒)、`WorkbookSplitGradingCloseSetUITests`(70秒)、`WorkbookSplitGradingBatchUITests`(54秒) |

共通の起動と導線は、テストを持たない入れ物のクラス(`WorkbookE2EUITestCase`、`WorkbookSplitGradingUITestCase`)に置いた。`ui_test_plan.py` は、変更した UI テストのファイルに書かれたクラスとその子クラスをすべて選ぶ。

## native の生成物

Xcode Cloud は、Clean にしなくても、カスタムの Rust の出力を次のビルドに持ち越さなかった(PR Gate 153 の終了時 3,941,748 KiB → 156 の開始時 0 KiB)。そこで、GitHub の `agent-native-cache.yml` が作る生成物(`NativeRuntime/Vendor`・`PythonPackages`・`PackageCache`・`.build`、両 SDK)を、GitHub の Release `native-runtime` の asset として公開し、PR Gate はダウンロードして使う(`scripts/ci/native_prebuilt.py`)。Release(TestFlight)は使わずに必ずソースから作る。asset と `.sha256` は `contents: write` を持つジョブ(エージェントの worker を含む)が置き換えられるので、配信するビルドには入れない。

- asset の名前は、追跡している `NativeRuntime/` の入力(Actions cache のキーと同じ除外)の SHA-256 から作るキー。
- `ci_post_clone.sh` は、PR Gate で asset と `.sha256` を取得し、SHA-256 を確かめ、一時フォルダに全部を展開できた時だけ置き換える。ビルドホストの automake を指す絶対パスのリンク(`dash-source/missing`)は作らない。公開されていない入力なら、今までどおり Rust から作る。
- 公開は main の `agent-native-cache.yml` が行う(`contents: write`)。`repository_dispatch` の `native-runtime` でも起動できる。新しい3つのキーだけを残す。
- 2026-10-21 に、main の cache から現在のキー(`v1-b0e2b14c4beb4ccaf3249749ba4a5adc9026d606`、約504MB)を公開し、展開と内容を確かめた。

## UI テストの計測

アプリは DEBUG・simulator・固定データの時だけ、起動の各段階(`init-start`、`init-end`、`root-appear`、`root-idle`、プロセスの起動からの経過)と、メインスレッドの250ms以上の止まりを、シミュレーターごとのファイルに時刻付きで書く(`UITestDiagnostics`)。UI テストのバンドルの主クラス `UITestDiagnosticsObserver` がテストごとに読み、xcodebuild のログへ次の形で書く。テストの操作・判定・待ちには触れない。

```
UI_DIAGNOSTICS test=<Class/method> max_stall_ms=… stalls_over_1s=… stall_total_ms=… launch=root-appear@t=…s(exec+…ms),…
UI_DIAGNOSTICS_STALL test=<Class/method> t=<テスト開始からの秒>s ms=…   (1秒以上。失敗したテストは250ms以上)
```

`t=` は XCUITest の操作の記録(`t = 12.34s Checking …`)と同じ物差しなので、要素の確認が十数秒返らない場面に、アプリのメインスレッドの止まりが重なっているかを突き合わせられる。

## 実測

| 実行 | 内容 | 結果 |
|---|---|---|
| PR Gate 153・156(`534d41f`) | UI テスト44本を直列、native を毎回作る | 成功、44分16秒・44分23秒。テストの実行29分36秒、post-clone 7分04秒(native 6分01秒)、テスト用のビルド1分28秒 |
| Release 154・155(`534d41f`) | 全57本を直列、archive | 成功。155 は TEST 57分45秒、ARCHIVE 36分2秒、内部 TestFlight 配信 `1.0 (155)` |
| PR Gate 158(`f5278ae`) | UI テスト56本をクラスごとに並列、native は公開物 | 赤、35分17秒。下の「PR Gate 158」 |
| PR Gate 159(`b7d95e7`) | 158 の没頭シーンの入口を直した後 | 赤、33分5秒。`ImmersionSceneChatUITests` は4本とも成功。`ChatCameraUITests/testCameraRotationAndReopening` が落ちた(下の「PR Gate 159」) |
| PR Gate 160(`31f0771`) | 159 の回転の確認を直した後 | 赤、37分30秒。`ChatCameraUITests` は成功。`ImmersionSceneChatUITests/testExploreRequiresManipulationThenFullCycleCompletes` が落ちた(下の「PR Gate 160」) |
| PR Gate 161(`11449c1`) | 160 の押し方を直した後 | 成功、44分12秒。native の取得が途中で切れてソースから作り(ビルド9.2分)、成功でも診断情報を600秒待った(下の「PR Gate 161〜163」) |
| PR Gate 162(`05b91b4`) | 診断情報の待ちをやめ、アプリの標準エラーへ流れる XCTest のログを捨てた後 | 赤、22分36秒。標準エラーの付け替えの誤りでアプリが落ちた |
| PR Gate 163(`d27d197`) | 162 の誤りと native の取得を直した後 | 赤、22分26秒。落ちたのは `WorkbookSubunitLayoutUITests/testAdvanceBandDoesNotCoverConversation` の1本(テストの準備の動かし方。下の「PR Gate 161〜163」) |

Xcode Cloud での画面録画の開始・終了は1回0.03〜0.05秒で、時間の原因ではなかった(PR Gate 156 の結果の束)。

### 門の時間の内訳(PR Gate 158〜163)

各段階の境目は、ビルド用のマシンの `ci_post_xcodebuild.sh` の時刻、テスト用のマシンの xcodebuild の開始と `Testing started completed`、テスト用のマシンの `ci_post_xcodebuild.sh` の時刻、App Store Connect の終了時刻。単位は分。

| 実行 | 合計 | ビルド | 受け渡し | xcodebuild | 後処理の開始まで | 後処理 | 結果の束 |
|---|---|---|---|---|---|---|---|
| 158 | 35.3 | 3.4 | 2.6 | 19.9 | 1.4 | 8.0 | 261MB |
| 159 | 33.1 | 3.5 | 2.5 | 19.8 | 1.6 | 5.7 | 272MB |
| 160 | 37.5 | 9.5 | 2.7 | 20.4 | 1.3 | 3.6 | 268MB |
| 161 | 44.2 | 9.2 | 2.6 | 19.7 | 1.4 | 11.3 | 254MB |
| 162 | 22.6 | 3.5 | 2.7 | 9.9 | 1.5 | 5.1 | 99MB |
| 163 | 22.4 | 3.4 | 2.6 | 9.9 | 1.4 | 5.1 | 59MB |

- 158〜161 の xcodebuild には、診断情報の取得の600秒の待ちが入っている(成功した 161 にも)。162 から `diagnosticCollectionPolicy: Never` で無くなった。
- テスト以外の段階(ビルド・受け渡し・後処理の開始まで・後処理)だけで、毎回11〜19分かかる。Xcode Cloud の後処理は3.6〜11.3分で、結果の束の大きさとは関係なくばらつく。TEST action のままでは、テストを0本にしても門は10分を切れない。
- ビルド用のマシンは12コア・メモリ64GB(`ci_post_clone.sh` の `sysctl`)。テスト用のビルドは、ビルド用のマシンにある iPhone 16 のシミュレーターの ID に向けて行われている。
- 163 の 9.9分の内訳は、単体テストと複製の準備が約1.4分、UI テストが約8.5分(最初の起動から最後のテストの終わりまで)。

### PR Gate 161〜163

- 161 は native の公開物(約504MB)の取得が途中で切れ(`IncompleteRead`)、ソースから6分かけて作り直した。切れたら `Range` で続きから取り直すようにした(4回まで)。
- アプリの標準エラーには、Xcode が設定する `OS_ACTIVITY_DT_MODE=YES` によって XCTest のアクセシビリティのログが流れ、アプリ1回の起動で25〜127MBになっていた。UI テストの時だけ、アプリの標準エラーを `/dev/null` へ付け替える(`UITestDiagnostics.start`)。デバッガーが付いている時と `STRUIS_KEEP_STDERR=1` の時は付け替えない。結果の束は 254MB → 59MB になったが、UI テストの時間(合計約1,800秒)は変わらず、Xcode Cloud の後処理の時間も結果の束の大きさとは関係がなかった(上の表)。
- 162 は付け替えに `freopen` を使い、新しい先を開けなかった時に番号2を閉じたままにして、`FileHandle.standardError` への書き込みでアプリが落ちた。番号2は閉じず、`/dev/null` を `dup2` で付け替え、開けない時は読んで捨てるパイプにつなぐ。163 ではアプリは落ちていない。
- 163 で落ちた `testAdvanceBandDoesNotCoverConversation` は、吹き出しの文字が「先に進む」の段の上端をまたぐ位置まで、画面の2%ずつ12回ドラッグして会話を戻す準備で、一度もまたがなかった。指を離す時の速さで1回ごとの動きが揃わず、文字の間の余白を飛び越えた。段の上端にいちばん近い文字までの距離を測り、その分だけ指を止めてから離すドラッグで動かして、測り直すようにした。判定は変えていない。

### テストの中身の時間(PR Gate 161)

UI テスト56本・合計1,828秒(緑)を、XCUITest の操作の記録で分けた。

| 内容 | 秒 | 扱い |
|---|---|---|
| アプリの起動(50回) | 431 | 必要(テストごとに状態を作り直す)。うち前のアプリの終了が145秒で、並列の時だけ最大18秒かかる(直列の 156 では1回1.2秒) |
| テストの中の固定の待ち | 177 | 大半は観察の時間(`ChatScrollStabilityUITests` の「指を離した後に動かないか」34秒、回転、録画) |
| `WorkbookLongConversationUITests` | 210 | 必要(20往復の送信とスクロール。1往復の6回の操作に約10秒) |
| 2つの条件を順に待ち、出ない方を毎回使い切る | 36 | 直した(同時に待つ。`XCUIApplication.anyAppears`) |
| 偽カメラの撮影の完了までの3秒(問題集の撮影14回) | 約43 | 直した(撮影の途中で何もしないテストは0.5秒。途中で操作する `ChatImmediateImageSendUITests` は今のまま) |
| 起動してから環境を足し、終了して起動し直す | 約10 | 直した(`testSetCaptureOpensResultAndPassShowsImmediately` を1回の起動に) |
| 偽の記録(40秒)の残りを待つ | 約33 | 未対応(`ReplyTailUITests/testQuestionSheetSendsWhileReplyIsRecording` は22秒で確かめ終わる) |
| 判定の無いテスト | 62 | 未決定(`striusUITestsLaunchTests/testLaunch` を構成ごとに4回、雛形の `testExample`) |
| 中身が重なるテスト | 55 | 未決定(録画用の `testJourneyWalkthroughForRecording`) |

### PR Gate 158

- post-clone は59秒(native の取得と展開27秒、`STRUIS_NATIVE_SOURCE source=prebuilt`)。テスト用のビルドは58秒。
- Xcode Cloud は UI テストを5台の複製に配った(8台ではない)。複製ごとの実行時間の合計は308〜438秒で、UI テストの部分は約7分半だった。1本ごとの時間は直列の時より長い(`WorkbookOnboardingUITests` 59秒 → 103秒など)。
- テストが失敗すると、xcodebuild はシミュレーターの診断情報の取得を600秒待って時間切れになった(`Failure collecting diagnostics from simulator: Timed out after 600.0 seconds`)。赤の門は、この10分だけ長くなる。
- 落ちたのは `ImmersionSceneChatUITests` の3本。アプリは応答していた(メインスレッドの止まりは最大0.68秒)が、「質問」シートのツールバーに没頭シーンの入口が出なかった。入口は候補の取得の後に出る。固定データの時も本番のサーバー(`/v1/immersion-lab/scenes`)に先に問い合わせ、失敗した時だけ同梱のシーンを使っていた。直列の実行(Cloud の154・156、GitHub)では入口は1〜2秒で出ている。固定データでは同梱のシーンだけを使うように直した(`ChatView.loadSceneCandidates`)。
- アプリのメインスレッドの1秒以上の止まりは、56本で12回・計13秒だけだった。5秒以上の操作の間隔39回(計423秒)は、どれもアプリの止まりと重ならず、多くはアプリの起動(15回・計204秒)と終了だった。

### PR Gate 159

- post-clone 59秒、テスト用のビルド59秒、テスト用のマシンの準備約3分、UI テストは一番遅い複製で487秒。失敗の後の診断情報の待ち600秒、Xcode Cloud の後処理約7分。
- `testCameraRotationAndReopening` は、最後に縦に戻した0.5秒後に「添付」を押せるかをすぐ確かめて落ちた(158 では同じ判定が通った)。同じテストの他の回転の確認は、回転が終わるまで8秒まで待っている。最後の確認も同じく回転の終わりを待つようにした。判定(縦に戻った後に「添付」を押せる)は変えていない。

### PR Gate 160

- `testExploreRequiresManipulationThenFullCycleCompletes`(158・159 では成功)は、境界の段に切り替わった0.4秒後に「今日はここまで」を押したが、画面が変わらなかった(押した後の要素の木でも境界の段のまま。アプリのメインスレッドの止まりは最大0.91秒)。同じ流れを録画用のテストは2秒ずつ間をあけて押していて、どの実行でも通っている。段の切り替えで動くボタンを、枠が止まってから押すようにした(`XCUIElement.tapWhenSettled`)。判定は変えていない。
- 失敗したテストは、250ms以上の止まりも時刻付きでログに出すようにした(次に同じ形で落ちた時に、押した時刻と突き合わせるため)。

### GitHub の runner との違い

同じ HEAD の GitHub の iOS 検証(run 39538292315、3コアの runner、UI テスト57本)では、アプリのメインスレッドの1秒以上の止まりが130回・計279秒あった。そのうち81回・計202秒は、XCUITest が要素の木を取りに行っている最中に始まっていた(入力の直後のアプリの処理は11回・計18秒)。起動から `App.init` までの時間は中央値4.9秒(Cloud は3.2秒)。この run では `ReplyTailUITests/testAdvanceAppearsWhileReadyReplyIsRecording` が、10秒の待ちの間にメインスレッドが約5秒ずつ2回止まって落ちた。

## 参照

- [Apple: Environment variable reference](https://developer.apple.com/documentation/xcode/environment-variable-reference)
- [Apple: Xcode Cloud workflow reference](https://developer.apple.com/documentation/xcode/xcode-cloud-workflow-reference)
- [Apple: Configuring your Xcode Cloud workflow's actions](https://developer.apple.com/documentation/xcode/configuring-your-xcode-cloud-workflow-s-actions)
- [WWDC18: What's New in Testing](https://wwdcnotes.com/notes/wwdc18/403)
