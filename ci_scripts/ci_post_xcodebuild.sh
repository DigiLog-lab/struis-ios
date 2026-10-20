#!/bin/sh
set -eu

if [ "${CI_XCODE_CLOUD:-}" != "TRUE" ]; then
    exit 0
fi
echo "STRUIS_XCODEBUILD_FINISHED workflow=${CI_WORKFLOW:-unknown} action=${CI_XCODEBUILD_ACTION:-unknown} at=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
# Test runners receive the hook but have no source checkout or repository-path
# variable. Only the optional archive audit needs repository files.
[ "${CI_XCODEBUILD_ACTION:-}" = archive ] || exit 0
case "${CI_WORKFLOW:-}" in
    "Release"|"Hyotan Native TestFlight") ;;
    *) exit 0 ;;
esac
# The archive audit (NativeRuntime/Scripts/audit-cloud-archive.py) no longer
# gates TestFlight: it added 11-14 minutes per build. Set
# STRUIS_ARCHIVE_AUDIT=1 on the workflow to run it again.
if [ "${STRUIS_ARCHIVE_AUDIT:-0}" = "1" ]; then
    . "${CI_PRIMARY_REPOSITORY_PATH}/ci_scripts/timing.sh"
    run_stage archive-audit python3 "${CI_PRIMARY_REPOSITORY_PATH}/NativeRuntime/Scripts/audit-cloud-archive.py"
fi
