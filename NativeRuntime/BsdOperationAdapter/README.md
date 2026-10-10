# BSD descriptor adapter

trusted routerがworkspace directory FDとcaptured owner・generation・invocationから新しいtableを作ります。tableはopaque operations instanceを所有し、OS descriptorやCore handleを外へ渡しません。guest messageからtable pointerやscopeを受け取りません。

logical descriptorは単調増加し、tableごとの上限があります。dupは同じopen-file descriptionとoffsetを共有し、独立openは別offsetです。read/writeはaccess・append・chunk/extent予算を検査します。closeは最後の参照でCore handleを閉じ、revokeは操作と直列化します。

FILE cookie、stdioとpipeの所有は[STDIO](STDIO.md)、[COMMAND-CAPTURE](COMMAND-CAPTURE.md)、[STREAM-CLASSES](STREAM-CLASSES.md)を参照してください。任意native codeに対するinterposerではありません。個別のBSD/dash call siteとactual dispatcherへ接続する必要があります。

Linuxの単独C callerは次で実行します。Rust 1.95.0、固定libc依存、pinned ios_systemのsourceが必要です。

```sh
python3 NativeRuntime/BsdOperationAdapter/tests/run.py
```

callerは合成workspaceとprivate canaryを使い、実Core ABIとlibcを検査します。Apple SDKとnative pipelineの確認には実worker経路も必要です。
