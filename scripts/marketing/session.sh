#!/bin/bash
# 宣伝用の収録の下準備(Dev Box で動かす)。模擬サーバーと E2E の操作役を裏で起動し、次の命令を待たせる。
#
#   scripts/marketing/session.sh start record <録音の名前>   本物の Claude に転送して録音する(要求の種類ごとの順)
#   scripts/marketing/session.sh start replay <録音の名前>   録音した返事を同じ間隔で返す
#   scripts/marketing/session.sh stop                         模擬サーバーと操作役を止め、録音を $DEVBOX_FILES に置く
#
# 作業場所は $MARKETING_DIR(既定 $RUNNER_TEMP/marketing)。録音は作業ツリーの外($MARKETING_DIR/tapes)に録り、
# replay の時はリポジトリの scripts/marketing/tapes/<名前> から写す(Dev Box は命令のたびに作業ブランチを取り込むので、
# 作業ツリーの中に録ると取り込みとぶつかる)。アプリに渡す API キーは偽物で、本物のキー($DEVBOX_ANTHROPIC_KEY_FILE)は
# 模擬サーバーの転送先にだけ使う(アプリにも記録にも出ない)。
set -uo pipefail
# 裏で起動するものは自分のプロセスグループに入れ、命令が終わっても残す(macOS に setsid は無い)。
set -m
ROOT="$(git -C "$(dirname "$0")" rev-parse --show-toplevel)"
W="${MARKETING_DIR:-${RUNNER_TEMP:-/tmp}/marketing}"
UDID="${SIMULATOR_UDID:?SIMULATOR_UDID が無い(Dev Box で動かす)}"
PORT=8787
mkdir -p "$W/drv" "$W/logs" "$W/shots" "$W/tapes"

stop() {
  if [[ -f "$W/drv/result.txt" ]] && pgrep -f "E2EDriverUITests" >/dev/null; then
    E2E_DIR="$W" python3 "$ROOT/scripts/e2e/ui.py" quit timeout=5 >/dev/null 2>&1 || true
  fi
  for name in driver fake; do
    if [[ -f "$W/$name.pid" ]]; then
      kill -- "-$(cat "$W/$name.pid")" 2>/dev/null || kill "$(cat "$W/$name.pid")" 2>/dev/null || true
      rm -f "$W/$name.pid"
    fi
  done
  pkill -f "E2EDriverUITests/testDrive" 2>/dev/null || true
  xcrun simctl status_bar "$UDID" clear >/dev/null 2>&1 || true
  if [[ -n "${DEVBOX_FILES:-}" ]] && [[ -n "$(ls -A "$W/tapes" 2>/dev/null)" ]]; then
    mkdir -p "$DEVBOX_FILES"
    tar -C "$W/tapes" -czf "$DEVBOX_FILES/tapes.tgz" .
  fi
}

start() {
  local mode="$1" tape="$2"
  stop
  rm -rf "$W/drv"/* "$W/fake"
  if [[ "$mode" == replay ]]; then
    [[ -d "$ROOT/scripts/marketing/tapes/$tape" ]] || { echo "録音が無い: scripts/marketing/tapes/$tape" >&2; exit 1; }
    rm -rf "$W/tapes/$tape"; cp -R "$ROOT/scripts/marketing/tapes/$tape" "$W/tapes/$tape"
  else
    rm -rf "$W/tapes/$tape"
  fi
  printf 'sk-fake-for-the-simulator' > "$W/app-key"; chmod 600 "$W/app-key"

  # 模擬サーバー(Messages API)。
  nohup python3 "$ROOT/scripts/e2e/fake_anthropic.py" --port "$PORT" --log-dir "$W/fake" --tape-dir "$W/tapes" \
    ${DEVBOX_ANTHROPIC_KEY_FILE:+--upstream-key-file "$DEVBOX_ANTHROPIC_KEY_FILE"} > "$W/logs/fake.log" 2>&1 < /dev/null &
  echo $! > "$W/fake.pid"
  for _ in $(seq 1 50); do curl -sf "http://127.0.0.1:$PORT/__health" >/dev/null && break; sleep 0.2; done
  curl -sf -X POST "http://127.0.0.1:$PORT/__control" -H 'content-type: application/json' \
    -d "{\"mode\":\"$mode\",\"tape\":\"$tape\",\"match\":\"kind\"}" >/dev/null || { echo "模擬サーバーが起動しない" >&2; cat "$W/logs/fake.log"; exit 1; }

  # 画面上部の表示を揃える(宣伝の映像で時刻や電池が毎回変わらないように)。
  xcrun simctl status_bar "$UDID" override --time "9:41" --dataNetwork wifi --wifiMode active --wifiBars 3 \
    --cellularMode active --cellularBars 4 --batteryState charged --batteryLevel 100 >/dev/null 2>&1 || true
  xcrun simctl ui "$UDID" appearance dark >/dev/null 2>&1 || true

  # E2E の操作役(E2EDriverUITests)。アプリへの環境変数は STRUIS_E2E_APP_ENV_ を付けて渡す。
  local xctestrun
  xctestrun="$(ls "$DERIVED_DATA"/Build/Products/*.xctestrun | head -1)"
  (
    export TEST_RUNNER_STRUIS_E2E_DRIVER_DIR="$W/drv"
    export TEST_RUNNER_STRUIS_E2E_APP_ENV_STRUIS_START_SCREEN=timeline
    export TEST_RUNNER_STRUIS_E2E_APP_ENV_STRUIS_DEVICE_RUNTIME=1
    export TEST_RUNNER_STRUIS_E2E_APP_ENV_STRUIS_LEDGER=memory
    export TEST_RUNNER_STRUIS_E2E_APP_ENV_STRUIS_ICLOUD_SYNC=off
    export TEST_RUNNER_STRUIS_E2E_APP_ENV_STRUIS_PLAN=generous
    export TEST_RUNNER_STRUIS_E2E_APP_ENV_STRUIS_USAGE_PERCENT=0
    export TEST_RUNNER_STRUIS_E2E_APP_ENV_STRUIS_DEBUG_ANTHROPIC_KEY_FILE="$W/app-key"
    export TEST_RUNNER_STRUIS_E2E_APP_ENV_STRUIS_ANTHROPIC_BASE_URL="http://127.0.0.1:$PORT"
    export TEST_RUNNER_STRUIS_E2E_APP_ENV_STRUIS_TEST_CAMERA_IMAGE="$W/camera.jpg"
    exec nohup xcodebuild test-without-building -xctestrun "$xctestrun" -destination "id=$UDID" \
      -parallel-testing-enabled NO -only-testing:striusUITests/E2EDriverUITests/testDrive > "$W/logs/driver.log" 2>&1 < /dev/null
  ) &
  echo $! > "$W/driver.pid"
  for _ in $(seq 1 120); do grep -q '^ready' "$W/drv/result.txt" 2>/dev/null && break; sleep 1; done
  if ! grep -q '^ready' "$W/drv/result.txt" 2>/dev/null; then
    echo "操作役が起動しない" >&2; tail -40 "$W/logs/driver.log" >&2; exit 1
  fi
  echo "started: mode=$mode tape=$tape dir=$W"
}

case "${1:-}" in
  start) start "${2:?record か replay}" "${3:?録音の名前}" ;;
  stop) stop; echo stopped ;;
  *) echo "usage: $0 start record|replay <name> | stop" >&2; exit 2 ;;
esac
