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
