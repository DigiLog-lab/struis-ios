#!/bin/sh
# Sourced by Xcode Cloud scripts. Keep both successes and failures measurable.
run_stage() {
    stage_name=$1
    shift
    stage_started=$(date +%s)
    echo "STRUIS_STAGE_START name=$stage_name at=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    if "$@"; then stage_result=0; else stage_result=$?; fi
    stage_finished=$(date +%s)
    echo "STRUIS_STAGE_END name=$stage_name elapsed_seconds=$((stage_finished - stage_started)) exit_code=$stage_result at=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    return "$stage_result"
}

cargo_cache_size() {
    cache_size=0
    if [ -d "$CARGO_TARGET_DIR" ]; then cache_size=$(du -sk "$CARGO_TARGET_DIR" | awk '{print $1}'); fi
    echo "STRUIS_CARGO_CACHE phase=$1 kib=$cache_size path=$CARGO_TARGET_DIR"
}
