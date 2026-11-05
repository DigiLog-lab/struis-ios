# 実 AI のシミュレータ E2E 道具

アプリは Claude(Anthropic の Messages API)を端末から直接呼ぶ。実機は App Attest で認証するが、Simulator では App Attest を使えない。DEBUG の Simulator だけ、API キーのファイル(`STRUIS_DEBUG_ANTHROPIC_KEY_FILE`)で送る。送り先は `STRUIS_ANTHROPIC_BASE_URL` で模擬サーバー(`fake_anthropic.py`)に替えられる。以前の Codex(ChatGPT のログイン)の手順は無くなった。

## 準備

1. native runtime を作る: `python3.14 NativeRuntime/Scripts/bootstrap.py --platform simulator`(rustup 1.95.0 と iOS targets、automake/libtool が要る)。
2. 専用のシミュレータを作る(他のセッションと共有しない。座標でたたく道具が iPhone 17 Pro の画面を前提にしているので、機種は iPhone 17 Pro に限る): `xcrun simctl create StruisE2E-<名前> "iPhone 17 Pro" com.apple.CoreSimulator.SimRuntime.iOS-27-0`。
3. `export E2E_DIR=<作業ディレクトリ> E2E_UDID=<UDID>; source scripts/e2e/env.sh`。
4. Anthropic の API キーを `$E2E_DIR/anthropic-key` に置く(`chmod 600`)。`run_driver.sh` がこのファイルの場所をアプリに渡す。模擬サーバーだけを使うなら中身は偽のキーでよい。
5. 模擬サーバーを使う場合: `python3 scripts/e2e/fake_anthropic.py --port 8787 --log-dir $E2E_DIR/fake-anthropic &` を起動し、`export STRUIS_ANTHROPIC_BASE_URL=http://127.0.0.1:8787` を設定してから 8 を実行する。本物の API に送る場合は設定しない。
6. `swiftc -O $E2E_TOOLS/ocr.swift -o $E2E_TOOLS/ocr`。
7. `xcodebuild build-for-testing -project strius.xcodeproj -scheme strius -destination id=$E2E_UDID -derivedDataPath $E2E_DIR/dd`。
8. `nohup $E2E_TOOLS/run_driver.sh > $E2E_DIR/logs/driver.log 2>&1 &`(`E2EDriverUITests` が `$E2E_DIR/drv/cmd.json` を待つ)。古い xcodebuild が残っていると取り合うので、先に止める。

## 道具

| 名前 | 役割 |
|---|---|
| `ui.py op key=value` | ランナーへ 1 コマンド(launch / tap / stap(SpringBoard の座標でたたく。アプリの idle を待たない)/ tapid / type / wait / drag / home / terminate / tree / quit) |
| `tr [n]` | アクセシビリティツリーの要約 |
| `say "文"` / `turn "文" [秒]` | 入力欄に打って送る / 送って返事が終わるまで待ち、所要秒数を出す |
| `shot 名前` | `simctl` で画面を撮る(`$E2E_DIR/ev/`) |
| `watch.py UDID 出力先` | 約 2 秒ごとに撮って OCR し、時系列を `watch.tsv` に残す(`STOP` ファイルで止まる) |
| `gaps.py watch.tsv 10 --ignore-counters` | 10 秒を超えて新しい情報が出ない区間を出す(W11 の判定) |
| `paths` | 台帳(`ledger.sqlite`)の場所。`turns.executions` の `requests[]` に要求ごとの記録(理由・状態・トークン・概算料金)が残る |
| `fake_anthropic.py --port 8787 --log-dir 出力先` | Messages API の模擬サーバー(実モデルではない)。現行の Claude が拒む形の要求は 400 で返し、通った要求には決まった応答を SSE で返す。`POST /__control` で場面・`script`/`record`/`replay`・故障(`http`・`drop`・`stall`・`sse_error`・`first_byte_delay`・`trickle`)を切り替える。`trickle` は本文の差分を 1 秒に 1 つ流し続ける(止める操作の確認用)。`record` の転送先のキーは `--upstream-key-file`。`usage` でアプリへ返す usage を上書きする(長い会話の切り替えの確認用)。要求の記録は番号を取った時点で `pending` として書き、転送の失敗も `exception` に残す |
| `redact_records.py --assets … --in … --out …` | 模擬サーバーの記録を、配信の本文(`strius/Resources/Prompts` の行)と認証情報を伏せて写す(artifact に入れる用) |
| `compare_runners.py --server … --outcomes … --out …` | 移行のときの比較(以前の Codex 版と直結版)を模擬サーバーの記録と `RunnerComparisonLiveTests` の結果から `report.md` にまとめる |
| `makematerials.py 出力先` / `makepaper.py out.jpg 行...` / `makedng.py out.dng` | 教材(PDF・画像の境界ケース) / 手書き風の答案画像 / ProRAW の代わりの大きな DNG |
| `keytype 文字` / `pick8` / `pickfile 名前` | 別プロセスのキーボードを座標でたたく / 写真 8 枚を添える / Files から選ぶ |

## 基準シナリオ

1. 単元づくり(PDF なし・あり)→ 全体像 → 要点 → 例題を共同で解く → 類題 → 演習 15 問の判定。
2. 同じ会話で 20 往復(`turn` を繰り返す)。台帳の turns.executions の `first_event_ms`・`first_text_ms`・`turn_tokens`・`requests` を記録する。
3. 質問: 写真 8 枚 / 200 ページ PDF の 150 ページ目 / 壊れたファイル。
4. 生成中にアプリを終了して起動し直す。
5. すべての待ちで `watch.py` を回し、`gaps.py --ignore-counters` で 10 秒を超える空白を数える。
6. 模擬サーバーの故障(`faults`)で、5xx の送り直し・ストリームの切断・止まった答えの扱いを確かめる。

## 落とし穴

- 写真ピッカーと Files は別プロセスのキーボードを使うので、`type` は効かない。`keytype` を使う。
- ビルドし直すとアプリのコンテナのパスが変わる(`paths` で取り直す)。
- 画面外のページにも同じラベルの要素がある。`tapid` は見えている要素を優先する。
- 実機でしか出ない問題(App Attest、裏退避、拡張のメモリ上限)は判定できない。
