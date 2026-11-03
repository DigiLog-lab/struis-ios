#!/bin/zsh
# starts E2EDriverUITests on StruisNight1003 (blocks until quit)
U=$E2E_UDID
rm -f $E2E_DIR/drv/cmd.json $E2E_DIR/drv/result.txt
export TEST_RUNNER_STRUIS_E2E_DRIVER_DIR=$E2E_DIR/drv
export TEST_RUNNER_STRUIS_E2E_APP_ENV_STRUIS_IOS_USE_FIXTURES=0
export TEST_RUNNER_STRUIS_E2E_APP_ENV_STRUIS_DEVICE_RUNTIME=1
export TEST_RUNNER_STRUIS_E2E_APP_ENV_STRUIS_LEDGER=persistent
# Claude: the DEBUG Simulator sends with an API key file (App Attest is device-only), optionally via the fake server.
export TEST_RUNNER_STRUIS_E2E_APP_ENV_STRUIS_DEBUG_ANTHROPIC_KEY_FILE=$E2E_DIR/anthropic-key
if [ -n "${STRUIS_ANTHROPIC_BASE_URL:-}" ]; then
  export TEST_RUNNER_STRUIS_E2E_APP_ENV_STRUIS_ANTHROPIC_BASE_URL="$STRUIS_ANTHROPIC_BASE_URL"
fi
# By default the app fetches delivery assets from the configured service.
if [ -n "${STRUIS_DEVICE_ASSETS_DIR:-}" ]; then
  export TEST_RUNNER_STRUIS_E2E_APP_ENV_STRUIS_DEVICE_ASSETS_DIR="$STRUIS_DEVICE_ASSETS_DIR"
fi
export TEST_RUNNER_STRUIS_E2E_APP_ENV_STRUIS_TEST_CAMERA_IMAGE=$E2E_DIR/camera.jpg
exec xcodebuild test-without-building -project $E2E_REPO/strius.xcodeproj -scheme strius -destination id=$U -derivedDataPath $E2E_DIR/dd -parallel-testing-enabled NO -only-testing:striusUITests/E2EDriverUITests/testDrive
