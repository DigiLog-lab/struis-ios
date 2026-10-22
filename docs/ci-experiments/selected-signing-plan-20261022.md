# Simulator署名を省く1要因の比較

PR #39のscripts/agent/delivery.py local_verifyはCODE_SIGNING_ALLOWED=NOを使う。一方、ここまでの追加実験はXcodeの既定の署名設定で、build.logにCodeSignが19件ある。

同じアプリ、全Unit398件、reply_tail_contractのUI3件、probe1件、事前warmなし、1コマンドで、CODE_SIGNING_ALLOWED=NOだけを追加した1回を測る。既存の2回との比較は別VMであり、VMのばらつきを除いた因果効果とは断定しない。速度が有望ならこの構成だけを再測定する。

期待する実行結果はUnit369 Passed/29既知skip、UI3 Passed、probe1 Passed。新たなskip、欠落、失敗は拒否する。iOS Simulatorでの検証であり、実機の署名/App Groups/配信を確認したとは扱わない。実機依存の既存skipは検証済みへ読み替えない。アプリのassertionは変更しない。

通常CI/main/PR #39/配信/秘密情報は変更しない。品質・準備済みVMの実験と合わせて同時2台以下。自動再試行なし、25分上限。
