# Struis iOS — ライセンスと第三者告知

自作部分のAGPLv3とApp Store除外規定は`LICENSE`・`LICENSE.AppStore`に記載しています。個別表記のあるコードはその条件を維持します。第三者由来の部分にはそれぞれの条件が適用されます。

## Native runtime

`NativeRuntime/` は Hyotan-v2 の native 実装を移植したものです。Codexはアプリ本体のNativeCodexHost、Python・コマンドはStruisExecで実行します。旧iSHのRuntime/hyotan・rootfsはこの独立リポジトリへ収録していません。

| 同梱物 | 固定入力 | 告知 |
|---|---|---|
| Native Codex 0.153.4 | `3d2ee51ca2d5db578f328aa75e20aa22c0197c9a`、iOS向け変更は `Scripts/prepare-codex.py` | Apache-2.0、`Licenses/Codex.txt`、Rust個別告知 |
| ios_system / BSD commands | `ebc045299e56edaf3509144d43a7f7348af400a7` | BSD系ほか、`Licenses/dependencies.json` |
| dash | `3da49bb7ac15458ea4f554b589dde5197816f6ba` | BSD-3-Clause、`Licenses/dash.txt` |
| CPython / Python-Apple-support | `dependencies.lock.json` のURLとSHA-256 | PSF-2.0 / MIT、Python native依存の個別告知 |
| Dulwich 1.2.15 / urllib3 2.8.0 | `PythonModules/` | Apache-2.0側を選択 / MIT |
| NumPy 2.3.5.post1 | SDK別iOS wheel、`python-packages.lock.json` | BSD-3-Clauseほか、wheel内の個別告知を保持 |
| SymPy 1.14.0 / mpmath 1.3.0 | 同lock | BSD-3-Clause |
| PyYAML 6.0.3 | 同lock、pure Python版 | MIT |
| CA bundle | `ca-bundle.lock.json` | CDLA-Permissive-2.0 |

`NativeRuntime/Licenses/` をextensionに同梱します。NumPyはApple Accelerateを使用し、iOS wheelのnative依存も監査対象にします。Rust依存一覧と通知は `Rust-dependencies.json` / `Rust-notices.txt` / `Rust-upstream/` に保持します。`debugserver-types` の独立した上流LICENSE/著作権通知が無い例外は既存監査に記録されています。

## 再ビルド

Xcode 27、Python 3.14、Rust 1.95.0とiOS targetを準備し、次を実行します。

```sh
python3 NativeRuntime/Scripts/bootstrap.py --platform both
```

ビルド済みframework、取得ソース、PythonPackagesはGit管理外です。別のローカルプロジェクトへのsymlinkは使用しません。BSDのパーサーはBerkeley Yaccで再生成し、dashのsignal tableも独立生成します。ビルド時だけ必要な生成器をアプリへ同梱しません。GitHub Actionsは同じnative構成のbootstrapを呼びます。

## その他のアプリにリンク・同梱するライブラリと資源

| コンポーネント | 入手先 | ライセンス | 用途 |
|---|---|---|---|
| GRDB.swift | https://github.com/groue/GRDB.swift(SPM) | MIT | 端末台帳(SQLite) |
| Yams | https://github.com/jpsim/Yams(SPM) | MIT | tutor desk の canonical memory(YAML) |
| Auth0.swift | https://github.com/auth0/Auth0.swift(SPM) | MIT | ログイン |
| JWTDecode.swift, SimpleKeychain | Auth0.swift の依存(SPM) | MIT | 同上 |
| KaTeX 0.16.45 | `strius/Resources/KaTeX/`(`LICENSE` 同梱) | MIT | 数式の組版 |
| Zen Kaku Gothic New | `strius/Resources/Fonts/`(`OFL-ZenKakuGothic.txt` 同梱) | SIL OFL 1.1 | 本文フォント |
| Cormorant Garamond | `strius/Resources/Fonts/`(`OFL-CormorantGaramond.txt` 同梱) | SIL OFL 1.1 | 欧文フォント |
| libsqlite3, libresolv | iOS SDK(システム) | Apple SDK | リンクのみ。再配布しない |

SPM パッケージの版は `strius.xcodeproj` の package reference(いずれも up to next major)で解決します。
