#!/bin/sh
#
# Install a minimal fake bundle as a user install, against stubs for the host
# checks, and check what the summary calls it.
#
# Needs a normal user with a subuid range, on Linux.

set -eu

here="$(cd "$(dirname "$0")/.." && pwd)"
user="$(id -un)"

skip() { echo "SKIP: $*"; exit 0; }
fail() { echo "FAIL: $*" >&2; exit 1; }
ok() { echo "ok - $*"; }

[ "$(uname -s)" = Linux ] || skip "install.sh installs on Linux only"
[ "$(id -u)" -ne 0 ] || skip "a user install refuses root; run this as a normal user"
grep -q "^$user:" /etc/subuid 2>/dev/null || skip "no subuid range for $user"
grep -q "^$user:" /etc/subgid 2>/dev/null || skip "no subgid range for $user"

T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/stub" "$T/home" "$T/run"

# A bundle with the rootless path, a brig of its own, and a setup that only
# says it ran.
bdir="$T/brig-standalone-v9.9.9-rootless-linux"
mkdir -p "$bdir/bin" "$bdir/etc"
printf '#!/bin/sh\necho setup-ran\n' > "$bdir/bin/brig-rootless-setup.sh"
printf '#!/bin/sh\necho brig 0.2.0\n' > "$bdir/bin/brig"
chmod 0755 "$bdir/bin"/*
: > "$bdir/etc/brig-env.sh"
cat > "$bdir/pins.env" <<'PINS'
BUNDLE_VERSION=v9.9.9
BRIG_VERSION=v0.2.0
ROOTLESS=true
PINS
tar -C "$T" -czf "$T/bundle.tar.gz" "${bdir##*/}"

# The host checks pass: this user holds the device ACL, no AppArmor profile is
# needed, and no module is missing. Whatever else this host lacks, sudo -n
# answers yes, so the install goes on; the stub setup never calls it.
cat > "$T/stub/getfacl" <<STUB
#!/bin/sh
echo "user:$user:rw-"
STUB
printf '#!/bin/sh\necho 0\n' > "$T/stub/sysctl"
printf '#!/bin/sh\n[ "$*" = "-n true" ]\n' > "$T/stub/sudo"
printf '#!/bin/sh\nexit 1\n' > "$T/stub/modinfo"
for b in newuidmap setfacl systemctl; do
    printf '#!/bin/sh\nexit 0\n' > "$T/stub/$b"
done
chmod 0755 "$T/stub"/*

if ! env -u XDG_CONFIG_HOME -u XDG_DATA_HOME \
    HOME="$T/home" XDG_RUNTIME_DIR="$T/run" PATH="$T/stub:$PATH" \
    INSTALL_BRIG_BUNDLE="$T/bundle.tar.gz" \
    sh "$here/install.sh" > "$T/out.log" 2>&1; then
    cat "$T/out.log" >&2
    fail "the install failed"
fi
grep -q setup-ran "$T/out.log" || { cat "$T/out.log" >&2; fail "the rootless setup did not run"; }

grep -q "the brig runtime bundle v9.9.9 is installed (user)" "$T/out.log" \
    || { cat "$T/out.log" >&2; fail "the summary does not name the bundle"; }
if grep -q "brig v9.9.9" "$T/out.log"; then
    fail "the summary gives brig the bundle's version"
fi
ok "the summary names the bundle and its version"
