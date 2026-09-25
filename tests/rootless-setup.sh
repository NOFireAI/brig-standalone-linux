#!/bin/sh
#
# Run the generated brig-rootless-setup.sh against stubs and check the device
# grant it asks sudo for. The stub sudo writes nothing outside a scratch
# directory, and the stub getfacl and stat answer from the rule files written
# there, the way udev would apply them.
#
# Needs a normal user with a subuid range and a /dev/kvm, as the setup does.

set -eu

here="$(cd "$(dirname "$0")/.." && pwd)"
user="$(id -un)"

skip() { echo "SKIP: $*"; exit 0; }
fail() { echo "FAIL: $*" >&2; exit 1; }
ok() { echo "ok - $*"; }

[ "$(id -u)" -ne 0 ] || skip "the setup refuses root; run this as a normal user"
[ -e /dev/kvm ] || skip "no /dev/kvm on this host"
grep -q "^$user:" /etc/subuid 2>/dev/null || skip "no subuid range for $user"

T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT

# Generate the setup with the build's own function.
STAGE="$T/stage"
PREFIX="$T/prefix"
ETC_DIR="$PREFIX/etc"
# Read by the generator, which shellcheck cannot see through the eval.
# shellcheck disable=SC2034
{
    NAMESPACE=brig
    SNAPSHOTTER=overlayfs
    CNI_DIR="$PREFIX/libexec/cni"
}
mkdir -p "$STAGE/bin" "$PREFIX/bin" "$ETC_DIR/cni/net.d" "$T/stub" "$T/home" "$T/run"
eval "$(awk '/^write_brig_rootless_setup\(\) \{/ {f=1} /^write_uninstaller\(\) \{/ {f=0} f' \
    "$here/scripts/build-bundle.sh")"
write_brig_rootless_setup
SETUP="$STAGE/bin/brig-rootless-setup.sh"
[ -x "$SETUP" ] || fail "the build did not write brig-rootless-setup.sh"

for b in rootlesskit containerd-rootless.sh slirp4netns containerd; do
    printf '#!/bin/sh\nexit 0\n' > "$PREFIX/bin/$b"
done

RULES="$T/root/etc/udev/rules.d"
mkdir -p "$RULES"

# sudo: log the call, and write files under $T/root instead of /.
cat > "$T/stub/sudo" <<STUB
#!/bin/sh
echo "\$*" >> "$T/sudo.log"
case "\$1" in
    tee) mkdir -p "$T/root\$(dirname "\$2")"; cat > "$T/root\$2" ;;
esac
exit 0
STUB

# getfacl: the user holds an ACL once a rule names them, or once the test says
# an admin granted them some other way.
cat > "$T/stub/getfacl" <<STUB
#!/bin/sh
echo "user::rw-"
if [ -f "$T/granted" ] || grep -qs "u:$user:rw" "$RULES"/*.rules; then
    echo "user:$user:rw-"
fi
echo "group::rw-"
STUB

# stat: the devices are 0666 while an open rule exists, 0660 otherwise.
cat > "$T/stub/stat" <<STUB
#!/bin/sh
if [ "\$1" = -c ] && [ "\$2" = %a ]; then
    case "\$3" in
        /dev/*)
            if [ -f "$RULES/99-brig-open-devices.rules" ]; then echo 666; else echo 660; fi
            exit 0 ;;
    esac
fi
exec /usr/bin/stat "\$@"
STUB

cat > "$T/stub/systemctl" <<'STUB'
#!/bin/sh
case "$*" in *is-active*) echo active ;; esac
exit 0
STUB

for b in setfacl newuidmap loginctl sleep; do
    printf '#!/bin/sh\nexit 0\n' > "$T/stub/$b"
done
printf '#!/bin/sh\necho 0\n' > "$T/stub/sysctl"
chmod 0755 "$T/stub"/* "$PREFIX/bin"/*

run_setup() {
    : > "$T/sudo.log"
    if ! env -u XDG_CONFIG_HOME -u XDG_DATA_HOME \
        HOME="$T/home" XDG_RUNTIME_DIR="$T/run" PATH="$T/stub:$PATH" \
        "$SETUP" "$@" > "$T/out.log" 2>&1; then
        cat "$T/out.log" >&2
        fail "the setup exited non-zero"
    fi
}

udev_calls() { grep -e udevadm -e 'rules\.d' "$T/sudo.log"; }

# 1. A user with no grant gets a rule file of their own.
run_setup
grep -qx "tee /etc/udev/rules.d/99-brig-kvm-$user.rules" "$T/sudo.log" \
    || { cat "$T/sudo.log" >&2; fail "the grant did not go to 99-brig-kvm-$user.rules"; }
if grep -q "rules.d/99-brig-kvm.rules" "$T/sudo.log"; then
    fail "the setup wrote the shared 99-brig-kvm.rules"
fi
grep -q "u:$user:rw /dev/kvm" "$RULES/99-brig-kvm-$user.rules" \
    || fail "99-brig-kvm-$user.rules does not grant $user"
ok "a first run writes 99-brig-kvm-$user.rules"

# 2. A user whose grant an admin wrote, in a file named anything, is not asked
#    for sudo over the devices.
rm -f "$RULES"/*.rules
touch "$T/granted"
run_setup
if udev_calls; then
    fail "a user the devices already admit was asked for sudo"
fi
ok "a user the devices already admit is not asked for sudo"
rm -f "$T/granted"

# 3. --open-devices writes the host-wide file, and a plain run afterwards leaves
#    it alone.
run_setup --open-devices
grep -qx "tee /etc/udev/rules.d/99-brig-open-devices.rules" "$T/sudo.log" \
    || { cat "$T/sudo.log" >&2; fail "--open-devices did not write 99-brig-open-devices.rules"; }
ok "--open-devices writes 99-brig-open-devices.rules"
run_setup
if udev_calls; then
    fail "a plain run on an open host asked for sudo"
fi
[ -f "$RULES/99-brig-open-devices.rules" ] || fail "a plain run removed the open rule"
ok "a plain run leaves the open rule in place"
