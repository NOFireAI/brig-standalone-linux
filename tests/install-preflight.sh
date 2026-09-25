#!/bin/sh
#
# Run install.sh as a user install against stubs and check where it stops when
# the host is not prepared. The bundle it is pointed at does not exist, so a
# run that gets past the preflight fails on the fetch, and says so.
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

# sudo: only -n true can succeed, and only when the test says sudo works.
cat > "$T/stub/sudo" <<STUB
#!/bin/sh
echo "\$*" >> "$T/sudo.log"
[ "\$*" = "-n true" ] && [ -f "$T/sudo-ok" ] && exit 0
exit 1
STUB

# getfacl and sysctl answer from files the test sets.
cat > "$T/stub/getfacl" <<STUB
#!/bin/sh
echo "user::rw-"
[ -f "$T/granted" ] && echo "user:$user:rw-"
echo "group::rw-"
STUB
cat > "$T/stub/sysctl" <<STUB
#!/bin/sh
if [ -f "$T/apparmor" ]; then echo 1; else echo 0; fi
STUB

# stat: the devices are 0660, whatever this host has them at.
cat > "$T/stub/stat" <<'STUB'
#!/bin/sh
if [ "$1" = -c ] && [ "$2" = %a ]; then
    case "$3" in /dev/*) echo 660; exit 0 ;; esac
fi
exec /usr/bin/stat "$@"
STUB

# modinfo: no module is missing but loadable, so the result does not depend on
# what this kernel has loaded.
printf '#!/bin/sh\nexit 1\n' > "$T/stub/modinfo"
for b in newuidmap setfacl systemctl; do
    printf '#!/bin/sh\nexit 0\n' > "$T/stub/$b"
done
chmod 0755 "$T/stub"/*

run_install() {
    : > "$T/sudo.log"
    set +e
    env -u XDG_CONFIG_HOME -u XDG_DATA_HOME \
        HOME="$T/home" XDG_RUNTIME_DIR="$T/run" PATH="$T/stub:$PATH" \
        INSTALL_BRIG_BUNDLE="$T/no-such-bundle.tar.gz" \
        sh "$here/install.sh" > "$T/out.log" 2>&1
    rc=$?
    set -e
}

prefix="$T/home/.local/share/brig/data"

# 1. Not prepared, and no sudo: stop before anything is fetched, and print the
#    root commands for this user and this prefix.
touch "$T/apparmor"
run_install
[ "$rc" -ne 0 ] || fail "the install succeeded on a host that is not prepared"
if grep -q "no-such-bundle" "$T/out.log"; then
    cat "$T/out.log" >&2
    fail "the install went on to fetch the bundle"
fi
[ ! -e "$T/home/.local/share/brig" ] || fail "the install wrote $T/home/.local/share/brig"
grep -q "Nothing was downloaded" "$T/out.log" || { cat "$T/out.log" >&2; fail "no reason given"; }
awk '/^sudo sh -eu <<.BRIG_ROOT.$/ {f=1; next} /^BRIG_ROOT$/ {f=0} f' "$T/out.log" > "$T/root.sh"
[ -s "$T/root.sh" ] || { cat "$T/out.log" >&2; fail "no root commands printed"; }
sh -n "$T/root.sh" || fail "the root commands are not valid sh"
profile="/etc/apparmor.d/$(printf '%s' "${prefix#/}/bin/rootlesskit" | tr / .)"
if ! grep -qF "apparmor_parser -r '$profile'" "$T/root.sh" \
    || ! grep -qF "$prefix/bin/rootlesskit flags=(unconfined) {" "$T/root.sh"; then
    cat "$T/root.sh" >&2
    fail "no AppArmor profile for $prefix/bin/rootlesskit"
fi
if [ -e /dev/kvm ]; then
    grep -q "^cat > /etc/udev/rules.d/99-brig-kvm-$user.rules" "$T/root.sh" \
        || { cat "$T/root.sh" >&2; fail "no udev rule for $user"; }
    grep -q "u:$user:rw /dev/kvm" "$T/root.sh" || fail "the udev rule does not grant $user"
fi
ok "without sudo the install stops before the download and prints the root commands"

# 2. Not prepared, and sudo runs without a password: go on, and leave the
#    host settings to the rootless setup.
touch "$T/sudo-ok"
run_install
grep -q "will make them with sudo" "$T/out.log" || { cat "$T/out.log" >&2; fail "no warning"; }
grep -q "no-such-bundle" "$T/out.log" || { cat "$T/out.log" >&2; fail "the install did not go on"; }
ok "with sudo the install goes on to the download"
rm -f "$T/sudo-ok"

# 3. Prepared by an admin, and no sudo: go on without asking for it.
if [ -d /sys/module/vhost_vsock ] && ! grep -qsx vhost_vsock /etc/modules-load.d/*.conf /etc/modules; then
    skip "vhost_vsock is loaded here but not at boot, which a prepared host has"
fi
rm -f "$T/apparmor"
touch "$T/granted"
run_install
grep -q "no-such-bundle" "$T/out.log" || { cat "$T/out.log" >&2; fail "a prepared host did not get past the preflight"; }
[ ! -s "$T/sudo.log" ] || { cat "$T/sudo.log" >&2; fail "a prepared host was asked for sudo"; }
ok "a prepared host needs no sudo"
