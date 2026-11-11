# 秘密分離型 HTTPS プロキシの検証コード

「秘密分離型 HTTPS プロキシ 研究開発要求仕様書 v0.2」の検証用。アプリのビルドには含めない。

## 方式
1. 端末(phone)が中継サーバー(relay)越しに、Anthropic とふつうの TLS 1.3 接続を張る。
2. phone は送信鍵の「relay が書く世代」の鍵だけを relay に渡す。relay はその鍵で、API キー入りの HTTP の先頭
   (と本文の先頭・末尾)を書き、KeyUpdate で世代を閉じる。relay が書いた暗号文は phone に流さない。
3. phone は次の世代の鍵で本文を送る。この鍵は relay に渡した鍵からは計算できない。
4. 応答は phone だけが復号する。relay は Anthropic から届いた暗号文を記録しておく。
5. phone は、usage が載る部分だけについて「記録された暗号文をこの鍵で復号するとこの平文になる」ことを
   1 通の証明で示す(`ssp/vzk.py`。VOLE-in-the-Head + QuickSilver、自前の実装で第三者の検証は無い)。

## ファイル
- `ssp/relay.py` 中継サーバー、`ssp/phone.py` 端末、`ssp/vzk.py` 証明、`ssp/tlsrec.py` TLS のレコード、
  `ssp/channel.py` phone と relay の間の経路、`ssp/mock.py` 模擬サーバー、`ssp/util.py` 比較用の経路。
- `verify.py` 検証一式。1 項目ごとに PASS / FAIL を出す。

## 動かし方
    pip install tlslite-ng cryptography numpy certifi
    python verify.py --target mock                              # 手元の模擬サーバー(OpenSSL)
    python verify.py --target anthropic                         # 公開の入口、キーなし(API は 401 を返す)
    python verify.py --target anthropic --key-file <キーのファイル> # 本物の応答で全項目

API キー、通信の鍵、暗号文は、出力にも `$DEVBOX_FILES` にも置かない(リポジトリが公開のため)。

## 結果(2026-11-11)
- 模擬サーバー: 24 項目すべて PASS。
- Anthropic の公開の入口(Dev Box から、キーなし): 10 項目すべて PASS。2 世代・3 世代の受け渡しが API に届く、
  KeyUpdate を抜く・古い鍵で書くと拒否される、同じ接続で 8 リクエスト(KeyUpdate 31 回)。
- 本物の応答(200)での項目は未実行。Dev Box の `CLAUDE_AGENT_API_KEY` が Anthropic に 401 で拒否されるため。
