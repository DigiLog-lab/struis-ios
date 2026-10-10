# source this: E2E settings shared by every script here.
# E2E_UDID   simulator UDID (dedicated device per lane; do not share with other sessions)
# E2E_DIR    work directory (driver mailbox, screenshots, logs, auth copy)
export E2E_REPO="${E2E_REPO:-$(git -C "$(dirname "${(%):-%x}")" rev-parse --show-toplevel)}"
export E2E_TOOLS="${E2E_TOOLS:-$E2E_REPO/scripts/e2e}"
export E2E_DIR="${E2E_DIR:?set E2E_DIR to a work directory}"
export E2E_UDID="${E2E_UDID:?set E2E_UDID to a dedicated simulator}"
mkdir -p "$E2E_DIR/drv" "$E2E_DIR/ev" "$E2E_DIR/logs" "$E2E_DIR/auth"
# The coordinate-based helpers (keytype, pick8, pickfile, the point maths in README) assume the
# iPhone 17 Pro layout (402 × 874 pt). Refuse other device types instead of tapping the wrong place.
if ! xcrun simctl list devices -j | python3 -c "
import json,sys,os
u=os.environ['E2E_UDID']
for rt,devs in json.load(sys.stdin)['devices'].items():
    for d in devs:
        if d['udid']==u: sys.exit(0 if d.get('deviceTypeIdentifier','').endswith('iPhone-17-Pro') else 1)
sys.exit(1)"; then
  echo "E2E_UDID must be an iPhone 17 Pro simulator (coordinate helpers assume its layout)" >&2
  return 1 2>/dev/null || exit 1
fi
