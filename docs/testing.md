# テストの条件

Engine vector、Learning Feed、台帳・規則の合成入力は同梱します。Engineの既存期待値は保持しています。mockを使う画面テストは表示や操作の回帰を調べるもので、実AIの成功を示すものではありません。

| 設定 | 必要な入力・用途 |
|---|---|
| `TEST_RUNNER_STRUIS_REAL_CODEX_AUTH` | 利用許可のあるCodex auth.jsonの作業コピー。実AIテストのopt-in |
| `TEST_RUNNER_STRUIS_REAL_CODEX_ASSETS_DIR` | DelegationLiveTestsと既定単元を使うUI実AIテストの外部配信資産ディレクトリ。未設定時は理由付きskip |
| `TEST_RUNNER_STRUIS_TEST_SKILLS_DIR` | TurnActivityTestsの2件が読む外部Skillディレクトリ |
| `STRUIS_TEST_DELIVERY_SCRIPTS_DIR` | build前に与える配信Pythonスクリプト2件のディレクトリ |
| `TEST_RUNNER_STRUIS_NATIVE_LIVE=1` | native Simulator統合テストのopt-in |
| `TEST_RUNNER_STRUIS_VIRTUAL_PYTHON_LIVE=1` | 任意のVirtual Python/WKテスト |
| `TEST_RUNNER_STRUIS_THREADED_PYTHON_LIVE=1` | 任意の固定threaded bundle/WKテスト |
| `STRUIS_THREADED_PYTHON_ASSETS_DIR` | build前に与える固定experimental bundle。内容をhashで検査 |
| `STRUIS_TEST_DELEGATE_FILE` | Linux browser filesystem検査が読む外部delegate.py |

外部入力は公開リポジトリへ含みません。`python3.14 scripts/sync_test_resources.py`が外部Python入力とthreaded bundleをGit管理外の専用領域へ配置します。設定がない場合はその入力を除き、該当テストは理由付きでskipします。指定済み入力が欠損・破損している場合は失敗です。テストrunnerへ環境を渡す場合、Xcodeでは`TEST_RUNNER_`を付けます。

Virtual Pythonとgitの公開固定入力は、必要な場合だけ`NativeRuntime/Scripts/prepare-virtual-python-test-assets.py`と`prepare-virtual-git-test-assets.py`で取得・生成して、resource同期を再実行します。任意の実験用入力は通常のapp/archiveへ同梱されません。threaded overlayのmanifestにある旧`ios/strius/`表記は、hash固定の生成元を示す文字列で、ローカルパス依存ではありません。

認証ファイルは実行用コピーだけを渡し、0600で保持してください。アプリへの注入はDEBUGのSimulatorに限り`STRUIS_DEBUG_CODEX_AUTH_FILE`で行います。元のMac認証を上書きしないでください。

UIで教育ループを確認する場合は、`STRUIS_IOS_USE_FIXTURES=0`、`STRUIS_DEVICE_RUNTIME=1`、`STRUIS_LEDGER=persistent`で起動し、実際の単元生成・説明・回答・採点・学習記録・再起動を操作します。既定のテスト単元を使う自動回帰テストと区別してください。`scripts/e2e/`はXCUITest経由の実操作を補助します。

`striusUITests/Fixtures/handwritten_eigenvalue.jpeg`は同梱フォントで描画した合成数学答案です。実機カメラ、端末のsandbox、既存インストール互換性は、実機上の操作で別に確認します。

HTTP bootstrapの同時読込テストは認証有効のビルドを前提にしています。READMEの単体テストコマンドでは`STRUIS_AUTH_REQUIRED=YES`を検証ビルドにだけ渡します。通常の認証不要設定では`BootstrapStore`がbootstrap通信を行わず、そのテストの「userを取得・1回通信」の期待値を満たしません。認証不要経路は同じ設定の`APIClientTests/noAuthStartupDoesNotCreateASignedInUserOrFetchBootstrap`で確認できます。この検証設定で配布用の設定やサーバー契約を変更しません。

## Claude の経路の確認

`ClaudeProxyTests` は、Codex の Responses API と Claude の Messages API の変換(tool、thinking の署名の往復、画像、structured outputs の schema)、端末内プロキシの往復、スレッドを始めた実行先で続ける規則を確認します。

実キーなしで Simulator の配線を確かめる場合は、`scripts/e2e/fake_anthropic.py`(現行の Claude が拒む要求の形を 400 で返す模擬サーバー)と `scripts/e2e/standin_assets.py`(配信の代わりの最小の prompt・schema)を使い、DEBUG の Simulator に `STRUIS_ANTHROPIC_BASE_URL=http://127.0.0.1:8787`・`STRUIS_DEVICE_ASSETS_DIR=<出力先>` を渡します。模擬サーバーの返事は決まった文で、Claude の答えの質の確認にはなりません。Simulator は App Attest を使えないため、実キーで確認する場合は 0600 の作業コピーを `STRUIS_DEBUG_ANTHROPIC_KEY_FILE` で渡します(DEBUG の Simulator のみ。端末向けのビルドにはこの経路が入りません)。実機は App Attest で Anthropic から token を受け取ります。token 取得の手順(チャレンジ・登録・交換・401 での取り直し)は `ClaudeAppAttestTests` が模擬の Apple・Anthropic で確かめ、Apple の本物の attestation は実機で確かめます。`STRUIS_CLAUDE_PROXY_DUMP_DIR` を付けると、変換前後の要求(画像は省略)を書き出します。

## マージ前に回すテストの範囲(2026-10-22 の方針)

PR ごとに、単体テスト全部と、変更が当たった「契約」のUIテストだけをマージ前に回します。夜間の全件実行はしません。UIテストに件数の上限はなく、選ばれた分は全部回します。狭い変更なら約10分、`ChatView.swift` と `ChatStore.swift` を一緒に触るような広い変更は20〜30分かかります。

理由は費用の構造です。単体テスト約400件の本体は25秒ですが、UIテストは1件20〜45秒かかり、全件では30分を超えます(2026-10-21〜22 の実測、`docs/ci-experiments/` は実験ブランチ `experiment/ci-overnight-20261022` にあります)。夜間の全件実行は「選び方を信用していない」ための保険で、失敗しても通知されず、変更のない日も回っていたのでやめました。その代わり、契約表の漏れはそのまま見逃しになるので、表は「迷ったら契約に入れる」向きに作ります。

### テストの層

| 層 | いつ | 何を |
|---|---|---|
| 毎PR | 毎回 | 単体テスト全部 |
| 毎PR | 契約に当たった時だけ | 契約のUIテスト(`scripts/ci/ui-test-plan.json` の `contracts`) |
| 手動 | TestFlight 配信の前、その機能を変えた時 | 実機・実Codex・実通信が要るUIテスト、画像を目で見て確かめるUIテスト(`manual`。理由つき) |
| 外す | ― | 起動テンプレート、起動時間の計測、操作の道具(`excluded`。理由つき) |

単体テストの既知の skip(実ランタイム・実通信)も毎PRでは確かめていない範囲です。手動の層と同じく、その機能を変えた時に環境を用意して回します。skip のまま成功扱いにはしません。

### 契約と選び方

`scripts/ci/ui_test_plan.py --list` が、main との差分のファイルから選びます。

1. 契約(`contracts`)ごとに、守る性質・UIテスト・対応するファイル(`paths`)を書きます。変更したファイルが当たった契約のUIテストを全部選び、複数当たれば和をとります。
2. `everything` に当たる変更(`strius/Design`、`strius/App`、`strius/Auth`、`strius/Resources`、`Info.plist`、`Config`、固定応答の `MockTurnRunner.swift`、台帳の fixture、`ios.yml`、選び方そのもの)は全契約です。
3. `strius.xcodeproj/project.pbxproj` は、差分がファイル参照の追加・削除だけなら何も足さず(足したファイル自身が契約を選ぶ)、ビルド設定などが変わる時は全契約です。
4. 契約にないファイルは `folders` の既定(フォルダごと、最初に当たったもの)で選びます。`guarded`(アプリと UI テストのソース)にあって、どの規則にも当たらないファイルがあると計画は止まります。新しいファイルは表に足して、選ぶUIテストを決めてから進めます。
5. `striusUITests/` のテストのファイルを変えると、そこに書かれた契約のUIテストを選びます。テストクラスの無い共通コード(`UITestSupport.swift` など)を変えると全契約です。
6. 見つかったUIテストは、どれかの契約か、`manual`・`excluded` のどれかに必ず入っていなければなりません。どこにも無い新しいテストがあると計画は止まります。
7. 選び方の表とスクリプトを変えた PR は、全契約を回します(PR が自分の検証を軽くできないようにするため)。

UIテストが0件の時は `-only-testing:striusTests` だけを渡します。空の絞り込みのまま `xcodebuild` を呼ぶと全件が走るためです。

### 実行の形

門は GitHub の `iOS` workflow(`verify` ジョブ)で、ビルド1回とテスト1回だけを回します。エージェントの完了前の手元検証(`scripts/agent/delivery.py` の `local_verify`)も同じ形です。

- `build-for-testing` を1回、`test-without-building` を1回。単体テストと選んだUIテストを1つのコマンドで流します。
- テストの時は署名を外しません(`CODE_SIGNING_ALLOWED=NO` を渡さない)。外した試行で `ClaudeAppAttestTests` が1件落ちたためです(2026-10-22)。
- Simulator は1台、並列にしません(`xcode-27` の runner は3コア・7GBで、1台の中で並列にすると遅く、不安定になった)。
- 結果は `ios-test-results-<実行ID>-<再実行番号>` の artifact に保存します(xcresult と、落ちた時の画面の写真・要素の木 `ui-probe`)。門の時は、実行したテストの一覧を `ios-gate-tests-…-verify` に保存し、制御ジョブが必要なテストと照合します。
- 手動の全件実行(`ui_tier=full`、または main での手動実行)は、従来どおり3台の runner に分けて流します(`build` + `ui-tests` ジョブ)。

### 時間を縮めるための fixture

同じ道筋を毎回最初からたどらないよう、必要な状態から始める起動の引数があります。準備は画面と同じ規則(`WorkbookMachine`)を通し、射影を直接書き換えません。

| 引数 | 始まる状態 | 使うテスト |
|---|---|---|
| `-workbook-practice-ready` | 類題に合格し、演習の一枚(5問)が開いている | 分割採点の3本。準備が正しいことは単体テスト `WorkbookPracticeFixtureTests` が確かめる |
| `-workbook-example-stage` | 小単元1が例題の段 | `testSendingCollapsesExampleBar`、`testExampleAdvanceAppearsOnlyAfterModelMarksReady`。要点から「先に進む」までは `testExampleStageBarsComposerAndFloatingAdvance` が確かめる |

返事の後ろの記録を待つテスト(`ReplyTailUITests`)は、確かめ終わった時点でテストから合図(Darwin 通知)を送り、記録を終わらせます。決まった時間だけ待つと、確かめ終わった後もその残り(偽の記録40秒の残り約33秒)を毎回待っていました。

### 導入後に測ること

導入から2週間、PRの「push から必須チェックが出るまで」の時間、選ばれたUIの件数(全契約に倒れた割合と、その原因のファイル)、マージ後に見つかった見逃し、同じ HEAD で再実行したら通った不安定な失敗を記録します。全契約に倒れる原因は `MockTurnRunner.swift` と大きいファイル(`ChatView.swift`、`ChatStore.swift`)だと見ています(main の最近の変更を当て直すと、全契約になった7件のうち3件が `MockTurnRunner.swift` によるもの)。その時は、ファイルを契約の単位に分けることを次の改善にします。
