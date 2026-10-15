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

## CIでのUIテストの割り当て

`iOS` workflowは、UIテストをテストメソッド単位で複数のrunnerへ割り当てて並行に実行します。runnerごとにSimulatorは1台です(`xcode-27`の標準runnerは3コア・メモリ7GBで、1台の中で並列にすると遅くなるため)。

- 割り当ては`scripts/ci/ui_test_plan.py`が`scripts/ci/ui-test-plan.json`を読んで決めます。所要時間の長いテストから順に、合計時間が最も短いrunnerへ入れます。
- `shards`: runnerの数。macOSのrunnerは同時に5台までで、エージェント本体や他のCIと共有するため、3にしています。
- `durations`: テストメソッドごとの所要秒数(CIの実測値)。載っていないテストは60秒として扱います。テストが大きく変わったら更新します。
- `pr`(任意): PRのCIで必ず実行するテストクラスの一覧。無ければPRでもすべてのUIテストを実行します。
- `paths`(任意): `{"変更ファイルのglob": ["テストクラス", ...]}`。PRで変更したファイルが一致すれば、そのクラスも実行します。
- リリースブランチ(`release/*`)へのpushと、リリースブランチでの手動実行は、常にすべてのUIテストを実行します。
- 各runnerの結果は`ios-ui-test-results-<実行ID>-<再実行番号>-<runner番号>`のartifactに保存します。runnerごとに終わるので、他のrunnerの実行中でも終わった分の結果を見られます。
