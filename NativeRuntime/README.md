# Struis native runtime

Hyotan-v2構成のnative runtime。モデルAPIはアプリ本体のSwiftから直接呼び、任意PythonとBSD/dashは`StruisExec`の通常拡張で実行します。アプリ本体には信頼済み作業領域操作(`libhyotan_operations.a`)だけを静的にリンクします。SwiftUI、Ledger、Engineはメインアプリに残る。ターミナル画面は追加しない。

## ビルド

Xcode 27 / iOS 27 SDK、Python 3.14、Rust 1.95.0、autoconf・automake・libtoolを使う。

```sh
rustup toolchain install 1.95.0 --profile minimal
rustup target add --toolchain 1.95.0 aarch64-apple-ios aarch64-apple-ios-sim
python3.14 NativeRuntime/Scripts/bootstrap.py --platform both
python3 scripts/sync_project.py
```

`--platform device` はXcode Cloud用。BSD/dashは両SDK、Rustライブラリ(`Scripts/build-native.py`)とPython追加パッケージは指定SDKを生成する。`NativeLibrary`(crate `hyotan-native`)を `search` / `operations` の別featureでビルドし、Exec worker用の `NativeSearch`(`libhyotan_search.a`)とアプリ用の `NativeOperations`(`libhyotan_operations.a`)を別成果物として保持する。`ca-bundle` featureはCA bundleの固定ソースを `cargo metadata` で解決するためだけに使い、ライブラリへはリンクしない。Vendor、PythonPackages、PackageCache、.buildは生成物でGit管理しない。別プロジェクトの絶対symlinkは使わない。Python support archive、wheel、BSD/dashのrevision、Rust依存(`NativeLibrary/Cargo.lock`)とCAはlockおよびスクリプトで固定する。Python framework内の追加拡張はSDKごとに署名対象へ配置する。

`Scripts/audit-rust-licenses.py` はターゲット別Cargo依存台帳と通知の整合、`Scripts/audit-bundle.py` は署名済みdevice appのentitlement・extension point・Mach-O・Python拡張・通知・Link Mapを検査し、廃止した組み込みエージェント実行環境(`StruisRuntime.appex`、`NativeCodexHost.framework`、`hyotan_codex`/`codex_app_server`のシンボル・Link Map項目)が無いことも確認する。未使用Vendorソースの名前だけで配布物への混入とは判定しない。ライセンスの法的保証を与える検査ではない。

## 通信と実行

モデルの呼出しは `strius/Runtime/Claude/ClaudeTurnRunner.swift` がAnthropicのMessages APIへHTTPSで直接行い、端末内のlocalhost通信やエージェントのプロセスは無い。モデルが求めたtoolは `NativeToolRouter` が端末で実行する。メインアプリの `NativeRuntimeHost` がExec workerを起動し、XPCで制御する。

`struis.exec_command` は直列のコマンドキューでBSD/dash/Pythonを実行し、cwd・exit・時間・出力・切詰めを実行監査へ返す。stdoutは96,000 bytesの末尾を保持する。`struis.struis_delegate` の待機はSwift側で行い、子の検索がコマンドキューを使用できる。子には`exec_command`と`document`だけを渡し、再帰委任は許可しない。

Pythonの割込みがC拡張内などで処理されない場合、3秒後にworkerを終了する。次の要求は新しいPIDで起動する。これは同じworker内の他の実行も切断する。古いepochの停止要求は新workerを終了させない。

## 保存先と境界

Ledger・写真・canonical memory・Claudeに送る会話の履歴はメインアプリの `Application Support/Struis` に保持する。共有app group `group.com.digiloglab.struis.runtime`には実行用home・workspaceと`thread-context.json`を置く。ディレクトリは0700、実行用領域はバックアップ除外。以前のCodexのデータ(アプリ私有の`Application Support/StruisRuntime/codex`とapp groupの`codex`)は起動時に削除する(`HyotanBoot.removeRetiredCodexData`)。

任意Python・登録コマンドはアプリ本体と別のworker processで動きます。Exec workerは共有workspaceを扱い、アプリ私有の領域にはアクセスさせません。ターン間の強いOS隔離は提供しない。Ledgerとの境界は通常拡張のOS sandboxに依存し、起動時に私有ファイルの読み書き拒否を検査する。cwd検査は隔離の代用にしない。Simulator上の試験から実機でのファイルアクセス拒否は保証しない。

署名の `com.apple.security.hardened-process` を維持する。Enhanced Security extension pointはApp Groupアクセスを拒否するため使用しない。依存frameworkがarm64であるためpointer authenticationは無効にしており、Apple templateのmemory tagging soft modeを使用する。実機のsandbox・hardeningの挙動は別途検証が必要。

start/health応答はworker自身の物理footprintと `os_proc_available_memory` を数値で返す。切断診断に添えるstart時点の値は、終了時点やpeakの測定ではない。依存分離はOSのメモリ上限を解除しない。変更後の実機メモリ余裕、PDF経路、SymPy実行は検証が必要で、移行完了を意味しない。

旧hyotan/agentcaseのworkspaceをコピーし、原本は削除しない。中断したコピーは再実行でき、既存のnativeファイルを上書きしない。保存planの写真・memoryパスは起動時の保存先で解決する。

## 互換性

- Python 3.14、NumPy 2.3.5.post1、SymPy 1.14.0、mpmath 1.3.0、PyYAML 6.0.3を固定する。配信memory/lintスクリプトは同じworkerで動く。
- POSIX dash / BSDが基準。bash配列、GNU固有オプション、任意ELF、OSのfork/subprocess実行は提供しない。
- CPythonは再利用するためsys.modulesや任意のグローバル状態は新プロセスと同じにはならない。cwd・環境・stdioを実行時に設定し、コマンドは直列化する。
- rgはripgrepエンジンの登録アダプターであり全CLI互換ではない。不一致のexit=1を維持する。
- requested/resolved modelとactual modelは区別する。actualが取得できなければnullのまま残す。
- `rootfs_min_version` は旧配信契約の互換フィールド。native版として比較しない。