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

# sudo: only -n true can succeed, and only when the test says sudo works. With
# that, -n sh -eu <file> is the installer making packages: it keeps the file,
# and "installs" them as stubs unless the test says the install fails.
cat > "$T/stub/sudo" <<STUB
#!/bin/sh
echo "\$*" >> "$T/sudo.log"
# -v is the password prompt, which the test answers right or not at all.
if [ "\$1" = -v ]; then
    [ -f "$T/sudo-pass" ] || exit 1
    touch "$T/sudo-ok"; exit 0
fi
[ -f "$T/sudo-ok" ] || exit 1
[ "\$*" = "-n true" ] && exit 0
if [ "\$1 \$2 \$3" = "-n sh -eu" ]; then
    cp "\$4" "$T/sudo-ran.sh"
    [ -f "$T/apt-fails" ] && exit 100
    for b in newuidmap setfacl iptables; do
        printf '#!/bin/sh\nexit 0\n' > "$T/stub/\$b"; chmod 0755 "$T/stub/\$b"
    done
    exit 0
fi
exit 1
STUB

# id -nG names a sudo group only when the test says this user is in one.
cat > "$T/stub/id" <<STUB
#!/bin/sh
if [ "\$1" = -nG ]; then
    if [ -f "$T/in-sudo" ]; then echo "$user sudo"; else echo "$user"; fi
    exit 0
fi
exec /usr/bin/id "\$@"
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
for b in newuidmap setfacl iptables systemctl; do
    printf '#!/bin/sh\nexit 0\n' > "$T/stub/$b"
done
chmod 0755 "$T/stub"/*

run_install() {
    : > "$T/sudo.log"
    set +e
    env -u XDG_CONFIG_HOME -u XDG_DATA_HOME \
        HOME="$T/home" XDG_RUNTIME_DIR="$T/run" PATH="$T/stub:$PATH" \
        INSTALL_BRIG_BUNDLE="$T/no-such-bundle.tar.gz" INSTALL_BRIG_TTY="$T/tty" \
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

# 2b. A fresh Ubuntu cloud image has neither uidmap nor acl. Without sudo: stop,
#     with the packages in the root commands and the way to let it use sudo.
if command -v newuidmap >/dev/null 2>&1 \
    || command -v setfacl >/dev/null 2>&1; then
    echo "SKIP: this host has uidmap or acl, so their absence cannot be staged"
else
    rm -f "$T/stub/newuidmap" "$T/stub/setfacl"
    run_install
    [ "$rc" -ne 0 ] || fail "the install went on without uidmap and acl"
    grep -q "apt-get install -y uidmap acl" "$T/out.log" || { cat "$T/out.log" >&2; fail "the packages are not in the root commands"; }
    grep -q "sudo -v" "$T/out.log" || { cat "$T/out.log" >&2; fail "no word that sudo -v lets the installer do it"; }
    ok "without sudo, missing packages stop the install with the root commands"

    # With sudo: install them before the download, check again, and go on.
    touch "$T/sudo-ok"
    run_install
    grep -q "apt-get install -y uidmap acl" "$T/sudo-ran.sh" 2>/dev/null \
        || { cat "$T/out.log" >&2; fail "the packages were not installed with sudo"; }
    if grep -q "^usermod\|udev\|apparmor" "$T/sudo-ran.sh"; then
        cat "$T/sudo-ran.sh" >&2
        fail "the early sudo ran what brig-rootless-setup.sh makes"
    fi
    grep -q "no-such-bundle" "$T/out.log" || { cat "$T/out.log" >&2; fail "the install did not go on after the packages"; }
    ok "with sudo, missing packages are installed and the install goes on"

    # With sudo, and an install that fails: stop, and say so.
    rm -f "$T/stub/newuidmap" "$T/stub/setfacl" "$T/sudo-ran.sh"
    touch "$T/apt-fails"
    run_install
    [ "$rc" -ne 0 ] || fail "the install went on after the packages failed"
    grep -q "making them with sudo failed" "$T/out.log" || { cat "$T/out.log" >&2; fail "no word that sudo failed"; }
    if grep -q "sudo -v" "$T/out.log"; then
        fail "a user whose sudo works was told to run sudo -v"
    fi
    ok "a failed package install stops the install"
    rm -f "$T/apt-fails" "$T/sudo-ok"

    # sudo with a password, from a terminal, for a user in a sudo group: asked
    # once, and then the same as sudo without one.
    rm -f "$T/stub/newuidmap" "$T/stub/setfacl" "$T/sudo-ran.sh"
    : > "$T/tty"
    touch "$T/in-sudo" "$T/sudo-pass"
    run_install
    [ "$(grep -c '^-v$' "$T/sudo.log")" = 1 ] || { cat "$T/sudo.log" >&2; fail "sudo was not asked for the password once"; }
    grep -q "apt-get install -y uidmap acl" "$T/sudo-ran.sh" 2>/dev/null \
        || { cat "$T/out.log" >&2; fail "the packages were not installed after the password"; }
    grep -q "no-such-bundle" "$T/out.log" || { cat "$T/out.log" >&2; fail "the install did not go on after the password"; }
    ok "a user in a sudo group is asked for the password and the install goes on"

    # No terminal, or not in a sudo group: no prompt, and the stop as before.
    rm -f "$T/stub/newuidmap" "$T/stub/setfacl" "$T/sudo-ok" "$T/tty"
    run_install
    if grep -q '^-v$' "$T/sudo.log"; then fail "sudo was asked for a password with no terminal"; fi
    grep -q "Nothing was downloaded" "$T/out.log" || { cat "$T/out.log" >&2; fail "no stop without a terminal"; }
    : > "$T/tty"
    rm -f "$T/in-sudo"
    run_install
    if grep -q '^-v$' "$T/sudo.log"; then fail "a user in no sudo group was asked for a password"; fi
    ok "no terminal, or no sudo group, means no password prompt"
    rm -f "$T/sudo-pass" "$T/tty"
    for b in newuidmap setfacl iptables; do
        printf '#!/bin/sh\nexit 0\n' > "$T/stub/$b"; chmod 0755 "$T/stub/$b"
    done
fi

# 2c. The packages come from the package manager the host has, by its names.
sed -n '/^install_tools_cmd()/,/^}/p' "$here/install.sh" > "$T/tools-fn.sh"
for pm in apt-get dnf yum zypper pacman none; do
    mkdir -p "$T/pm-$pm"
    [ "$pm" = none ] || { printf '#!/bin/sh\n' > "$T/pm-$pm/$pm"; chmod 0755 "$T/pm-$pm/$pm"; }
    got="$(PATH="$T/pm-$pm" /bin/sh -c ". '$T/tools-fn.sh'; install_tools_cmd newuidmap setfacl")"
    case "$pm" in
        apt-get) want="DEBIAN_FRONTEND=noninteractive apt-get install -y uidmap acl </dev/null" ;;
        dnf) want="dnf install -y shadow-utils acl" ;;
        yum) want="yum install -y shadow-utils acl" ;;
        zypper) want="zypper --non-interactive install shadow acl" ;;
        pacman) want="pacman -S --noconfirm --needed shadow acl" ;;
        none) want="# install shadow acl with this host's package manager: none that this installer knows is here" ;;
    esac
    [ "$got" = "$want" ] || fail "with $pm: got '$got', want '$want'"
done
got="$(PATH="$T/pm-dnf" /bin/sh -c ". '$T/tools-fn.sh'; install_tools_cmd iptables")"
[ "$got" = "dnf install -y iptables-nft" ] || fail "iptables on dnf: got '$got'"
got="$(PATH="$T/pm-zypper" /bin/sh -c ". '$T/tools-fn.sh'; install_tools_cmd iptables")"
[ "$got" = "zypper --non-interactive install iptables" ] || fail "iptables on zypper: got '$got'"
ok "the packages come from the host's own package manager"

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
