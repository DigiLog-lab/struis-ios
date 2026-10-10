#!/bin/sh

set -eu

if [ "${CI_XCODE_CLOUD:-}" != "TRUE" ]; then
    exit 0
fi

cd "${CI_PRIMARY_REPOSITORY_PATH}"

# Keep host tooling separate from bundled native dependencies.
if ! command -v python3.14 >/dev/null 2>&1; then brew install python@3.14; fi
export PATH="$(brew --prefix python@3.14)/bin:$PATH"
if ! command -v rustup >/dev/null 2>&1; then
    brew install rustup
    export PATH="$(brew --prefix rustup)/bin:$PATH"
fi
rustup toolchain install 1.95.0 --profile minimal
native_platform="${STRUIS_NATIVE_PLATFORM:-}"
if [ -z "$native_platform" ]; then
    case "${CI_WORKFLOW:-}" in
        "Hyotan Native Tests"|"Hyotan Native Runtime Tests"|"Hyotan Native Camera Tests"|"Hyotan Threaded Python Foundation Tests") native_platform=simulator ;;
        *) native_platform=device ;;
    esac
fi
case "$native_platform" in
    device) rustup target add --toolchain 1.95.0 aarch64-apple-ios ;;
    simulator) rustup target add --toolchain 1.95.0 aarch64-apple-ios-sim ;;
    both) rustup target add --toolchain 1.95.0 aarch64-apple-ios aarch64-apple-ios-sim ;;
    *) echo "Unsupported STRUIS_NATIVE_PLATFORM: $native_platform" >&2; exit 1 ;;
esac
export CARGO_HOME="${CARGO_HOME:-$HOME/.cargo}"
export PATH="$CARGO_HOME/bin:$PATH"
# The signed Dash stage pool is a dedicated Simulator preparation, never an
# archive/device default or a model-selected execution option.
if [ "${CI_WORKFLOW:-}" = "Hyotan Native Runtime Tests" ]; then
    [ "$native_platform" = simulator ] || { echo "Compound Dash preparation requires Simulator" >&2; exit 1; }
    export STRUIS_COMPOUND_DASH_PREPARATION=1
fi
echo "Building native runtime for $native_platform"
python3.14 NativeRuntime/Scripts/bootstrap.py --platform "$native_platform"
test -f NativeRuntime/Vendor/NativeCodex.xcframework/Info.plist
if [ "${STRUIS_COMPOUND_DASH_PREPARATION:-0}" = 1 ]; then
    python3.14 scripts/configure_compound_dash_preparation.py
fi

# Large pinned WASM inputs belong only to the dedicated Debug Simulator tests.
# Archive/Release/device workflows never download or package these assets.
if [ "${CI_WORKFLOW:-}" = "Hyotan Native Runtime Tests" ]; then
    [ "$native_platform" = simulator ] || { echo "WK filesystem tests require Simulator preparation" >&2; exit 1; }
    python3.14 NativeRuntime/Scripts/prepare-virtual-python-test-assets.py
    python3.14 NativeRuntime/Scripts/prepare-virtual-git-test-assets.py
fi

# Independent experimental CLI runtime: checked-in fixed assets, no downloads.
if [ "${CI_WORKFLOW:-}" = "Hyotan Native Runtime Tests" ] || [ "${CI_WORKFLOW:-}" = "Hyotan Threaded Python Foundation Tests" ]; then
    [ "$native_platform" = simulator ] || { echo "Threaded WK foundation requires Simulator" >&2; exit 1; }
    if [ -n "${STRUIS_THREADED_PYTHON_ASSETS_DIR:-}" ]; then
        python3.14 scripts/prepare_external_test_inputs.py
        python3.14 NativeRuntime/Scripts/check-threaded-python-foundation-assets.py
        python3.14 NativeRuntime/Scripts/check-threaded-python-command-overlay.py
    else
        echo "SKIP threaded foundation: STRUIS_THREADED_PYTHON_ASSETS_DIR is unset"
    fi
fi

python3.14 scripts/sync_test_resources.py

current_version="$(xcrun agvtool what-version -terse | tail -n 1)"
if [ "${CI_BUILD_NUMBER}" -gt "${current_version}" ]; then
    next_version="${CI_BUILD_NUMBER}"
else
    next_version=$((current_version + 1))
fi

echo "Setting CURRENT_PROJECT_VERSION to ${next_version} (CI_BUILD_NUMBER=${CI_BUILD_NUMBER}, current=${current_version})"
xcrun agvtool new-version -all "${next_version}"
