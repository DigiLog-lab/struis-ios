#!/bin/bash
# Starts RealUsageDriverUITests on the Dev Box's Simulator and waits until it takes commands (claude/real-usage-test only).
# usage: ru_start.sh [fresh]   fresh: uninstall the app first (a first install)
set -uo pipefail
RU=${RU_DIR:-$RUNNER_TEMP/ru}
UDID=${RU_UDID:-$SIMULATOR_UDID}
mkdir -p "$RU/drv" "$RU/logs"
pkill -f 'xcodebuild test-without-building.*RealUsageDriverUITests' 2>/dev/null && sleep 3
[[ "${1:-}" == fresh ]] && xcrun simctl uninstall "$UDID" "${RU_BUNDLE_ID:-}" 2>/dev/null
rm -f "$RU/drv/cmd.json" "$RU/drv/result.txt" "$RU/drv/seq"
if [[ ! -x "$RU/venv/bin/python" ]]; then python3 -m venv "$RU/venv" && "$RU/venv/bin/pip" -q install pillow; fi
[[ -f "$RU/camera.jpg" ]] || "$RU/venv/bin/python" "$(dirname "$0")/makepaper.py" "$RU/camera.jpg" "x = 3"
export TEST_RUNNER_STRUIS_E2E_DRIVER_DIR="$RU/drv"
export TEST_RUNNER_STRUIS_E2E_APP_ENV_STRUIS_IOS_USE_FIXTURES=0
export TEST_RUNNER_STRUIS_E2E_APP_ENV_STRUIS_DEVICE_RUNTIME=1
export TEST_RUNNER_STRUIS_E2E_APP_ENV_STRUIS_LEDGER=persistent
export TEST_RUNNER_STRUIS_E2E_APP_ENV_STRUIS_DEBUG_ANTHROPIC_KEY_FILE="$DEVBOX_ANTHROPIC_KEY_FILE"
export TEST_RUNNER_STRUIS_E2E_APP_ENV_STRUIS_TEST_CAMERA_IMAGE="$RU/camera.jpg"
[[ -n "${RU_API_BASE:-}" ]] && export TEST_RUNNER_STRUIS_E2E_APP_ENV_STRUIS_ANTHROPIC_BASE_URL="$RU_API_BASE"
[[ -n "${RU_STORE_KEEP:-}" ]] && export TEST_RUNNER_STRUIS_E2E_STORE_KEEP=1
nohup xcodebuild test-without-building -project strius.xcodeproj -scheme strius -destination "id=$UDID" \
  -derivedDataPath "$DERIVED_DATA" -parallel-testing-enabled NO \
  -only-testing:striusUITests/RealUsageDriverUITests/testDrive > "$RU/logs/driver.log" 2>&1 &
for _ in $(seq 1 180); do
  [[ "$(cat "$RU/drv/result.txt" 2>/dev/null)" == ready ]] && { echo "driver ready"; exit 0; }
  sleep 1
done
echo "driver did not start"; tail -n 40 "$RU/logs/driver.log"; exit 1
