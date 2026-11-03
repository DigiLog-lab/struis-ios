# ビルドと外部設定

READMEのコマンドはリポジトリのルートで実行します。Xcode 27.0、Python 3.14、Rust 1.95.0、autoconf・automake・libtoolが必要です。

`NativeRuntime/Scripts/bootstrap.py --platform both`は固定したURL、revision、SHA-256から依存を取得し、deviceとSimulatorのnative成果物(BSDコマンド、dash、`build-native.py`のRustライブラリ、Python)を生成します。Rustライブラリは`NativeRuntime/NativeLibrary`(crate `hyotan-native`)の`libhyotan_search.a`(rg。StruisExecにリンク)と`libhyotan_operations.a`(作業領域操作。アプリ本体に静的リンク)です。モデルは端末で動かさないため、AIエージェントの実行環境はビルドしません。`--platform device`または`simulator`はRustライブラリ(検索・作業領域操作)・Python追加パッケージの対象SDKを限定します。BSD/dashは両SDKを生成します。BSDのコンパイル対象は`bsd-sources.lock.json`に固定されています。入力は`dependencies.lock.json`、`NativeLibrary/Cargo.lock`、`python-packages.lock.json`、`ca-bundle.lock.json`とScripts内の固定値です。Rust registry依存はCargo.lockに従います。

Vendor、PackageCache、PythonPackages、.buildは生成・取得領域です。別のローカルプロジェクトへのsymlinkは必要ありません。generic Simulatorを指定する場合は、native成果物と同じ`ARCHS=arm64`を明示してください。x86_64版のnative frameworkは生成しません。依存を更新する場合はlock、告知と実bundleを一緒に確認してください。

Xcodeの参照とターゲットはソースに含まれており、通常の導入でプロジェクトの再生成は不要です。Swift sourceやtargetを追加する開発では、Rubyの`xcodeproj` gemを準備して`scripts/sync_project.py`で登録できます。`sync_test_resources.py`は同梱可能な合成入力と、存在する任意test資産を登録します。backend checkoutはビルド入力ではありません。

配信キーは`Config/Local.xcconfig`へ設定します。`Config/Build.xcconfig`の公開既定値は空です。Info.plistは`STRUIS_DELIVERY_APP_KEY`をビルド時に取り込みます。キーは配信サービスの利用条件です。AIはAnthropicのMessages APIを端末から直接呼び、実機はApp Attestで認証します。そのためのClaude ConsoleのApp integrationのclient ID(`STRUIS_CLAUDE_CLIENT_ID`、`clid_...`)は秘密値ではなく、`Config/Build.xcconfig`に記載しています。App Attestはclient IDに登録したTeam IDとBundle IDの組だけを通します。DEBUGのSimulatorはApp Attestを使えないため、`STRUIS_DEBUG_ANTHROPIC_KEY_FILE`に置いたAPIキーのファイルで検証します。

実機archiveにはApple Developerの署名チーム、`com.digiloglab.strius`とExec拡張(`com.digiloglab.strius.exec`)のBundle ID、`group.com.digiloglab.struis.runtime`のApp Groups entitlementを設定します。既存データの検証では同じ識別子を維持してください。

GitHub Actionsの`.github/workflows/ios.yml`は標準の`xcode-27` runnerを使用します(PRの検証と手動の配布。mainへのpushでは動きません)。Native Runtimeは`agent-native-cache.yml`を呼び出し、cacheが無ければそこでREADMEのbootstrapを実行して保存し、あれば再生成を省略します。いずれの場合もarm64 Simulator buildと単体テストを実施し、`-collect-test-diagnostics never`で長時間のSimulator診断収集を抑制します。mainでの手動実行では、Actions Secretsから署名を供給してdevice archiveを作成し、実bundleの署名・同梱資源・リンクマップを監査します。pull requestのコードには署名・配信の秘密値を渡しません。archive、IPA、秘密設定と実行ログは公開artifactへアップロードしません。CIのsummaryに元commit、version、buildと検証結果だけを記録します。


署名用のSecretsは`BUILD_CERTIFICATE_BASE64`、`P12_PASSWORD`と、App Store Connect APIの`APP_STORE_CONNECT_PRIVATE_KEY`、`APP_STORE_CONNECT_KEY_ID`、`APP_STORE_CONNECT_ISSUER_ID`です。2つ(アプリとExec拡張)のApp Store配布用プロファイルは`scripts/ci_archive.py`がAPIで取得し、配布証明書が一致して`ACTIVE`で期限まで7日以上あり、App Group(本体はiCloudコンテナ`iCloud.com.digiloglab.strius`も)が入っているものを再利用し、無ければ作ります。App IDに機能を足してプロファイルが無効になっても、Secretsの差し替えは要りません。配信サービス設定は`STRUIS_DELIVERY_APP_KEY`を使用します。値はコードへ記載しません。

通常のCIはarchiveまでです。次の配布時は`main`を対象に手動実行し、`upload`を有効にして未使用の`build_number`を指定します。`scripts/ci_archive.py`が同じcheckoutから署名とアップロードを行い、元commit・version・buildを記録します。アップロード成功後はApp Store Connectで処理完了と内部配布先を確認し、公開ソースの対応表を更新してください。審査提出は自動実行しません。


生成されたアプリは`NativeRuntime/Scripts/audit-bundle.py`、Rust通知は`audit-rust-licenses.py`で実物を確認できます。`audit-bundle.py`は、廃止したCodexの実行環境(`StruisRuntime.appex`、`NativeCodexHost.framework`、`hyotan_codex`・`codex_app_server`等のシンボルとLink Mapの項目)がbundleに無いことも確かめます。各スクリプトの引数は`--help`を参照してください。
