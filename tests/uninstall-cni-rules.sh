#!/bin/sh
#
# Run the generated brig-uninstall.sh on a fake system install and check what it
# does to the CNI firewall rules. iptables-save and iptables-restore are stubs
# that answer from, and apply -D lines to, per-table rule files in a scratch
# directory. The uninstall must delete the rules that name brig0 in the CNI-*
# chains and leave the shared chains and other bridges' rules alone.

set -eu

here="$(cd "$(dirname "$0")/.." && pwd)"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok() { echo "ok - $*"; }

T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/stub" "$T/bare" "$T/state" "$T/want" "$T/home"

# Generate the uninstaller with the build's own function.
STAGE="$T/stage"
mkdir -p "$STAGE/bin"
eval "$(awk '/^write_uninstaller\(\) \{/ {f=1} /^fetch\(\) \{/ {f=0} f' \
    "$here/scripts/build-bundle.sh")"
write_uninstaller

# The commands the uninstaller reaches for on the host. id answers FAKE_UID, ip
# answers whether the bridge exists, and the rest only log.
cat > "$T/bare/id" <<'STUB'
#!/bin/sh
echo "${FAKE_UID:-0}"
STUB
cat > "$T/bare/ip" <<STUB
#!/bin/sh
echo "ip \$*" >> "$T/log"
case "\$*" in "link show"*) [ "\${FAKE_BRIDGE:-up}" = up ] ;; esac
STUB
for c in systemctl pkill sleep umount dmsetup losetup groupdel; do
    printf '#!/bin/sh\necho "%s $*" >> "%s/log"\n' "$c" "$T" > "$T/bare/$c"
done
chmod 0755 "$T/bare"/*
cp "$T/bare"/* "$T/stub/"

# <ipt>-save -t <table> prints $T/state/<ipt>.<table>. <ipt>-restore takes
# "*<table>", "-D <rule>" and "COMMIT" lines and drops the first "-A <rule>"
# from that file, or fails as iptables does when the rule is not there. It
# refuses to run without --noflush, which would flush the whole table.
cat > "$T/stub/iptables-save" <<STUB
#!/bin/sh
ipt="\$(basename "\$0")"; ipt="\${ipt%-save}"
echo "\$ipt-save \$*" >> "$T/log"
[ "\$1" = -t ] || exit 2
cat "$T/state/\$ipt.\$2" 2>/dev/null || true
STUB
cat > "$T/stub/iptables-restore" <<STUB
#!/bin/sh
ipt="\$(basename "\$0")"; ipt="\${ipt%-restore}"
echo "\$ipt-restore \$*" >> "$T/log"
case " \$* " in *" --noflush "*) ;; *) exit 3 ;; esac
[ "\${FAKE_RESTORE_FAIL:-}" != 1 ] || { echo "\$ipt-restore: line 2 failed: Bad rule" >&2; exit 1; }
table=""
while IFS= read -r l; do
    case "\$l" in
        "*"*) table="\${l#\*}" ;;
        COMMIT) ;;
        "-D "*)
            f="$T/state/\$ipt.\$table"
            grep -qxF -- "-A \${l#-D }" "\$f" 2>/dev/null || exit 1
            awk -v r="-A \${l#-D }" '\$0 == r && !d {d = 1; next} {print}' "\$f" > "\$f.new"
            mv "\$f.new" "\$f" ;;
        *) exit 4 ;;
    esac
done
STUB
chmod 0755 "$T/stub"/iptables-*
ln -s iptables-save "$T/stub/ip6tables-save"
ln -s iptables-restore "$T/stub/ip6tables-restore"

# The filter table as nuc8 had it after a system install, with brig0 next to a
# Docker bridge, plus two rules naming brig0 that are not ours to remove: one in
# FORWARD, outside the CNI-* chains, and one for brig0x.
cat > "$T/filter" <<'RULES'
*filter
:INPUT ACCEPT [0:0]
:FORWARD DROP [0:0]
:OUTPUT ACCEPT [0:0]
:CNI-ADMIN - [0:0]
:CNI-FORWARD - [0:0]
:CNI-ISOLATION-STAGE-1 - [0:0]
:CNI-ISOLATION-STAGE-2 - [0:0]
-A FORWARD -m comment --comment "CNI firewall plugin rules (ingressPolicy: same-bridge|isolated)" -j CNI-ISOLATION-STAGE-1
-A FORWARD -m comment --comment "CNI firewall plugin rules" -j CNI-FORWARD
-A FORWARD -i brig0 -j ACCEPT
-A CNI-FORWARD -m comment --comment "CNI firewall plugin admin overrides" -j CNI-ADMIN
-A CNI-ISOLATION-STAGE-1 -i br-177cd0907bb6 ! -o br-177cd0907bb6 -m comment --comment "CNI firewall plugin rules (ingressPolicy: same-bridge)" -j CNI-ISOLATION-STAGE-2
-A CNI-ISOLATION-STAGE-1 -i brig0 ! -o brig0 -m comment --comment "CNI firewall plugin rules (ingressPolicy: same-bridge)" -j CNI-ISOLATION-STAGE-2
-A CNI-ISOLATION-STAGE-1 -i brig0x ! -o brig0x -m comment --comment "CNI firewall plugin rules (ingressPolicy: same-bridge)" -j CNI-ISOLATION-STAGE-2
-A CNI-ISOLATION-STAGE-1 -m comment --comment "CNI firewall plugin rules (ingressPolicy: same-bridge|isolated)" -j RETURN
-A CNI-ISOLATION-STAGE-2 -o br-177cd0907bb6 -m comment --comment "CNI firewall plugin rules (ingressPolicy: same-bridge|isolated)" -j DROP
-A CNI-ISOLATION-STAGE-2 -o brig0 -m comment --comment "CNI firewall plugin rules (ingressPolicy: same-bridge|isolated)" -j DROP
-A CNI-ISOLATION-STAGE-2 -m comment --comment "CNI firewall plugin rules (ingressPolicy: same-bridge|isolated)" -j RETURN
COMMIT
RULES
grep -vxF \
    -e '-A CNI-ISOLATION-STAGE-1 -i brig0 ! -o brig0 -m comment --comment "CNI firewall plugin rules (ingressPolicy: same-bridge)" -j CNI-ISOLATION-STAGE-2' \
    -e '-A CNI-ISOLATION-STAGE-2 -o brig0 -m comment --comment "CNI firewall plugin rules (ingressPolicy: same-bridge|isolated)" -j DROP' \
    "$T/filter" > "$T/want/iptables.filter"

# The nat and IPv6 tables carry no brig0 rule on a real host. These are made up
# to cover the other tables the uninstaller reads.
cat > "$T/nat" <<'RULES'
*nat
:POSTROUTING ACCEPT [0:0]
:CNI-HOSTPORT-MASQ - [0:0]
-A POSTROUTING -m comment --comment "CNI portfwd requiring masquerade" -j CNI-HOSTPORT-MASQ
-A CNI-HOSTPORT-MASQ -o brig0 -m comment --comment "made up" -j MASQUERADE
-A CNI-HOSTPORT-MASQ -o br-177cd0907bb6 -m comment --comment "made up" -j MASQUERADE
COMMIT
RULES
grep -v -- '-o brig0 ' "$T/nat" > "$T/want/iptables.nat"
grep -v 'brig0x\|br-177' "$T/filter" > "$T/filter6"
grep -v -- '^-A CNI-.*brig0' "$T/filter6" > "$T/want/ip6tables.filter"

reset_state() {
    rm -f "$T/state"/* "$T/log"
    cp "$T/filter" "$T/state/iptables.filter"
    cp "$T/nat" "$T/state/iptables.nat"
    cp "$T/filter6" "$T/state/ip6tables.filter"
}

# install <mode>: a fresh install tree for the uninstaller to remove, with the
# stamp install.sh writes.
install() {
    rm -rf "$T/inst"
    mkdir -p "$T/inst/data/bin" "$T/inst/agent" "$T/run"
    cp "$STAGE/bin/brig-uninstall.sh" "$T/inst/data/bin/"
    cat > "$T/inst/data/.install-stamp" <<STAMP
INSTALL_MODE=$1
PREFIX=$T/inst/data
DATA_DIR=$T/inst/agent
RUN_DIR=$T/run
BRIDGE_NAME=brig0
SERVICE_NAME=brig-containerd
POOL_SERVICE_NAME=brig-devpool
SYSTEMD_INSTALLED=false
POOL_NAME=
POOL_CREATED=false
BRIG_GROUP=brig
GROUP_CREATED=false
BRIG_LAUNCHER=
BRIGD_LAUNCHER=
ETC_SYMLINK=
STAMP
}

# uninstall <path>: run the uninstaller with that PATH, keep its output. The
# FAKE_* settings are passed on by hand: whether an assignment in front of a
# function call reaches the commands it runs differs between shells.
uninstall() {
    FAKE_UID="${FAKE_UID:-0}" FAKE_BRIDGE="${FAKE_BRIDGE:-up}" \
        FAKE_RESTORE_FAIL="${FAKE_RESTORE_FAIL:-}" \
        HOME="$T/home" XDG_CONFIG_HOME="$T/home/.config" PATH="$1" \
        "$T/inst/data/bin/brig-uninstall.sh" --yes > "$T/out" 2>&1 \
        || { cat "$T/out" >&2; fail "the uninstall failed"; }
    grep -q '^\[brig-uninstall\] done$' "$T/out" || { cat "$T/out" >&2; fail "the uninstall did not finish"; }
    [ ! -e "$T/inst/data" ] || fail "the uninstall left $T/inst/data"
}

same_state() {
    for f in iptables.filter iptables.nat ip6tables.filter; do
        cmp -s "$T/state/$f" "$1/$f" || { diff "$1/$f" "$T/state/$f" >&2 || true; fail "$2: $f"; }
    done
}

mkdir -p "$T/orig"
cp "$T/filter" "$T/orig/iptables.filter"
cp "$T/nat" "$T/orig/iptables.nat"
cp "$T/filter6" "$T/orig/ip6tables.filter"

# A system install with the bridge still up.
reset_state; install system
FAKE_UID=0 FAKE_BRIDGE=up uninstall "$T/stub:/usr/bin:/bin"
grep -q '^ip link delete brig0$' "$T/log" || fail "the bridge was not deleted"
same_state "$T/want" "the brig0 rules are not exactly the ones removed"
[ "$(grep -c '^\[brig-uninstall\] removed ip6\{0,1\}tables ' "$T/out")" -eq 5 ] \
    || { cat "$T/out" >&2; fail "the uninstall did not report five removed rules"; }
grep -q ':CNI-ISOLATION-STAGE-2 - ' "$T/state/iptables.filter" || fail "a shared chain went"
ok "a system uninstall removes the brig0 rules and keeps the rest"

# Again on what is left: nothing matches, so nothing is deleted or said.
rm -f "$T/log"; install system
FAKE_UID=0 FAKE_BRIDGE=up uninstall "$T/stub:/usr/bin:/bin"
! grep -q 'restore' "$T/log" || fail "a second uninstall still deleted rules"
! grep -q 'tables\|WARNING' "$T/out" || { cat "$T/out" >&2; fail "a second uninstall was not quiet"; }
same_state "$T/want" "a second uninstall changed the rules"
ok "a second uninstall finds nothing and says nothing"

# nuc8: the bridge was already gone by the time the uninstall ran.
reset_state; install system
FAKE_UID=0 FAKE_BRIDGE=absent uninstall "$T/stub:/usr/bin:/bin"
! grep -q '^ip link delete' "$T/log" || fail "an absent bridge was deleted"
same_state "$T/want" "the brig0 rules stayed with the bridge gone"
ok "the rules go when the bridge is already gone"

# iptables fails every delete: the uninstall warns and finishes.
reset_state; install system
FAKE_UID=0 FAKE_RESTORE_FAIL=1 uninstall "$T/stub:/usr/bin:/bin"
[ "$(grep -c 'WARNING: could not remove ip6\{0,1\}tables ' "$T/out")" -eq 5 ] \
    || { cat "$T/out" >&2; fail "the failed deletes were not reported"; }
[ "$(grep -c 'WARNING: could not remove ip6\{0,1\}tables .*: ip6\{0,1\}tables-restore: line 2 failed: Bad rule' "$T/out")" -eq 5 ] \
    || { cat "$T/out" >&2; fail "a failed delete did not say why"; }
grep -q -- '-restore -w 5 --noflush' "$T/log" || fail "the xtables lock wait is not bounded"
same_state "$T/orig" "a failed delete changed the rules"
ok "a failing iptables does not stop the uninstall"
unset FAKE_RESTORE_FAIL FAKE_BRIDGE

# A user install owns no host firewall rules.
reset_state; install user
FAKE_UID=1000 uninstall "$T/stub:/usr/bin:/bin"
! grep -q 'tables' "$T/log" || fail "a user uninstall ran iptables"
same_state "$T/orig" "a user uninstall changed the rules"
ok "a user uninstall leaves iptables alone"

# A host without iptables at all.
if PATH="$T/bare:/usr/bin:/bin" command -v iptables-save >/dev/null 2>&1; then
    echo "SKIP: iptables-save is in /usr/bin or /bin here"
else
    rm -f "$T/log"; install system
    FAKE_UID=0 uninstall "$T/bare:/usr/bin:/bin"
    ok "a system uninstall without iptables finishes"
fi
