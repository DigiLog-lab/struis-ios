# 速い検証の検出能力と、準備済みVMの再利用を確かめる

## 確認する内容

1. 既存のReplyTailQueueTestsとWorkbookRulesTestsの該当2件が正常版で成功する。
2. 記録中もisReplyBusyをtrueにする故障を入れる。既存の結合テストが「記録だけを書いている間は入力欄を停止ボタンにしない」のassertionで失敗することを確認する。
3. 分割採点のpartial分岐を通らず途中で締める故障を入れる。既存の結合テストが「1 枚目で一枚を締めた」のassertionで失敗することを確認する。
4. 故障を戻し、Boolの否定をfalseとの比較にする等価な実ソース変更を入れる。準備済みVMで再ビルドし、全Unit398件と長文・スクロールの選択UI9件、実験設定probe1件を実行する。Unit369 Passed/29既知skip、UI9 Passed、probe1 Passedを期待する。

故障のビルドが失敗した、別のassertionで失敗した、timeoutした、テストが欠落した場合は「検出できた」としない。原ソースはfinallyで復元する。意図した2件の失敗をアプリ正常版のPassedへ読み替えない。

## 時間の扱い

最初の冷たいbuild・Simulator起動・初期アプリ配置はこのjobに含まれ、全runner消費時間に計上する。準備済みVMでの再検証については、明示した新しい変更時刻から再ビルド・全Unit・選択UI・結果検証までを別に測り、さらにGitHub job完了までの時間も示す。この後半の時間は、毎回新規VMを起動する通常CIの全体時間ではない。

同じworkerを使う案に意味があるのは、既存のscripts/agent/delivery.pyのlocal_verifyが既にエージェントのMacでbuild/Unit/UIを実行し、その後scripts/agent/gate.pyが同じHEADの外部gateを開始するため。結果を一度だけ検証し、そのHEADの記録をLinuxの制御側で確認する案を検討する。通常の門の動作や必要checkは本実験では変更しない。

## ビルド再利用

AppleのXcode build settingsのCOMPILATION_CACHE_ENABLE_CACHINGを有効にして同一VM内の再ビルドを測る。小さな変更後も故障を検出し、最後の正常版のUnit/UIが成功することを確認する。通常のincremental buildとcompiler cacheを合わせた再利用の測定であり、compiler cache単独の短縮率を断定しない。新規VMへのcache保存/復元は実装・計測しない。

- https://developer.apple.com/documentation/xcode/build-settings-reference
- https://developer.apple.com/documentation/xcode-release-notes/xcode-26-release-notes

アプリbundleのファイル数/容量とbuild後のswap状態も残し、アプリ配置の重さやメモリ圧迫を推測だけで原因としない。

1台、最大25分、自動再試行なし、全UIは実行しない。通常CI/main/PR #39/配信/秘密情報は変更しない。
