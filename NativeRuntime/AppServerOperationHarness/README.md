# Codex filesystem adapter

固定したCodex revision `3d2ee51ca2d5db578f328aa75e20aa22c0197c9a`の`codex_file_system::ExecutorFileSystem`を、隣のOperationHarnessへ接続します。Codexのmodel loopは上流の実装を使用します。

`CapabilityFileSystem`へ渡すroot・owner・generation・grantはtrusted callerの値です。modelの引数から権限を発行しません。URIはworkspace内のrelative pathへ変換して、最後の操作を保持したdescriptorで行います。`sandbox: None`でもcapability検査を除きません。追加のrestricted sandbox条件は既存policy resolverで交差させ、未対応の条件は拒否します。

通常のfile read/write、metadata、有限stream/list/walk、mkdir/remove、copyを実装します。linkや特殊file、未対応のrecursive sandbox mutation等は失敗になります。streamはchunkごとにgrantを再確認するので、複数chunkのsnapshot同一性は提供しません。

bootstrap後の固定upstream checkoutをpath dependencyとして使用します。

```sh
rustup run 1.95.0 cargo test --locked --manifest-path NativeRuntime/AppServerOperationHarness/Cargo.toml
```

このtrait adapterの検査だけでCodexのconfig/auth/state、local media、native search、BSD/Python等の全経路を確認したことにはなりません。各接続は`Scripts/prepare-codex.py`と個別のsource preparationで確認してください。
