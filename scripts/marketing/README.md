# 宣伝の映像の収録

実際のアプリをシミュレータで決まった手順どおりに動かして録画し、編集(文字・端末の枠・音)は Claude の環境の ffmpeg でやる。
App Store のプレビュー動画は「アプリそのものの画面収録」しか使えない(App Review Guidelines 2.3.4)ので、画面は描き起こさない。

## 流れ

1. **録音**(初回と、タイムラインの見た目や出題が変わった時だけ): Dev Box で本物の Claude に通しで解き、返事を録る。
   ```
   mac.py run -- 'scripts/marketing/session.sh start record demo1 && python3 scripts/marketing/step.py launch'
   mac.py run -- 'python3 scripts/marketing/step.py answer scripts/marketing/answers/demo1/01.jpg'   # 答案の画像はブランチに置いてから
   mac.py run -- 'python3 scripts/marketing/step.py next'
   ...
   mac.py run -- 'scripts/marketing/session.sh stop'      # 録音が $DEVBOX_FILES/tapes.tgz に届く → scripts/marketing/tapes/ に置く
   ```
2. **撮影**: 録音を再生しながら、同じ手順で解いて録画する(1回数分)。
   ```
   mac.py run -- 'python3 scripts/marketing/take.py scripts/marketing/takes/demo1.json'   # take.mp4 と take.json が届く
   ```
3. **編集**(Dev Box は使わない): `MARKETING_OUT=/tmp/out python3 scripts/marketing/edit/edit.py take.mp4`。
   切り口の違う4案は `python3 scripts/marketing/edit/variants.py A take.mp4`(A〜D)。同じ録画から作るので、撮り直しは要らない。

## 仕組み

- **返事の固定**: `scripts/e2e/fake_anthropic.py` の `record` / `replay` を `match: kind` で使う。タイムラインは次のカードの束・
  見直し・知識グラフの要求を裏で同時に送るので、届いた順で対応させると入れ替わる。出力の形(JSON Schema)が同じ要求を同じ種類とし、
  種類ごとの順で対応させる。同じ手順で解けば、同じ問題・同じ採点が返る(2026-11-11 に demo1 の5問で確かめた)。
- **API キー**: アプリには偽のキーを渡し、本物のキー(`$DEVBOX_ANTHROPIC_KEY_FILE`)は模擬サーバーの転送先にだけ使う。
- **答案の写真**: シミュレータにカメラが無いので `STRUIS_TEST_CAMERA_IMAGE` を使う。アプリは撮るたびにファイルを読み直す
  (`ChatCamera.swift` の `testPhoto`)ので、撮る直前に差し替える。画像は `answer.py`(Klee One、SIL Open Font License)で作る。
  Dev Box には Pillow が無いので、Claude の環境で作ってブランチに置く。
- **操作**: E2E の操作役(`striusUITests/E2EDriverUITests`)に `scripts/e2e/ui.py` で命令を送る。識別子(`timeline-capture` など)
  だけでたたくので、Dev Box の iPhone 17 のままでよい(座標でたたく道具は使わない)。
- **画面の上部**: `simctl status_bar` で 9:41・電池満タンに固定、外観はダーク。
- **録画**: `xcrun simctl io recordVideo` は可変フレームレートで、そのまま区間を頭出しするとずれる。編集の最初に 30fps に直す。

## ファイル

| 名前 | 役割 |
|---|---|
| `session.sh` | 模擬サーバーと操作役を裏で起動する・止める(Dev Box) |
| `step.py` | 起動・問題を読む・答案を撮る・次へ(Dev Box) |
| `take.py` | 録音を再生しながら手順どおりに解いて録画する(Dev Box) |
| `takes/*.json` | 撮影の手順(録音の名前、答案の順、各場面を見せる秒数) |
| `tapes/<名前>/` | 録音(種類ごとの返事。秘密の値は入らない) |
| `answers/<名前>/` | 答案の写真 |
| `answer.py` | 手書き風の答案の写真を作る(Claude の環境) |
| `edit/` | 編集(Claude の環境)。`edit.py` は基本の1本、`variants.py` は4案 |
