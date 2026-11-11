# Enclave 導入の範囲の下調べ(2026-11-11)

`repro-app/` は、TypeScript + Node のアプリを Docker イメージとして再現可能にビルドできるかを確かめるための試験用アプリ。
製品のコードではない。

確かめ方: ベースイメージをダイジェストで固定し、`SOURCE_DATE_EPOCH=1700000000` と `rewrite-timestamp=true` を付けて、
キャッシュ無しで 2 回ビルドし、OCI マニフェストのダイジェストを比べる(`.github/workflows/enclave-repro.yml`)。

web 版 Claude の環境(Docker 29.9.2 / buildx v0.38.1、x86_64)での結果: 2 回とも
`sha256:45b0f484e0df27d5…`。`rewrite-timestamp` を付けない場合は 2 回で別のダイジェストになった。
