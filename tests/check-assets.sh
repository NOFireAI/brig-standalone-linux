#!/bin/sh
#
# Run scripts/check-assets.sh against hull-assets bundle.json files written here,
# and check that it passes only assets built from the urunc the bundle carries.

set -eu

here="$(cd "$(dirname "$0")/.." && pwd)"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok() { echo "ok - $*"; }

T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT

urunc=3c00b69ff9ac1b8bb260975cdc63d18a7043558b
urunit=48a61bd480eb57871204523312127b06d0a05363
other=1111111111111111111111111111111111111111

# assets <urunc-source-json>: write the bundle.json hull-assets 0.1.11 ships,
# with the given sources object.
assets() {
    cat > "$T/bundle.json" <<EOF
{
  "schemaVersion": 1,
  "platform": "linux-amd64",
  "version": "0.1.11",
  "kernel": { "file": "bzImage", "version": "6.18.59" },
  "sources": {
    $1
  }
}
EOF
}

check() {
    sh "$here/scripts/check-assets.sh" "$T/bundle.json" "$urunc" "$urunit" > "$T/out" 2> "$T/err"
}

refused() {
    if check; then
        cat "$T/out" "$T/err" >&2
        fail "$2 was accepted"
    fi
    grep -q "$1" "$T/err" || { cat "$T/err" >&2; fail "$2 was refused, but not with '$1'"; }
}

# 1. The bundle.json of hull-assets 0.1.11: urunc matches, no urunit recorded.
assets "\"urunc\": { \"repo\": \"https://github.com/urunc-dev/urunc\", \"ref\": \"$urunc\" }"
check || { cat "$T/err" >&2; fail "matching assets were refused"; }
[ "$(cat "$T/out")" = "$urunc -" ] || fail "printed '$(cat "$T/out")', not the urunc ref and no urunit"
grep -q "records no urunit commit" "$T/err" || fail "a bundle.json without urunit was not reported"
ok "assets built from this urunc pass, and a missing urunit ref is reported"

# 2. Assets built from another urunc are refused.
assets "\"urunc\": { \"repo\": \"https://github.com/urunc-dev/urunc\", \"ref\": \"$other\" }"
refused "built from urunc $other, but this bundle carries urunc $urunc" "assets from another urunc"
ok "assets built from another urunc are refused"

# 3. A recorded urunit must be the one urunc pins.
assets "\"urunc\": { \"repo\": \"https://github.com/urunc-dev/urunc\", \"ref\": \"$urunc\" },
    \"urunit\": { \"repo\": \"https://github.com/NOFireAI/urunit\", \"ref\": \"$other\" }"
refused "carry urunit $other, but urunc $urunc pins urunit $urunit" "assets with another urunit"
assets "\"urunc\": { \"repo\": \"https://github.com/urunc-dev/urunc\", \"ref\": \"$urunc\" },
    \"urunit\": { \"repo\": \"https://github.com/NOFireAI/urunit\", \"ref\": \"$urunit\" }"
check || { cat "$T/err" >&2; fail "assets with the pinned urunit were refused"; }
if grep -q "records no urunit commit" "$T/err"; then fail "a recorded urunit was reported missing"; fi
[ "$(cat "$T/out")" = "$urunc $urunit" ] || fail "printed '$(cat "$T/out")', not both refs"
ok "a recorded urunit must be the one urunc pins"

# 3b. A urunit source whose ref cannot be read is refused, not taken as absent.
assets "\"urunc\": { \"repo\": \"https://github.com/urunc-dev/urunc\", \"ref\": \"$urunc\" },
    \"urunit\": { \"repo\": \"https://github.com/NOFireAI/urunit\", \"build\": { \"arch\": \"amd64\" }, \"ref\": \"$other\" }"
refused "records a urunit source whose ref could not be read" "a urunit source the check cannot read"
ok "an unreadable urunit source is refused"

# 4. No urunc recorded, or no bundle.json at all, is refused.
assets "\"kernel-config\": { \"ref\": \"$urunc\" }"
refused "records no sources.urunc.ref" "a bundle.json without a urunc ref"
rm -f "$T/bundle.json"
refused "is missing" "a missing bundle.json"
ok "assets that do not say which urunc they were built from are refused"
