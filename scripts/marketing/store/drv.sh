#!/bin/bash
# App Store のスクショ撮影(Dev Box)。AI の返事は模擬(STRUIS_DEVICE_TURNS=mock)で、E2E の操作役を指定のシミュレータで起動する。
#   drv.sh start <udid> [NAME=VALUE ...]   アプリへの環境変数を足して操作役を起動する(前のものは止める)
#   drv.sh stop
#   drv.sh ui <op> [key=value ...]         操作役に命令を1つ送る
#   drv.sh shot <udid> <名前>              画面を $DEVBOX_FILES/<名前>.png に撮る
set -uo pipefail
set -m
ROOT="$(git -C "$(dirname "$0")" rev-parse --show-toplevel)"
W="${RUNNER_TEMP:-/tmp}/store"
mkdir -p "$W/drv" "$W/logs"
stop() {
  if [[ -f "$W/driver.pid" ]]; then
    E2E_DIR="$W" timeout 20 python3 "$ROOT/scripts/e2e/ui.py" quit timeout=5 >/dev/null 2>&1 || true
    kill -- "-$(cat "$W/driver.pid")" 2>/dev/null || kill "$(cat "$W/driver.pid")" 2>/dev/null || true
    rm -f "$W/driver.pid"
  fi
  pkill -f "E2EDriverUITests/testDrive" 2>/dev/null || true
  sleep 1
}
case "${1:-}" in
  start)
    udid="$2"; shift 2
    stop
    rm -rf "$W/drv"/*
    xcrun simctl status_bar "$udid" override --time "9:41" --dataNetwork wifi --wifiMode active --wifiBars 3 \
      --cellularMode active --cellularBars 4 --batteryState charged --batteryLevel 100 >/dev/null 2>&1 || true
    xcrun simctl ui "$udid" appearance light >/dev/null 2>&1 || true
    xctestrun="$(ls "$DERIVED_DATA"/Build/Products/*.xctestrun | head -1)"
    (
      export TEST_RUNNER_STRUIS_E2E_DRIVER_DIR="$W/drv"
      export TEST_RUNNER_STRUIS_E2E_APP_ENV_STRUIS_START_SCREEN=timeline
      export TEST_RUNNER_STRUIS_E2E_APP_ENV_STRUIS_DEVICE_TURNS=mock
      export TEST_RUNNER_STRUIS_E2E_APP_ENV_STRUIS_DEVICE_RUNTIME=0
      export TEST_RUNNER_STRUIS_E2E_APP_ENV_STRUIS_TEST_CAMERA_IMAGE="$W/camera.jpg"
      export TEST_RUNNER_STRUIS_E2E_APP_ENV_STRUIS_TEST_CAPTURE_FINISH_SECONDS=0.5
      for kv in "$@"; do export "TEST_RUNNER_STRUIS_E2E_APP_ENV_${kv%%=*}=${kv#*=}"; done
      exec nohup xcodebuild test-without-building -xctestrun "$xctestrun" -destination "id=$udid" \
        -parallel-testing-enabled NO -only-testing:striusUITests/E2EDriverUITests/testDrive > "$W/logs/driver.log" 2>&1 < /dev/null
    ) &
    echo $! > "$W/driver.pid"
    for _ in $(seq 1 240); do grep -q '^ready' "$W/drv/result.txt" 2>/dev/null && break; sleep 1; done
    grep -q '^ready' "$W/drv/result.txt" 2>/dev/null || { echo "操作役が起動しない" >&2; tail -40 "$W/logs/driver.log" >&2; exit 1; }
    echo started ;;
  stop) stop; echo stopped ;;
  ui) shift; E2E_DIR="$W" python3 "$ROOT/scripts/e2e/ui.py" "$@" ;;
  cam) cp "$ROOT/$2" "$W/camera.jpg" && echo ok ;;
  shot) mkdir -p "$DEVBOX_FILES"; xcrun simctl io "$2" screenshot "$DEVBOX_FILES/$3.png" >/dev/null 2>&1 && echo "$3.png" ;;
  *) echo "usage" >&2; exit 2 ;;
esac
