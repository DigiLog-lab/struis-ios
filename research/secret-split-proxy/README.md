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

## 結果(2026-11-11、Dev Box の macOS ランナーから)
本物の Messages API(`claude-haiku-5-5`、公開の入口は Cloudflare)に対して、27 項目すべて PASS。

- 受け渡し: 2 世代(relay の先頭 → phone の本文)、3 世代(relay の先頭 → phone の本文 → relay の末尾)とも HTTP 200。
  KeyUpdate を抜く・末尾を古い世代の鍵で書くと、サーバーが拒否する。
- relay から見えるもの: 要求の目印も応答の目印も無い。渡された鍵で開けられたレコードは 0。
- phone に渡ったもの: API キーも、relay が書いた暗号文も無い。
- JSON の重複キーは後勝ち(同じキーが 2 回あると後ろの値が使われる)。だから model と max_tokens は relay が書く
  末尾に置く。phone が model と max_tokens を足しても relay の値が使われ、末尾を文字列やオブジェクトに飲み込ませる
  本文は 400 になる。
- usage の証明: relay は暗号文の記録と証明 1 通から usage を得て、phone が復号した値と一致。証明から relay が
  知った平文は usage のイベントだけ。別の鍵、違うレコード番号、改ざん 4 種、末尾でない位置、回答文の中の偽の
  usage は、すべて拒否。
- 接続の使い回し: 1 本の TLS 接続で 8 リクエスト、8 回とも証明が通る(KeyUpdate 31 回)。

計測(n=5〜10、phone と relay は同じ機械。片道 40ms の遅延は phone 側の経路に足したもの):

| 条件 | 鍵を世代で分けて渡す | TLS を終端する中継 | 直結 |
|---|---|---|---|
| 新しい接続・文章 1KB: phone 側の通信量 | 74,173 B | 5,803 B | 7,905 B |
| 新しい接続・画像 100KB: phone 側の通信量 | 208,807 B | 138,088 B | 140,168 B |
| 新しい接続・画像 1MB: phone 側の通信量 | 1,414,116 B | 1,339,790 B | 1,341,898 B |
| 新しい接続・文章 1KB: 初回トークンまで(遅延なし) | 0.92 s | 0.94 s | 0.99 s |
| 新しい接続・文章 1KB: 初回トークンまで(片道 40ms) | 1.78 s | 1.52 s | 1.72 s |
| 使い回しの接続・文章 1KB: 初回トークンまで(片道 40ms) | 1.242 s | - | 1.234 s |
| 使い回しの接続・文章 1KB: 証明を除く通信量 | 4,189 B | - | 4,058 B |

- 証明は 1 回 59〜63KB(AES 30 ブロック)。作るのに 1.2〜1.8 秒、確かめるのも同程度(Python、M1 のランナー)。
- 通信量の増分はほぼ証明の分。証明を除くと 1 リクエストあたり約 +130 バイト。

模擬サーバー(`--target mock`)でも同じ項目が PASS。
