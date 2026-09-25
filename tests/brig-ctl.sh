#!/bin/sh
#
# Generate brig-ctl with the build's own function and check how it runs ctr:
# with a bare socket path, and through the rootless namespace for a caller who
# is not root. ctr and the setup tool are stubs that log their argv.

set -eu

here="$(cd "$(dirname "$0")/.." && pwd)"

skip() { echo "SKIP: $*"; exit 0; }
fail() { echo "FAIL: $*" >&2; exit 1; }
ok() { echo "ok - $*"; }

[ "$(id -u)" -ne 0 ] || skip "the rootless path is for a caller who is not root"

T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT

# gen <rootless>: write brig-ctl for a bundle built with or without the
# rootless path, into a tree of its own, with stub ctr and setup tool.
gen() {
    STAGE="$T/$1"
    PREFIX="$STAGE"
    ETC_DIR="$PREFIX/etc"
    # Read by the generator, which shellcheck cannot see through the eval.
    # shellcheck disable=SC2034
    {
        ROOTLESS="$1"
        SERVICE_NAME=brig-containerd
        CONTAINERD_SOCK=/run/brig/containerd.sock
        NAMESPACE=brig
        SNAPSHOTTER=overlayfs
        CNI_DIR="$PREFIX/libexec/cni"
    }
    mkdir -p "$STAGE/bin" "$ETC_DIR"
    write_brig_ctl
    cat > "$STAGE/bin/ctr" <<STUB
#!/bin/sh
echo "ctr \$*" >> "$T/log"
STUB
    cat > "$STAGE/bin/containerd-rootless-setuptool.sh" <<STUB
#!/bin/sh
echo "setuptool \$1 \$2" >> "$T/log"
shift 2
exec "\$@"
STUB
    printf '#!/bin/sh\nexit 0\n' > "$STAGE/bin/systemctl"
    chmod 0755 "$STAGE/bin"/*
}

eval "$(awk '/^write_brig_ctl\(\) \{/ {f=1} /^write_brig_rootless_setup\(\) \{/ {f=0} f' \
    "$here/scripts/build-bundle.sh")"
gen true
gen false

mkdir -p "$T/run/containerd-rootless"
echo 1 > "$T/run/containerd-rootless/child_pid"

# brig_ctl <rootless> <address> <args...>: run it the way brig-env.sh leaves
# the environment for a caller who is not root.
brig_ctl() {
    tree="$1"; addr="$2"; shift 2
    : > "$T/log"
    CONTAINERD_ADDRESS="$addr" XDG_RUNTIME_DIR="$T/run" PATH="$T/$tree/bin:$PATH" \
        "$T/$tree/bin/brig-ctl" "$@"
}

# 1. A rootless caller: ctr runs inside the namespace, on a bare path.
brig_ctl true unix:///run/containerd/containerd.sock ctr version
grep -qx "setuptool nsenter --" "$T/log" \
    || { cat "$T/log" >&2; fail "ctr did not go through the rootless namespace"; }
grep -qx "ctr --address /run/containerd/containerd.sock --namespace brig version" "$T/log" \
    || { cat "$T/log" >&2; fail "ctr did not get a bare socket path"; }
ok "a rootless caller runs ctr in the namespace, on a bare path"

# 2. status asks ctr the same way.
brig_ctl true unix:///run/containerd/containerd.sock status > /dev/null
if ! grep -qx "setuptool nsenter --" "$T/log" \
    || ! grep -qx "ctr --address /run/containerd/containerd.sock plugin ls" "$T/log"; then
    cat "$T/log" >&2
    fail "status did not reach the rootless containerd"
fi
ok "status lists plugins through the namespace"

# 3. No daemon: say so instead of failing inside nsenter.
rm "$T/run/containerd-rootless/child_pid"
if brig_ctl true unix:///run/containerd/containerd.sock ctr version 2> "$T/err"; then
    fail "ctr ran with no rootless containerd"
fi
grep -q "systemctl --user start brig-containerd.service" "$T/err" \
    || { cat "$T/err" >&2; fail "no hint to start the daemon"; }
ok "with no daemon it says how to start one"

# 4. A bundle without the rootless path: ctr runs directly, on a bare path.
brig_ctl false unix:///run/brig/containerd.sock ctr version
grep -q setuptool "$T/log" && fail "a plain bundle went through the rootless namespace"
grep -qx "ctr --address /run/brig/containerd.sock --namespace brig version" "$T/log" \
    || { cat "$T/log" >&2; fail "a plain bundle did not give ctr a bare path"; }
ok "a plain bundle runs ctr directly, on a bare path"
