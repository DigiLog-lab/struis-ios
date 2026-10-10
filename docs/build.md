# ビルドと外部設定

READMEのコマンドはリポジトリのルートで実行します。Xcode 27.0、Python 3.14、Rust 1.95.0、autoconf・automake・libtool、Ruby `xcodeproj`が必要です。

`NativeRuntime/Scripts/bootstrap.py --platform both`は固定したURL、revision、SHA-256から依存を取得し、deviceとSimulatorのnative成果物を生成します。`--platform device`または`simulator`はCodex・検索・Python追加パッケージの対象SDKを限定します。BSD/dashは両SDKを生成します。入力は`dependencies.lock.json`、`Scripts/build-codex.py`のCodex revision、`python-packages.lock.json`、`ca-bundle.lock.json`とScripts内の固定値です。Rust registry依存はCargo.lockに従います。

Vendor、PackageCache、PythonPackages、.buildは生成・取得領域です。別のローカルプロジェクトへのsymlinkは必要ありません。generic Simulatorを指定する場合は、native成果物と同じ`ARCHS=arm64`を明示してください。x86_64版のnative frameworkは生成しません。依存を更新する場合はlock、告知と実bundleを一緒に確認してください。

`scripts/sync_project.py`はSwift sourceとnative targetを登録し、`sync_test_resources.py`は同梱可能な合成入力と、存在する任意test資産を登録します。backend checkoutはビルド入力ではありません。

配信キーは`Config/Local.xcconfig`へ設定します。`Config/Build.xcconfig`の公開既定値は空です。Info.plistは`STRUIS_DELIVERY_APP_KEY`をビルド時に取り込みます。キーは配信サービスの利用条件であり、AIアカウント認証は別に必要です。

実機archiveにはApple Developerの署名チーム、`com.digiloglab.strius`とworkerのBundle ID、`group.com.digiloglab.struis.runtime`のApp Groups entitlementを設定します。既存データの検証では同じ識別子を維持してください。

Xcode Cloudの`ci_scripts/ci_post_clone.sh`は独立リポジトリのルートからbootstrapします。`STRUIS_NATIVE_PLATFORM`を指定しない場合、既存のnativeテストworkflowはSimulator、それ以外はdeviceを選びます。配信キー等はCIの外部設定で供給してください。署名秘密値をソースへ書かないでください。

生成されたアプリは`NativeRuntime/Scripts/audit-bundle.py`、Rust通知は`audit-rust-licenses.py`で実物を確認できます。各スクリプトの引数は`--help`を参照してください。
