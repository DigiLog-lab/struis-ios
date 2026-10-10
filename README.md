# Struis iOS

紙に解いた答案を取り込み、質問・例題・演習と学習記録をつなぐiOSアプリです。このリポジトリでは、端末側の画面、学習規則、台帳、通信、Hyotan-v2の実行環境とビルド手順を公開します。

ソースの閲覧、ローカルでのビルド、実サービスの利用にはそれぞれ条件があります。ビルドには下記のツールが必要です。実サービスには配信サーバーの利用設定とAI認証が必要で、公開テンプレートだけでは利用できません。backend・Web・配信プロンプト・スキーマ・Skill本文はこのリポジトリに含みません。

| 場所 | 内容 |
|---|---|
| `strius/Features/`・`strius/App/` | 画面とアプリ起動 |
| `strius/Engine/`・`strius/Ledger/` | 学習規則、応答検証、端末台帳 |
| `strius/Runtime/`・`NativeRuntime/` | Codex、Python、BSD/dashとworker |
| `strius/Delivery/`・`Networking/`・`Auth/` | 配信、通信、認証 |
| `striusTests/`・`striusUITests/` | 単体テスト、画面テスト、任意の実AIテスト |

## ビルド

Xcode 27.0、iOS 27 SDK、Python 3.14、Rust 1.95.0、autoconf・automake・libtoolを使用します。native frameworkはarm64用です。生成物と取得cacheはGit管理外です。

```sh
git clone https://github.com/DigiLog-lab/struis-ios.git
cd struis-ios
brew install python@3.14 rustup autoconf automake libtool
rustup toolchain install 1.95.0 --profile minimal
rustup target add --toolchain 1.95.0 aarch64-apple-ios aarch64-apple-ios-sim
python3.14 NativeRuntime/Scripts/bootstrap.py --platform both
xcodebuild build -project strius.xcodeproj -scheme strius \
  -destination 'generic/platform=iOS Simulator' ARCHS=arm64 CODE_SIGNING_ALLOWED=NO
```

配信サービスを使う場合は`Config/Local.xcconfig.example`を`Config/Local.xcconfig`へコピーし、運営者から取得した`STRUIS_DELIVERY_APP_KEY`を設定してください。値をGitへ追加しないでください。実機・archiveには自分の署名チームとApp Groups・extensionの署名設定も必要です。既存のBundle IDとApp Groupsは保存互換性のため維持しています。

```sh
xcodebuild archive -project strius.xcodeproj -scheme strius \
  -destination 'generic/platform=iOS' -archivePath /path/out/Struis.xcarchive
```

実際に使用するSDK・署名・依存は[ビルドの説明](docs/build.md)を参照してください。

## テスト

```sh
xcodebuild test -project strius.xcodeproj -scheme strius \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:striusTests -parallel-testing-enabled NO STRUIS_AUTH_REQUIRED=YES
```

実AI・非公開配信入力・実験用bundleを要するテストは任意です。未設定時は理由付きでskipし、mockの画面テストとは区別します。[テストの条件](docs/testing.md)を参照してください。カメラUI用の同梱画像は個人情報を含まない生成答案で、実機で紙を撮影した証拠にはなりません。

通信先と送信項目、端末内の保存先、使用量報告は[通信と保存](docs/communication-and-storage.md)に記載します。サーバーから配信される本文が非公開である範囲も明記しています。

## ライセンスとソースの対応

個別のライセンス表示がない自作部分はAGPLv3です。[App Store除外規定](LICENSE.AppStore)を追加許諾として適用します。第三者コードと個別表記を持つコードにはそれぞれの条件が適用されます。[LICENSE](LICENSE)、[第三者告知](THIRD_PARTY.md)を参照してください。

権利者は自作部分について将来、別ライセンスでの提供を検討できます。現時点でその提供条件は定めていません。必要な権利を維持するため、コードの寄稿は当面受け付けません。Issueでの不具合報告・質問は受け付けます。

[配布版と公開ソースの対応](docs/source-and-releases.md)には、抽出元と今後の配布版に対応するcommitを記録します。
