# ビルドと外部設定

READMEのコマンドはリポジトリのルートで実行します。Xcode 27.0、Python 3.14、Rust 1.95.0、autoconf・automake・libtoolが必要です。

`NativeRuntime/Scripts/bootstrap.py --platform both`は固定したURL、revision、SHA-256から依存を取得し、deviceとSimulatorのnative成果物を生成します。`--platform device`または`simulator`はCodex・検索・Python追加パッケージの対象SDKを限定します。BSD/dashは両SDKを生成します。BSDのコンパイル対象は`bsd-sources.lock.json`に固定されています。入力は`dependencies.lock.json`、`Scripts/build-codex.py`のCodex revision、`python-packages.lock.json`、`ca-bundle.lock.json`とScripts内の固定値です。Rust registry依存はCargo.lockに従います。

Vendor、PackageCache、PythonPackages、.buildは生成・取得領域です。別のローカルプロジェクトへのsymlinkは必要ありません。generic Simulatorを指定する場合は、native成果物と同じ`ARCHS=arm64`を明示してください。x86_64版のnative frameworkは生成しません。依存を更新する場合はlock、告知と実bundleを一緒に確認してください。

Xcodeの参照とターゲットはソースに含まれており、通常の導入でプロジェクトの再生成は不要です。Swift sourceやtargetを追加する開発では、Rubyの`xcodeproj` gemを準備して`scripts/sync_project.py`で登録できます。`sync_test_resources.py`は同梱可能な合成入力と、存在する任意test資産を登録します。backend checkoutはビルド入力ではありません。

配信キーは`Config/Local.xcconfig`へ設定します。`Config/Build.xcconfig`の公開既定値は空です。Info.plistは`STRUIS_DELIVERY_APP_KEY`をビルド時に取り込みます。キーは配信サービスの利用条件であり、AIアカウント認証は別に必要です。

実機archiveにはApple Developerの署名チーム、`com.digiloglab.strius`とworkerのBundle ID、`group.com.digiloglab.struis.runtime`のApp Groups entitlementを設定します。既存データの検証では同じ識別子を維持してください。

GitHub Actionsの`.github/workflows/ios.yml`は標準の`xcode-27` runnerで固定依存を生成し、arm64 Simulatorの単体テストを実行します。`main`へのpushと手動実行では、Actions Secretsから署名を供給してdevice archiveを作成し、実bundleの署名・同梱資源・リンクマップを監査します。pull requestのコードには署名・配信の秘密値を渡しません。archive、IPA、秘密設定と実行ログは公開artifactへアップロードしません。CIのsummaryに元commit、version、buildと検証結果だけを記録します。

署名用のSecretsは`BUILD_CERTIFICATE_BASE64`、`P12_PASSWORD`、`BUILD_PROVISION_PROFILE_APP_BASE64`、`BUILD_PROVISION_PROFILE_RUNTIME_BASE64`、`BUILD_PROVISION_PROFILE_EXEC_BASE64`です。配信サービス設定は`STRUIS_DELIVERY_APP_KEY`、任意の配布には`APP_STORE_CONNECT_PRIVATE_KEY`、`APP_STORE_CONNECT_KEY_ID`、`APP_STORE_CONNECT_ISSUER_ID`を使用します。値はコードへ記載しません。

通常のCIはarchiveまでです。次の配布時は`main`を対象に手動実行し、`upload`を有効にして未使用の`build_number`を指定します。`scripts/ci_archive.py`が同じcheckoutから署名とアップロードを行い、元commit・version・buildを記録します。アップロード成功後はApp Store Connectで処理完了と内部配布先を確認し、公開ソースの対応表を更新してください。審査提出は自動実行しません。

統合側の既存CIと`ci_scripts/`のXcode Cloud hooksは復帰用に保持しています。次の配布の起点はこの独立リポジトリのGitHub Actionsです。

生成されたアプリは`NativeRuntime/Scripts/audit-bundle.py`、Rust通知は`audit-rust-licenses.py`で実物を確認できます。各スクリプトの引数は`--help`を参照してください。
