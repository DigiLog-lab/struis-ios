#!/bin/sh
set -eu

if [ "${CI_XCODE_CLOUD:-}" != "TRUE" ]; then
    exit 0
fi
# The PR Gate on one machine: a BUILD action on the StruisPRGate scheme runs
# the gate's tests here, on this machine's simulators, before its own build
# (which then only reuses the DerivedData). A TEST action's build machine runs
# build-for-testing, and its test machines have no source checkout, so neither
# comes here. A failed test exits non-zero and fails the action.
if [ "${CI_XCODEBUILD_ACTION:-}" = build ] && [ "${CI_XCODE_SCHEME:-}" = StruisPRGate ]; then
    cd "${CI_PRIMARY_REPOSITORY_PATH}"
    exec /usr/bin/python3 scripts/ci/cloud_gate_tests.py
fi
