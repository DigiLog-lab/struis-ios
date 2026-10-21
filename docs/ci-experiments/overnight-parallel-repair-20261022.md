# 並列測定の失敗記録と準備修正

## 初期run
[39630297628](https://github.com/DigiLog-lab/struis-ios/actions/runs/39630297628) は全8ジョブ完了。直列の3構成×2回は成功し、2worker構成の2回はUIテスト開始前のSimulator複製で失敗した。欠けた56件を成功扱いしていない。最後の試行のUIコマンドは31.70秒でexit65。

初期8 macOSジョブの合計開始〜終了は271.63分。これは全試行のRunner実時間の合計であり、請求額でも通常のマージ所要時間でもない。

## 最初の準備修正run
[39650567488](https://github.com/DigiLog-lab/struis-ios/actions/runs/39650567488) の2ジョブは、準備スクリプトに書いた `simctl unpair_all` が現在のXcodeに存在せず、ビルド開始前に失敗した。これは実験コード側の誤り。macOSジョブ合計1.70分。失敗ログのヘルプには `unpair` と `clone` があり、一括解除はない。

一方、実際のペア一覧には `iPhone 17` とApple Watch Ultraの組が存在し、Watchランタイム欠落による複製エラーの原因候補と整合する。

## 追加測定の修正
`scripts/ci/prepare_parallel_simulator.py` で一覧にある実際のペアUUIDごとに `simctl unpair UUID` を実行する。UUIDを検証し、解除前後の一覧を保存し、ペアが残っていれば失敗する。利用できないデバイスを削除した後、対象iPhoneを直接cloneしてdeleteする確認をビルド前に実施する。

対象は引き続き2worker版2回だけ。成功済み6ジョブは再実行せず、通常CI・main・PR #39は変更しない。アプリassertionの失敗を成功するまで再実行する操作ではない。修正後に実際の複製と全対象テストが完了するまで、並列版の速度や安定性を結論に含めない。
