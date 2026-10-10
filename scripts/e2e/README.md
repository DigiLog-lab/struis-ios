# 実 Codex のシミュレータ E2E 道具

## 準備

1. native runtime を作る: `python3.14 NativeRuntime/Scripts/bootstrap.py --platform simulator`(rustup 1.95.0 と iOS targets、automake/libtool が要る)。
2. 専用のシミュレータを作る(他のセッションと共有しない。座標でたたく道具が iPhone 17 Pro の画面を前提にしているので、機種は iPhone 17 Pro に限る): `xcrun simctl create StruisE2E-<名前> "iPhone 17 Pro" com.apple.CoreSimulator.SimRuntime.iOS-27-0`。
3. `export E2E_DIR=<作業ディレクトリ> E2E_UDID=<UDID>; source scripts/e2e/env.sh`。
4. `cp ~/.codex/auth.json $E2E_DIR/auth/auth.json; cp ~/.codex/auth.json $E2E_DIR/auth/mac-auth-backup.json`(アプリは起動のたびにこの作業コピーを注入する。ゲスト側で更新されたら`syncauth`で作業コピーだけに反映する。元のMac認証には書き戻さない)。
5. `swiftc -O $E2E_TOOLS/ocr.swift -o $E2E_TOOLS/ocr`。
6. `xcodebuild build-for-testing -project strius.xcodeproj -scheme strius -destination id=$E2E_UDID -derivedDataPath $E2E_DIR/dd`。
7. `nohup $E2E_TOOLS/run_driver.sh > $E2E_DIR/logs/driver.log 2>&1 &`(`E2EDriverUITests` が `$E2E_DIR/drv/cmd.json` を待つ)。古い xcodebuild が残っていると取り合うので、先に止める。

## 道具

| 名前 | 役割 |
|---|---|
| `ui.py op key=value` | ランナーへ 1 コマンド(launch / tap / tapid / type / wait / drag / home / terminate / tree / quit) |
| `tr [n]` | アクセシビリティツリーの要約 |
| `say "文"` / `turn "文" [秒]` | 入力欄に打って送る / 送って返事が終わるまで待ち、所要秒数を出す |
| `shot 名前` | `simctl` で画面を撮る(`$E2E_DIR/ev/`) |
| `watch.py UDID 出力先` | 約 2 秒ごとに撮って OCR し、時系列を `watch.tsv` に残す(`STOP` ファイルで止まる) |
| `gaps.py watch.tsv 10 --ignore-counters` | 10 秒を超えて新しい情報が出ない区間を出す(W11 の判定) |
| `rollout.py rollout.jsonl [n]` / `newest` / `paths` | Codex の rollout の要約 / 最新の rollout / 台帳と Codex home の場所 |
| `correlate.py <codex home> <app-activity.log> [始 終]` | 画面に出した段(アプリの `turn-activity` の記録)と rollout の出来事を時刻順に並べる(偽の段が無いかの確認) |
| `makematerials.py 出力先` / `makepaper.py out.jpg 行...` | 教材(PDF・画像の境界ケース) / 手書き風の答案画像 |
| `keytype 文字` / `pick8` / `pickfile 名前` | 別プロセスのキーボードを座標でたたく / 写真 8 枚を添える / Files から選ぶ |
| `syncauth` | ゲストの auth.json が更新されていたら作業コピーへ持ち帰る |

## 基準シナリオ

1. 単元づくり(PDF なし・あり)→ 全体像 → 要点 → 例題を共同で解く → 類題 → 演習 15 問の判定。
2. 同じ会話で 20 往復(`turn` を繰り返す)。台帳の turns.executions の `first_event_ms`・`first_text_ms`・`compactions`・`usage` を記録する。
3. 質問: 写真 8 枚 / 200 ページ PDF の 150 ページ目 / 壊れたファイル。
4. 生成中にアプリを終了して起動し直す。
5. すべての待ちで `watch.py` を回し、`gaps.py --ignore-counters` で 10 秒を超える空白を数える。

## 落とし穴

- 写真ピッカーと Files は別プロセスのキーボードを使うので、`type` は効かない。`keytype` を使う。
- ビルドし直すとアプリのコンテナのパスが変わる(`paths` で取り直す)。
- 画面外のページにも同じラベルの要素がある。`tapid` は見えている要素を優先する。
- 実機でしか出ない問題(裏退避、拡張のメモリ上限)は判定できない。
