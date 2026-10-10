# Threaded CPython test overlay

任意の固定threaded foundation bundleへmain.js、worker.js、stdio.jsとcanonical Python runnerを重ねるテスト用overlayです。`overlay-manifest.json`で基礎bundleとoverlayのhashを固定します。manifestの旧source path表記は生成元の記録で、実行時のcheckout依存ではありません。

exact argv bytesをcanonical runnerへ渡し、実Emscripten FSのfd0/1/2を使用します。Dedicated Workerだけが有限binary SABで待ち、UI側のtransportは非同期です。completion/cancelには実provider cleanupとpthread retirementを要求します。

基礎bundleは公開Gitへ同梱しません。`STRUIS_THREADED_PYTHON_ASSETS_DIR`をbuild前に設定し、`scripts/prepare_external_test_inputs.py`で検査・配置します。設定がない場合、該当テストは理由付きでskipします。hashや内容が異なる入力は失敗です。

Linuxの`Scripts/check-threaded-python-stdio.py`は実C bridgeとdescriptor ABIを合成workspaceで検査します。Apple WK/XPC/dashの構成はSimulatorで別に確認します。このoverlayは通常のproduction provider設定を変更しません。
