#!/bin/sh
set -eu

if [ "${CI_XCODE_CLOUD:-}" != "TRUE" ]; then
    exit 0
fi
if [ "${CI_WORKFLOW:-}" != "Hyotan Native TestFlight" ]; then
    exit 0
fi
# The archive audit (NativeRuntime/Scripts/audit-cloud-archive.py) no longer
# gates TestFlight: it added 11-14 minutes per build. Set
# STRUIS_ARCHIVE_AUDIT=1 on the workflow to run it again.
if [ "${STRUIS_ARCHIVE_AUDIT:-0}" = "1" ]; then
    python3 "${CI_PRIMARY_REPOSITORY_PATH}/NativeRuntime/Scripts/audit-cloud-archive.py"
fi
