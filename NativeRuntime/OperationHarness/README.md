# Descriptor capability filesystem

`src/lib.rs`と`src/handles.rs`は、trusted callerが発行するworkspace capabilityに対してdescriptor相対の実ファイル操作を提供します。owner・generation・権限を各操作で確認し、revokeと進行中操作をmutexで直列化します。絶対path、親参照、symlink、複数hardlink、特殊fileを拒否します。opaque handleはCoreが保持し、外部へOS descriptorを渡しません。

read/write/list/copy/remove/renameは実際のPOSIX操作を呼びます。chunk、file size、handle数、list長、再帰深度・node数には有限の予算があります。失敗はsanitized errnoとして残り、拒否された操作を別のpathname APIへ迂回しません。部分的なcopy/removeには途中の変更が残る場合があります。

trusted callerはworkspaceのrename・分類変更や私有fileの配置前にgrantをrevokeし、進行中操作の終了を待つ必要があります。descriptorが指す元のobjectはrename後も同じobjectです。別の権限を持つnative actorの操作や任意native code全体は、このlibraryだけでは制御しません。

```sh
rustup run 1.95.0 cargo test --locked --manifest-path NativeRuntime/OperationHarness/Cargo.toml
```

テストは一時的な合成workspaceとprivate canaryを使用します。単独のfilesystem試験と、アプリのAI・worker・撮影・再開の実操作は別に確認してください。アプリへの接続は`NativeCodex/src/lib.rs`と`Scripts/prepare-codex.py`、Swiftの`NativeRuntimeHost`から追えます。
