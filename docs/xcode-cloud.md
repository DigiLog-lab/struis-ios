# Xcode Cloud のテストプランと実測

方針は [verification-and-delivery-policy.md](verification-and-delivery-policy.md)。この変更は10節の1本目に当たり、テストプラン、ビルド準備、時間とcacheの計測を用意する。Ready・門の起動・workerの再開と、既存のGitHub macOSジョブの停止は後続の変更で行う。

`Default` の旧プロジェクトパスはTomochikaが修正済み。この変更はApp Store Connect上のworkflowを作り替えない。

## scheme とテストプラン

| 用途 | scheme | テストプラン | 単体テスト | UIテスト |
|---|---|---|---|---|
| 門 | `StruisPRGate` | `TestPlans/PRGate.xctestplan` | 全部 | E2E + 変更に関係するメソッドから、門の対象外だけを除く |
| リリース | `StruisRelease` | `TestPlans/Release.xctestplan` | 全部 | 全部 |

両方ともプロジェクトはリポジトリ直下の `strius.xcodeproj`。既存の `strius` scheme はそのままなので、GitHubの現行検証は既存の対象を実行する。

`ci_post_clone.sh` はscheme名で用途を判断する。workflow名を変えても、上のschemeなら同じ準備をする。互換のためworkflow名 `PR Gate`・`Release` でも判定する。PR Gateはnative依存をSimulator向け、ReleaseはSimulatorとdeviceの両方で生成する。`STRUIS_NATIVE_PLATFORM` を明示した場合はその指定を使う。

Cloudのテスト用Debugビルドだけに `STRUIS_AUTH_REQUIRED=YES` と `ARCHS=arm64` を設定する。これは既存のGitHub単体テストと同じ設定。Releaseのarchive設定は変更しない。ビルド番号は既存の `CI_BUILD_NUMBER` を使う処理を保つ。

録画はschemeの `preferredScreenCaptureFormat=screenshots` で使わず、コードカバレッジも無効にする。テスト自身のスクリーンショットと失敗時の添付は残す。テストの判定・時間上限・再実行設定は変更しない。

## PR Gate の対象の生成

`scripts/ci/xcode_test_plan.py` は既存の `ui_test_plan.py` と `ui-test-plan.json` を使う。別の対応表は作らない。Cloudでcloneした後、main(実際のPRビルドでは `CI_PULL_REQUEST_TARGET_BRANCH`)を取得してmerge baseからの差分を調べ、PR Gateのプランを更新する。

```sh
python3 scripts/ci/xcode_test_plan.py --tier pr --base main \
  --output TestPlans/PRGate.xctestplan --report /tmp/struis-pr-test-selection.json
```

mainの取得や差分の特定に失敗した場合は、門で実行可能なUIテスト全部に広げる。E2Eだけには縮めない。対象が空になった場合や、除外表に削除済み・重複したテストがある場合は生成を止める。

選別結果には、元のHEAD、実際のcheckoutのSHA、変更ファイル、実行する全UIメソッド、除外したメソッドと理由、Cloudのbuild IDを記録する。CloudではDerivedData直下の `struis-pr-test-selection.json` に保存し、ログにも出す。PRのsource commitとCloudがcheckoutしたcommitは別々に記録する。

チェックイン済みのPR Gateプランは、差分が取得できない時と同じ広い対象。UIテストの追加・改名時は、次の2つを実行して更新する。選別スクリプトのテストが更新漏れを検出する。

```sh
python3 scripts/ci/xcode_test_plan.py --tier pr --output TestPlans/PRGate.xctestplan
python3 scripts/ci/xcode_test_plan.py --tier full --output TestPlans/Release.xctestplan
```

## メソッド単位で確認した門の対象外

カメラ画面を開く13メソッドを `scripts/ci/xcode-cloud-exclusions.json` に列挙した。各行は元ファイルと理由を持つ。既存のテスト本体にskipは追加しない。手元検証とReleaseでは従来どおり実行する。

| クラス | 門から除くメソッド |
|---|---|
| `ChatCameraUITests` | `testCameraAndChatPreservation`、`testCameraRotationAndReopening` |
| `ChatImmediateImageSendUITests` | `testCancelWhileCaptureIsFinishing`、`testSendImmediatelyAfterCameraAttachment`、`testTwoImagesPersistAfterRelaunch` |
| `ChatPhysicalImageSendUITests` | `testPhysicalCameraImmediateSend` |
| `DeviceWorkbookUITests` | `testSetGenerationCaptureAndGradingOnDevice`、`testSetGenerationCaptureAndGradingWithRealCodex` |
| `Issue10ScreenshotUITests` | `testProblemCaptureAndAllCorrectResult` |
| `WorkbookE2EFixesUITests` | `testSetCaptureOpensResultAndPassShowsImmediately` |
| `WorkbookSplitGradingUITests` | `testBatchOfPhotosGradedAsOneAnswer`、`testCloseSetWithFoundProblems`、`testPhotosAddUpToOneSetResult` |

`WorkbookHomeUITests` はカメラボタンの存在を調べるだけで、カメラを開かないため残す。`DeviceChatUITests` の `#filePath` はアサーションの失敗位置を示す用途で、ソースを読む用途ではないため残す。画像フィクスチャを指定したカメラテストは、`ChatCameraController.authorize()` が画像を表示して戻り、実カメラのsessionを起動しない。上表にはそれらも含め、方針に従ってカメラ画面を開くテストを手元検証へ置く。

単体テストで `#filePath` からファイルを開く可能性があるのは `EngineVectors.loadData` の代替経路。先にテストbundleの `engine-vectors` を探すため、そのフォルダを必須resourceとして明示登録した。同期グループでの自動同梱に依存せず、Cloudのテスト側マシンでもbundleから読む。単体テストを門から除く設定は加えていない。

現時点の広い対象はPR Gateが44 UIメソッド、Releaseが57 UIメソッド。外部入力がない時の既存skip条件は [testing.md](testing.md) のまま。

## 時間とcacheを比べる

`ci_post_clone.sh` はworkflow・action・build ID、CPU数・メモリ・アーキテクチャ・Xcode版を出す。各工程は `STRUIS_STAGE_START` と `STRUIS_STAGE_END` で時刻・所要秒数・終了コードを出し、途中の工程が失敗した場合も失敗コードを保持する。全体は `STRUIS_POST_CLONE` に出す。

`CARGO_TARGET_DIR` は `CI_DERIVED_DATA_PATH/StruisNative/cargo`。bootstrapの前後に `STRUIS_CARGO_CACHE` で容量を出す。DerivedDataの変数がない場合は既存のbuild領域を使い、cacheの持ち越しができるとは報告しない。

App Store Connectでは、現在修正済みの設定を起点に次を確認する。

1. PR Gateは `StruisPRGate` scheme のTest action、Releaseは `StruisRelease` scheme のTestとArchive actionにする。プロジェクトは `strius.xcodeproj`、Cleanは無効にする。Releaseの配布先は内部TestFlightとし、まだ自動起動は追加しない。
2. 同じソース・同じPR Gate workflow・同じXcode版で2回実行する。1回目の初回生成と2回目のcache利用を比べる。各build ID、対象SHA、bootstrapの秒数、前後のcache容量、Test action全体の時間、単体/UIの成功・失敗・既存skip件数を残す。
3. 録画とカバレッジを使わない設定で、UIテスト前の待ち時間も測る。15分という見積もりが達成できたとは、測るまで扱わない。

GitHubの `Agent tests` はLinuxで `scripts/ci/cache_usage.py` を実行し、その時点のActions cacheの合計bytes・GiB・件数をsummaryに出す。cacheを復元・作成するmacOSジョブは追加しない。

この実行環境にはXcodeがないため、schemeの読み込み、Simulator実行、Cloud cacheの持ち越し、実際のTestFlight配布は未検証。後続のエージェントとworkflowの切り替えは、この実測を確認してから行う。夜間全件・mainの署名付きarchive・cold buildは、方針5.1の条件が満たされるまで保つ。

## 参照

- [Apple: Environment variable reference](https://developer.apple.com/documentation/xcode/environment-variable-reference)
- [Apple: Xcode Cloud workflow reference](https://developer.apple.com/documentation/xcode/xcode-cloud-workflow-reference)
- [Apple: Configuring your Xcode Cloud workflow’s actions](https://developer.apple.com/documentation/xcode/configuring-your-xcode-cloud-workflow-s-actions)
- [XcodeGen: Test Action / preferredScreenCaptureFormat](https://github.com/yonaskolb/XcodeGen/blob/master/Docs/ProjectSpec.md#test-action)
