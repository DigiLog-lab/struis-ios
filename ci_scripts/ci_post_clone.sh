#!/bin/sh
# Temporary probe (branch probe/cloud-host only): can the Xcode Cloud build
# machine run the simulator tests itself? Prints the host, the installed
# simulator runtimes, and how long booting simulators takes, then stops the
# build on purpose so it costs only the clone and this script.
set -u

if [ "${CI_XCODE_CLOUD:-}" != "TRUE" ]; then
    exit 0
fi

echo "PROBE_HOST arch=$(uname -m) ncpu=$(sysctl -n hw.ncpu) perf=$(sysctl -n hw.perflevel0.physicalcpu 2>/dev/null || echo -) eff=$(sysctl -n hw.perflevel1.physicalcpu 2>/dev/null || echo -) mem=$(sysctl -n hw.memsize)"
sw_vers
xcodebuild -version
echo "PROBE_RUNTIMES"
xcrun simctl list runtimes
echo "PROBE_DEVICES"
xcrun simctl list devices available | head -60
df -h / /Volumes/workspace 2>/dev/null

runtime=$(xcrun simctl list runtimes | awk '/^iOS / && /com.apple.CoreSimulator.SimRuntime/ {for (i = 1; i <= NF; i++) if ($i ~ /^com\.apple\.CoreSimulator\.SimRuntime\.iOS/) id = $i} END {print id}')
echo "PROBE_RUNTIME_ID ${runtime:-none}"
if [ -z "${runtime}" ]; then
    echo "PROBE_RESULT no-ios-runtime"
    exit 1
fi

start=$(date +%s)
base=$(xcrun simctl create probe-base "iPhone 16" "$runtime" 2>&1)
echo "PROBE_CREATE ${base} seconds=$(($(date +%s) - start))"
start=$(date +%s)
xcrun simctl boot "$base" && xcrun simctl bootstatus "$base" -b >/dev/null
echo "PROBE_BOOT_FIRST seconds=$(($(date +%s) - start)) status=$?"
xcrun simctl shutdown "$base"

start=$(date +%s)
clones=""
for n in 1 2 3 4 5 6 7 8; do
    clones="$clones $(xcrun simctl clone "$base" "probe-clone-$n")"
done
echo "PROBE_CLONE8 seconds=$(($(date +%s) - start))"
start=$(date +%s)
for udid in $clones; do xcrun simctl boot "$udid" & done
wait
for udid in $clones; do xcrun simctl bootstatus "$udid" -b >/dev/null & done
wait
echo "PROBE_BOOT8 seconds=$(($(date +%s) - start))"
vm_stat | head -12
sysctl vm.swapusage
xcrun simctl list devices booted | head -20
xcrun simctl shutdown all
echo "PROBE_RESULT done"
exit 1
