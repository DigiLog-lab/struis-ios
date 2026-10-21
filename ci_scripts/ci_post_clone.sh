#!/bin/sh

set -eu

if [ "${CI_XCODE_CLOUD:-}" != "TRUE" ]; then
    exit 0
fi

cd "${CI_PRIMARY_REPOSITORY_PATH}"
. ./ci_scripts/timing.sh
clone_started=$(date +%s)
trap 'clone_result=$?; echo "STRUIS_POST_CLONE elapsed_seconds=$(($(date +%s) - clone_started)) exit_code=$clone_result"' EXIT
echo "STRUIS_HOST workflow=${CI_WORKFLOW:-unknown} action=${CI_XCODEBUILD_ACTION:-unknown} build=${CI_BUILD_ID:-unknown}"
uname -m
sysctl -n hw.ncpu hw.memsize
xcodebuild -version

# Xcode Cloud retains DerivedData between non-clean builds. The Rust builder
# already accepts CARGO_TARGET_DIR, so keep its incremental output there too.
if [ -n "${CI_DERIVED_DATA_PATH:-}" ]; then
    export CARGO_TARGET_DIR="${CI_DERIVED_DATA_PATH}/StruisNative/cargo"
else
    export CARGO_TARGET_DIR="${CARGO_TARGET_DIR:-${CI_PRIMARY_REPOSITORY_PATH}/NativeRuntime/.build/codex}"
    echo "STRUIS_CARGO_CACHE persistence=unavailable reason=CI_DERIVED_DATA_PATH-is-unset"
fi
cargo_cache_size before

# Keep host tooling separate from bundled native dependencies.
if ! command -v python3.14 >/dev/null 2>&1; then run_stage python-toolchain brew install python@3.14; fi
export PATH="$(brew --prefix python@3.14)/bin:$PATH"
# Apple's system Ruby does not include xcodeproj. Prepare host-only gems before
# the expensive native build, and keep them outside the packaged runtime.
ruby_prefix="$(brew --prefix ruby@3.4)"
if [ ! -x "$ruby_prefix/bin/ruby" ]; then run_stage ruby-toolchain brew install ruby@3.4; fi
export PATH="$ruby_prefix/bin:$PATH"
ruby_abi="$(ruby -e 'require "rbconfig"; print RbConfig::CONFIG.fetch("ruby_version")')"
export GEM_HOME="${CI_DERIVED_DATA_PATH:-${TMPDIR:-/tmp}}/StruisHostTools/ruby-$ruby_abi"
export GEM_PATH="$GEM_HOME"
if ! ruby -e 'gem "xcodeproj", "1.27.0"; require "xcodeproj"' >/dev/null 2>&1; then
    run_stage ruby-gems gem install xcodeproj --version 1.27.0 --no-document --install-dir "$GEM_HOME"
fi
run_stage ruby-check ruby -e 'gem "xcodeproj", "1.27.0"; require "xcodeproj"; puts "STRUIS_RUBY version=#{RUBY_VERSION} xcodeproj=#{Xcodeproj::VERSION}"'
cloud_test_tier=""
case "${CI_XCODE_SCHEME:-}" in
    StruisPRGate) cloud_test_tier=pr ;;
    StruisRelease) cloud_test_tier=full ;;
    *)
        case "${CI_WORKFLOW:-}" in
            "PR Gate") cloud_test_tier=pr ;;
            "Release") cloud_test_tier=full ;;
        esac
        ;;
esac
native_platform="${STRUIS_NATIVE_PLATFORM:-}"
if [ -z "$native_platform" ]; then
    case "$cloud_test_tier" in
        pr) native_platform=simulator ;;
        full) native_platform=both ;;
        *)
            case "${CI_WORKFLOW:-}" in
                "Hyotan Native Tests"|"Hyotan Native Runtime Tests"|"Hyotan Native Camera Tests"|"Hyotan Threaded Python Foundation Tests") native_platform=simulator ;;
                *) native_platform=device ;;
            esac
            ;;
    esac
fi
case "$native_platform" in
    device|simulator|both) ;;
    *) echo "Unsupported STRUIS_NATIVE_PLATFORM: $native_platform" >&2; exit 1 ;;
esac
# The signed Dash stage pool is a dedicated Simulator preparation, never an
# archive/device default or a model-selected execution option.
if [ "${CI_WORKFLOW:-}" = "Hyotan Native Runtime Tests" ]; then
    [ "$native_platform" = simulator ] || { echo "Compound Dash preparation requires Simulator" >&2; exit 1; }
    export STRUIS_COMPOUND_DASH_PREPARATION=1
fi
# PR Gate and Release reuse the outputs that agent-native-cache.yml built on
# GitHub for the same NativeRuntime inputs (both SDKs), verified by SHA-256.
# Anything else, or an input set not published yet, builds from source.
native_source=build
if [ -n "$cloud_test_tier" ] && [ "${STRUIS_NATIVE_PREBUILT:-1}" = 1 ]; then
    rm -f NativeRuntime/.prebuilt.json
    run_stage native-prebuilt python3.14 scripts/ci/native_prebuilt.py apply || true
    if [ -f NativeRuntime/.prebuilt.json ]; then native_source=prebuilt; fi
fi
echo "STRUIS_NATIVE_SOURCE source=$native_source platform=$native_platform"
if [ "$native_source" = build ]; then
    if ! command -v rustup >/dev/null 2>&1; then
        run_stage rustup-install brew install rustup
        export PATH="$(brew --prefix rustup)/bin:$PATH"
    fi
    run_stage rust-toolchain rustup toolchain install 1.95.0 --profile minimal
    case "$native_platform" in
        device) rustup target add --toolchain 1.95.0 aarch64-apple-ios ;;
        simulator) rustup target add --toolchain 1.95.0 aarch64-apple-ios-sim ;;
        both) rustup target add --toolchain 1.95.0 aarch64-apple-ios aarch64-apple-ios-sim ;;
    esac
    export CARGO_HOME="${CARGO_HOME:-$HOME/.cargo}"
    export PATH="$CARGO_HOME/bin:$PATH"
    echo "Building native runtime for $native_platform"
    run_stage native-inputs python3.14 scripts/ci/prefetch_native.py --platform "$native_platform"
    run_stage native-bootstrap python3.14 NativeRuntime/Scripts/bootstrap.py --platform "$native_platform"
fi
cargo_cache_size after
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

run_stage test-resources python3.14 scripts/sync_test_resources.py

# The original strius scheme stays independent of these plans. Unknown or
# unavailable base refs expand PR Gate to every eligible UI test.
case "$cloud_test_tier" in
    pr)
        run_stage pr-test-plan python3.14 scripts/ci/xcode_test_plan.py --tier pr \
            --base "${CI_PULL_REQUEST_TARGET_BRANCH:-main}" \
            --output TestPlans/PRGate.xctestplan \
            --report "${CI_DERIVED_DATA_PATH:-${TMPDIR:-/tmp}}/struis-pr-test-selection.json"
        ;;
    full)
        run_stage release-test-plan python3.14 scripts/ci/xcode_test_plan.py --tier full \
            --output TestPlans/Release.xctestplan \
            --report "${CI_DERIVED_DATA_PATH:-${TMPDIR:-/tmp}}/struis-release-test-selection.json"
        ;;
esac

current_version="$(xcrun agvtool what-version -terse | tail -n 1)"
if [ "${CI_BUILD_NUMBER}" -gt "${current_version}" ]; then
    next_version="${CI_BUILD_NUMBER}"
else
    next_version=$((current_version + 1))
fi

echo "Setting CURRENT_PROJECT_VERSION to ${next_version} (CI_BUILD_NUMBER=${CI_BUILD_NUMBER}, current=${current_version})"
run_stage build-number xcrun agvtool new-version -all "${next_version}"
