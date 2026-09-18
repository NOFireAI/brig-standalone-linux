#!/bin/sh
#
# Copyright (c) 2026, NOFire AI
# SPDX-License-Identifier: Apache-2.0
#
# Build the self-contained brig bundle for one architecture -- the single tarball
# install.sh fetches and unpacks. This script is where all the building happens.
#
# The tarball is a complete /opt/brig tree: brig and brigd, cosign and oras, the
# private-containerd stack (containerd, ctr, runc, nerdctl, CNI), the microVM
# monitors, the urunc runtime, the guest kernel and a brig-built initrd, plus
# every config file, systemd unit, wrapper and the uninstaller. Most components
# are upstream release artifacts; three are built here because no release ships
# them: urunc (from urunc-dev/urunc), urunit (from NOFireAI/urunit) and the
# container-initrd (assembled from both).
#
#   scripts/build-bundle.sh --arch amd64 --version v0.1.0 --out dist
#   scripts/build-bundle.sh --arch arm64 --version v0.1.0 --variant generic-boot
#
# docker is required (the urunc/urunit builds run in containers). Building the
# arm64 pieces on an amd64 runner (or vice versa) needs binfmt/qemu registered,
# because the static urunc binary and urunit are CGO/C and are built native
# inside a target-arch container (docker run --platform).
#
# Produces, under --out:
#   brig-standalone-<version>-linux-<arch>.tar.gz          (the install tarball)
#   brig-standalone-<version>-linux-<arch>.pins.env
#   brig-standalone-<version>-linux-<arch>.components.json

set -eu

# Directory modes in the archive come from the builder's umask, so two hosts
# with different umasks produce different bytes from the same inputs. Pin it.
umask 022

SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(dirname "$SELF_DIR")"

ARCH=""
VERSION=""
OUT="$REPO_DIR/dist"
VARIANT="generic-boot"
URUNC_VERSION_STOCK=""   # only for --variant stock: a released urunc tag

info() { echo "[build-bundle] $*" >&2; }
fatal() { echo "[build-bundle] ERROR: $*" >&2; exit 1; }

while [ $# -gt 0 ]; do
    case "$1" in
        --arch) ARCH="$2"; shift 2 ;;
        --version) VERSION="$2"; shift 2 ;;
        --out) OUT="$2"; shift 2 ;;
        --variant) VARIANT="$2"; shift 2 ;;
        --urunc-version) URUNC_VERSION_STOCK="$2"; shift 2 ;;
        --help|-h) sed -n '2,30p' "$0"; exit 0 ;;
        *) fatal "unknown argument '$1'" ;;
    esac
done

[ -n "$ARCH" ] || fatal "--arch is required (amd64 or arm64)"
[ -n "$VERSION" ] || fatal "--version is required"

case "$ARCH" in
    amd64) ARCH_UNAME=x86_64 ;;
    arm64) ARCH_UNAME=aarch64 ;;
    *) fatal "unsupported arch '$ARCH'" ;;
esac
case "$VARIANT" in
    stock|generic-boot|introspection) ;;
    *) fatal "unknown --variant '$VARIANT'" ;;
esac

for tool in curl tar sha256sum awk sed; do
    command -v "$tool" >/dev/null 2>&1 || fatal "'$tool' is required"
done

# ---------------------------------------------------------------- pins
# build-bundle.sh is the build authority: bumping a version here is the only place
# it changes. install.sh does not build, so it carries none of these.
BRIG_VERSION="${BRIG_VERSION:-latest}"
BRIG_REPO="${BRIG_REPO:-brig-sh/brig}"
URUNC_REPO="${URUNC_REPO:-urunc-dev/urunc}"
URUNC_BRANCH="${URUNC_BRANCH:-feat/unchanged_containers}"
URUNC_GO_IMAGE="${URUNC_GO_IMAGE:-golang:1.26.4}"
URUNIT_REPO="${URUNIT_REPO:-NOFireAI/urunit}"
URUNIT_BRANCH="${URUNIT_BRANCH:-urunit_agent}"
MONITORS_VERSION="${MONITORS_VERSION:-FC-v1.7.0_CLH-v50.0_S5-v0.12.1_VFS_-v1.13.0_QM-v10.1.1-9a44e}"
CONTAINERD_VERSION="${CONTAINERD_VERSION:-v2.3.5}"
RUNC_VERSION="${RUNC_VERSION:-v1.5.1}"
NERDCTL_VERSION="${NERDCTL_VERSION:-v2.3.5}"
CNI_VERSION="${CNI_VERSION:-v1.9.1}"
ORAS_VERSION="${ORAS_VERSION:-v1.3.4}"
COSIGN_VERSION="${COSIGN_VERSION:-v3.1.3}"
COSIGN_SHA_LINUX_AMD64="4629c757b7618056f8ddd7e2625ae9fdd94c0372a65049520bc7d9df9efc7f71"
COSIGN_SHA_LINUX_ARM64="c5d324e091826b0d7a78eb16fef316450b4eb9aaec045611c08ba06f5e73220a"
MONITORS="${MONITORS:-firecracker cloud-hypervisor solo5-hvt solo5-spt}"
ASSETS_REGISTRY="${ASSETS_REGISTRY:-ghcr.io}"
ASSETS_REPO="${ASSETS_REPO:-nofireai/hull-assets}"
ASSETS_VERSION="${ASSETS_VERSION:-0.1.4}"
VIRTIOFSD="${VIRTIOFSD:-true}"

# Fixed install layout, baked into the config files the bundle carries. install.sh
# unpacks the tree to exactly these paths, so they are not configurable there.
PREFIX=/opt/brig
DATA_DIR=/var/lib/brig
RUN_DIR=/run/brig
BIN_DIR="$PREFIX/bin"
ETC_DIR="$PREFIX/etc"
SHARE_DIR="$PREFIX/share"
LIBEXEC_DIR="$PREFIX/libexec"
CNI_DIR="$LIBEXEC_DIR/cni"
LOG_DIR="$DATA_DIR/log"
CONTAINERD_SOCK="$RUN_DIR/containerd.sock"
NAMESPACE=brig
POOL_NAME=brig-devpool
BRIDGE_NAME=brig0
BRIDGE_SUBNET=10.44.0.0/24
SERVICE_NAME=brig-containerd
POOL_SERVICE_NAME=brig-devpool
SNAPSHOTTER=devmapper
POOL_FS=ext2
POOL_BASE_IMAGE_SIZE=10GB
VIRTIOFSD_OPTIONS="--cache always --sandbox none"
BRIG_GROUP=brig

GITHUB="https://github.com"
NAME="brig-standalone-$VERSION-linux-$ARCH"
TMP_DIR="$(mktemp -d)"
# The urunc/urunit/initrd builds run in docker as root and leave root-owned files
# (vendored deps, dist/, apt caches) under TMP_DIR. A non-root builder -- a CI
# runner -- cannot rm those, and a failing cleanup would fail the whole build
# after the tarball was already produced. So reclaim them via docker if a plain
# rm cannot, and never let cleanup change the exit status.
cleanup() {
    [ -n "${TMP_DIR:-}" ] && [ -d "$TMP_DIR" ] || return 0
    rm -rf "$TMP_DIR" 2>/dev/null && return 0
    if command -v docker >/dev/null 2>&1; then
        docker run --rm -v "$TMP_DIR":/t alpine:3.20 \
            chown -R "$(id -u):$(id -g)" /t >/dev/null 2>&1 || true
        rm -rf "$TMP_DIR" 2>/dev/null || true
    fi
    return 0
}
trap cleanup EXIT INT TERM
STAGE="$TMP_DIR/$NAME"
DL="$TMP_DIR/dl"
mkdir -p "$STAGE/bin" "$STAGE/libexec" "$STAGE/libexec/cni" "$STAGE/share/guest" "$DL" "$OUT"

COMPONENTS="$TMP_DIR/components"
: > "$COMPONENTS"

# record <name> <version> <license> <url> <file>
record() {
    printf '%s\t%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" "$(sha256sum "$5" | awk '{print $1}')" \
        >> "$COMPONENTS"
}

# brig-ctl: drive the private stack by hand. Baked with the fixed layout.
write_brig_ctl() {
    cat > "$STAGE/bin/brig-ctl" <<CTLENV
#!/bin/sh
# brig-ctl: run ctr, nerdctl and friends against the private brig stack.
set -eu
PREFIX="$PREFIX"
CONTAINERD_ADDRESS="$CONTAINERD_SOCK"
CONTAINERD_NAMESPACE="$NAMESPACE"
CONTAINERD_SNAPSHOTTER="$SNAPSHOTTER"
NERDCTL_TOML="$ETC_DIR/nerdctl.toml"
CNI_PATH="$CNI_DIR"
SERVICE_NAME="$SERVICE_NAME"
BRIG_ENV="$ETC_DIR/brig-env.sh"
CTLENV
    cat >> "$STAGE/bin/brig-ctl" <<'CTLBODY'
export CONTAINERD_ADDRESS CONTAINERD_NAMESPACE CONTAINERD_SNAPSHOTTER NERDCTL_TOML CNI_PATH
PATH="$PREFIX/bin:$PATH"
export PATH

cmd="${1:-help}"
[ $# -gt 0 ] && shift

case "$cmd" in
    ctr)
        exec "$PREFIX/bin/ctr" --address "$CONTAINERD_ADDRESS" \
            --namespace "$CONTAINERD_NAMESPACE" "$@" ;;
    nerdctl)
        exec "$PREFIX/bin/nerdctl" "$@" ;;
    run)
        exec "$PREFIX/bin/nerdctl" run --runtime io.containerd.urunc.v2 \
            --snapshotter "$CONTAINERD_SNAPSHOTTER" "$@" ;;
    env)
        cat "$BRIG_ENV" ;;
    version)
        cat "$PREFIX/pins.env" ;;
    status)
        if command -v systemctl >/dev/null 2>&1; then
            systemctl --no-pager status "$SERVICE_NAME.service" || true
        fi
        echo
        "$PREFIX/bin/ctr" --address "$CONTAINERD_ADDRESS" plugin ls 2>/dev/null \
            | awk 'NR==1 || /snapshotter/ || /urunc/' ;;
    uninstall)
        exec "$PREFIX/bin/brig-uninstall.sh" "$@" ;;
    help|--help|-h)
        cat <<USAGE
brig-ctl <command> [args]

  ctr [args]        ctr against the private containerd
  nerdctl [args]    nerdctl against the private containerd
  run <image>       nerdctl run with the urunc runtime and snapshotter
  env               shell exports for driving the stack by hand
  status            service state and the relevant containerd plugins
  version           the bundled component versions
  uninstall         remove this install
USAGE
        ;;
    *)
        echo "unknown command '$cmd', try 'brig-ctl help'" >&2
        exit 1 ;;
esac
CTLBODY
    chmod 0755 "$STAGE/bin/brig-ctl"
}

# brig-uninstall.sh: static, reads the .install-stamp install.sh writes, and
# removes exactly what that install created.
write_uninstaller() {
    cat > "$STAGE/bin/brig-uninstall.sh" <<'UNEOF'
#!/bin/sh
#
# Remove a standalone brig install. Part of the brig bundle.
#
# Reads .install-stamp and removes exactly what that install created. A pool it
# did not create, a symlink that no longer points into this tree, a group it did
# not add, and anything belonging to the host are left alone.
#
#   brig-uninstall.sh [--keep-data] [--yes]

set -eu

SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
PREFIX_GUESS="$(dirname "$SELF_DIR")"
STAMP="$PREFIX_GUESS/.install-stamp"

info() { echo "[brig-uninstall] $*" >&2; }
warn() { echo "[brig-uninstall] WARNING: $*" >&2; }
fatal() { echo "[brig-uninstall] ERROR: $*" >&2; exit 1; }

KEEP_DATA=false
ASSUME_YES=false
for arg in "$@"; do
    case "$arg" in
        --keep-data) KEEP_DATA=true ;;
        --yes|-y) ASSUME_YES=true ;;
        --help|-h) sed -n '2,12p' "$0"; exit 0 ;;
        *) fatal "unknown argument '$arg'" ;;
    esac
done

[ "$(id -u)" -eq 0 ] || fatal "run this as root"
[ -f "$STAMP" ] || fatal "no install stamp at $STAMP, refusing to remove anything"

# shellcheck disable=SC1090
. "$STAMP"

[ "$PREFIX" = "$PREFIX_GUESS" ] || fatal "stamp says $PREFIX but this script lives under $PREFIX_GUESS"

if [ "$ASSUME_YES" != "true" ]; then
    echo "About to remove the brig install at $PREFIX (state in $DATA_DIR)." >&2
    [ "$KEEP_DATA" = "true" ] && echo "State under $DATA_DIR will be kept." >&2
    printf 'Continue? [y/N] ' >&2
    read -r answer </dev/tty || answer=n
    case "$answer" in y|Y|yes|YES) ;; *) info "aborted"; exit 0 ;; esac
fi

if [ "${SYSTEMD_INSTALLED:-false}" = "true" ] && command -v systemctl >/dev/null 2>&1; then
    for unit in "$SERVICE_NAME" "${POOL_SERVICE_NAME:-}"; do
        [ -n "$unit" ] || continue
        systemctl stop "$unit.service" >/dev/null 2>&1 || true
        systemctl disable "$unit.service" >/dev/null 2>&1 || true
    done
    systemctl daemon-reload || true
    systemctl reset-failed >/dev/null 2>&1 || true
    info "stopped and disabled the units"
fi

pkill -f "containerd --config $PREFIX/etc/containerd.toml" 2>/dev/null || true
pkill -f "containerd-shim-urunc-v2.*$PREFIX" 2>/dev/null || true
sleep 1

if [ -r /proc/self/mounts ]; then
    awk -v a="$PREFIX" -v b="$DATA_DIR" -v c="$RUN_DIR" \
        '$2 ~ "^"a || $2 ~ "^"b || $2 ~ "^"c {print $2}' /proc/self/mounts \
        | sort -r | while read -r mp; do
        umount "$mp" 2>/dev/null || umount -l "$mp" 2>/dev/null || true
    done
fi

if [ "${POOL_CREATED:-false}" = "true" ] && [ -n "${POOL_NAME:-}" ]; then
    if dmsetup info "$POOL_NAME" >/dev/null 2>&1; then
        held="$(dmsetup status "$POOL_NAME" 2>/dev/null | awk '{print $7}')"
        if [ -n "$held" ] && [ "$held" != "-" ]; then
            info "releasing the held metadata snapshot on $POOL_NAME"
            dmsetup message "$POOL_NAME" 0 release_metadata_snap 2>/dev/null || true
        fi
        dmsetup ls 2>/dev/null | awk -v p="$POOL_NAME" '$1 ~ "^"p"-snap" {print $1}' \
            | while read -r thin; do
                dmsetup remove "$thin" 2>/dev/null || dmsetup remove -f "$thin" 2>/dev/null || true
            done
        info "removing device-mapper pool $POOL_NAME"
        dmsetup remove "$POOL_NAME" 2>/dev/null \
            || dmsetup remove -f "$POOL_NAME" 2>/dev/null \
            || warn "could not remove the pool $POOL_NAME, it may still be in use"
    fi
elif [ -n "${POOL_NAME:-}" ]; then
    info "pool $POOL_NAME was not created by this install, leaving it alone"
fi

for dev in "${POOL_LOOP_DATA:-}" "${POOL_LOOP_META:-}"; do
    [ -n "$dev" ] || continue
    [ -b "$dev" ] || continue
    back="$(losetup -l -n -O BACK-FILE "$dev" 2>/dev/null | tr -d ' ')"
    case "$back" in
        "$DATA_DIR"/*) info "detaching $dev"; losetup -d "$dev" 2>/dev/null || true ;;
        *) warn "$dev no longer backs a file under $DATA_DIR, leaving it attached" ;;
    esac
done

if [ -n "${ETC_SYMLINK:-}" ]; then
    if [ -L "$ETC_SYMLINK" ] && [ "$(readlink "$ETC_SYMLINK")" = "$PREFIX/etc/urunc.toml" ]; then
        rm -f "$ETC_SYMLINK"
        info "removed $ETC_SYMLINK"
        if [ -n "${ETC_SYMLINK_BACKUP:-}" ] && [ -e "$ETC_SYMLINK_BACKUP" ]; then
            mv "$ETC_SYMLINK_BACKUP" "$ETC_SYMLINK"
            info "restored the previous $ETC_SYMLINK"
        fi
    else
        warn "$ETC_SYMLINK no longer points into $PREFIX, leaving it alone"
    fi
    rmdir /etc/urunc 2>/dev/null || true
fi

for l in "${BRIG_LAUNCHER:-}" "${BRIGD_LAUNCHER:-}"; do
    [ -n "$l" ] || continue
    if [ -f "$l" ] && grep -q "$PREFIX/bin" "$l" 2>/dev/null; then
        rm -f "$l"
        info "removed $l"
    fi
done

if [ -n "${BRIDGE_NAME:-}" ] && ip link show "$BRIDGE_NAME" >/dev/null 2>&1; then
    ip link set "$BRIDGE_NAME" down 2>/dev/null || true
    ip link delete "$BRIDGE_NAME" 2>/dev/null || true
    info "removed the CNI bridge $BRIDGE_NAME"
fi

if [ "${GROUP_CREATED:-false}" = "true" ] && [ -n "${BRIG_GROUP:-}" ]; then
    if command -v groupdel >/dev/null 2>&1; then
        if groupdel "$BRIG_GROUP" 2>/dev/null; then
            info "removed the $BRIG_GROUP group"
        else
            warn "could not remove the $BRIG_GROUP group (a user may still list it)"
        fi
    fi
fi

rm -rf "${PREFIX:?}"
rm -rf "${RUN_DIR:?}"
info "removed $PREFIX and $RUN_DIR"
if [ "$KEEP_DATA" = "true" ]; then
    info "kept state under $DATA_DIR"
else
    rm -rf "${DATA_DIR:?}"
    info "removed $DATA_DIR"
fi

info "done"
UNEOF
    chmod 0755 "$STAGE/bin/brig-uninstall.sh"
}

fetch() {
    curl -sfL --retry 3 --retry-delay 2 -o "$2" "$1" || fatal "failed to download $1"
}

# Verify against an upstream sums file when the project publishes one. A
# component without published checksums still gets its sha256 recorded in
# components.json, so the bundle is pinned either way.
verify() {
    file="$1"; sums_url="$2"; name="$3"
    actual="$(sha256sum "$file" | awk '{print $1}')"
    [ -n "$sums_url" ] || { info "  $name: no upstream checksums, recorded $actual"; return 0; }
    if curl -sfL --retry 2 -o "$TMP_DIR/sums.txt" "$sums_url" 2>/dev/null; then
        expected="$(awk -v n="$name" '$2 == n || $2 == "*"n {print $1; exit}' "$TMP_DIR/sums.txt")"
        [ -n "$expected" ] || expected="$(awk 'NF==1 {print $1; exit}' "$TMP_DIR/sums.txt")"
        if [ -n "$expected" ] && [ "$expected" != "$actual" ]; then
            fatal "checksum mismatch for $name: expected $expected, got $actual"
        fi
        info "  $name: verified"
    else
        info "  $name: no upstream checksums, recorded $actual"
    fi
}

info "building $NAME (variant $VARIANT)"
info "fetching components"

# ---- urunc: built from source (generic-boot) or a released tag (stock) -------
if [ "$VARIANT" = "stock" ] && [ -n "$URUNC_VERSION_STOCK" ]; then
    u_base="$GITHUB/$URUNC_REPO/releases/download/$URUNC_VERSION_STOCK"
    fetch "$u_base/urunc_static_$ARCH" "$DL/urunc"
    verify "$DL/urunc" "" "urunc_static_$ARCH"
    fetch "$u_base/containerd-shim-urunc-v2_static_$ARCH" "$DL/containerd-shim-urunc-v2"
    verify "$DL/containerd-shim-urunc-v2" "" "containerd-shim-urunc-v2_static_$ARCH"
    URUNC_SOURCE="$URUNC_REPO@$URUNC_VERSION_STOCK"
    URUNC_REF="$URUNC_VERSION_STOCK"
else
    command -v docker >/dev/null 2>&1 || fatal "docker is required to build urunc from $URUNC_REPO@$URUNC_BRANCH"
    command -v git >/dev/null 2>&1 || fatal "git is required to build urunc from source"
    info "building urunc from $URUNC_REPO@$URUNC_BRANCH ($URUNC_GO_IMAGE, linux/$ARCH)"
    src="$TMP_DIR/urunc-src"
    git clone --depth 1 --branch "$URUNC_BRANCH" "https://github.com/$URUNC_REPO" "$src" 2>/dev/null \
        || git clone "https://github.com/$URUNC_REPO" "$src"
    ( cd "$src" && git checkout "$URUNC_BRANCH" 2>/dev/null ) || true
    URUNC_REF="$(cd "$src" && git rev-parse HEAD)"
    # --platform builds native inside a target-arch container (needs binfmt for
    # a cross build). The static urunc binary is CGO, so this is not a Go cross
    # compile.
    docker run --rm --platform "linux/$ARCH" -v "$src":/app -w /app -e HOME=/tmp "$URUNC_GO_IMAGE" \
        sh -c "git config --global --add safe.directory /app && make static" \
        || fatal "urunc build failed"
    cp "$src/dist/urunc_static_$ARCH" "$DL/urunc" 2>/dev/null || cp "$src/dist/urunc" "$DL/urunc"
    cp "$src/dist/containerd-shim-urunc-v2_static_$ARCH" "$DL/containerd-shim-urunc-v2" 2>/dev/null \
        || cp "$src/dist/containerd-shim-urunc-v2" "$DL/containerd-shim-urunc-v2"
    chmod 0755 "$DL/urunc" "$DL/containerd-shim-urunc-v2"
    URUNC_SOURCE="$URUNC_REPO@$URUNC_REF"
    info "  built urunc $URUNC_REF"
fi

# ---- urunit + the brig container-initrd (generic-boot / introspection) -------
# brig builds its own initrd rather than shipping hull-assets': it execs into a
# guest through urunit-agent, which has to match the urunc shim's protocol, so
# the agent is built from the same urunc checkout ($src) as the shim above.
URUNIT_REF=""
if [ "$VARIANT" != "stock" ]; then
    command -v docker >/dev/null 2>&1 || fatal "docker is required to build the brig initrd"
    [ -d "${src:-}" ] || fatal "the urunc checkout is needed to build the initrd (build urunc from source)"
    info "building urunit from $URUNIT_REPO@$URUNIT_BRANCH (linux/$ARCH)"
    usrc="$TMP_DIR/urunit-src"
    git clone --depth 1 --branch "$URUNIT_BRANCH" "https://github.com/$URUNIT_REPO" "$usrc" 2>/dev/null \
        || git clone "https://github.com/$URUNIT_REPO" "$usrc"
    ( cd "$usrc" && git checkout "$URUNIT_BRANCH" 2>/dev/null ) || true
    URUNIT_REF="$(cd "$usrc" && git rev-parse HEAD)"
    docker run --rm --platform "linux/$ARCH" -v "$usrc":/u -w /u alpine:3.20 \
        sh -c "apk add --no-cache build-base linux-headers make musl-dev >/dev/null && make static" \
        || fatal "urunit build failed"
    [ -s "$usrc/dist/urunit_static" ] || fatal "no urunit_static produced by the build"

    info "building the brig container-initrd (urunit + urunit-agent + busybox)"
    docker run --rm --platform "linux/$ARCH" \
        -v "$src":/app -v "$usrc/dist/urunit_static":/urunit-static:ro \
        -w /app -e HOME=/tmp -e URUNIT=/urunit-static -e TARGET_ARCH="$ARCH_UNAME" "$URUNC_GO_IMAGE" \
        sh -c "apt-get update >/dev/null 2>&1 && apt-get install -y cpio curl >/dev/null 2>&1 && git config --global --add safe.directory /app && ./packaging/container-initrd/build-container-initrd.sh /app/dist/container-initrd" \
        || fatal "container-initrd build failed"
    [ -s "$src/dist/container-initrd" ] || fatal "no container-initrd produced"
    cp "$src/dist/container-initrd" "$DL/container-initrd"
    chmod 0644 "$DL/container-initrd"
    info "  built container-initrd ($(stat -c%s "$DL/container-initrd") bytes)"
fi

# ---- brig + brigd ------------------------------------------------------------
# brig is not built here: its own release is fetched and repackaged into the tree.
# "latest" resolves to brig's newest release (prereleases included).
if [ "$VARIANT" != "stock" ] || [ "${BRIG_IN_STOCK:-true}" = "true" ]; then
    if [ "$BRIG_VERSION" = "latest" ]; then
        BRIG_VERSION="$(curl -sfL "https://api.github.com/repos/$BRIG_REPO/releases" \
            | sed -n 's/.*"tag_name": *"\([^"]*\)".*/\1/p' | head -1)"
        [ -n "$BRIG_VERSION" ] || fatal "could not resolve the latest brig release from $BRIG_REPO"
        info "brig latest release is $BRIG_VERSION"
    fi
    bare="${BRIG_VERSION#v}"
    b_archive="brig-${bare}-linux-${ARCH}.tar.gz"
    b_base="$GITHUB/$BRIG_REPO/releases/download/$BRIG_VERSION"
    fetch "$b_base/$b_archive" "$DL/brig.tar.gz"
    verify "$DL/brig.tar.gz" "$b_base/checksums.txt" "$b_archive"
    mkdir -p "$TMP_DIR/brig-unpack"
    tar -xzf "$DL/brig.tar.gz" -C "$TMP_DIR/brig-unpack"
    bb="$(find "$TMP_DIR/brig-unpack" -name brig -type f | head -1)"
    bd="$(find "$TMP_DIR/brig-unpack" -name brigd -type f | head -1)"
    [ -n "$bb" ] || fatal "no brig binary in $b_archive"
    install -m 0755 "$bb" "$STAGE/bin/brig"
    [ -n "$bd" ] && install -m 0755 "$bd" "$STAGE/bin/brigd"
    comp="$(dirname "$bb")/completions"
    [ -d "$comp" ] && { mkdir -p "$STAGE/share/completions"; cp -a "$comp/." "$STAGE/share/completions/"; }
fi

# ---- oras --------------------------------------------------------------------
o_ver="${ORAS_VERSION#v}"
o_name="oras_${o_ver}_linux_${ARCH}.tar.gz"
fetch "$GITHUB/oras-project/oras/releases/download/$ORAS_VERSION/$o_name" "$DL/oras.tar.gz"
verify "$DL/oras.tar.gz" "$GITHUB/oras-project/oras/releases/download/$ORAS_VERSION/oras_${o_ver}_checksums.txt" "$o_name"
mkdir -p "$TMP_DIR/oras-unpack"
tar -xzf "$DL/oras.tar.gz" -C "$TMP_DIR/oras-unpack"
install -m 0755 "$(find "$TMP_DIR/oras-unpack" -name oras -type f | head -1)" "$STAGE/bin/oras"

# ---- cosign (pinned by hash, cannot self-verify) -----------------------------
case "$ARCH" in
    amd64) cosign_sha="$COSIGN_SHA_LINUX_AMD64" ;;
    arm64) cosign_sha="$COSIGN_SHA_LINUX_ARM64" ;;
esac
fetch "$GITHUB/sigstore/cosign/releases/download/$COSIGN_VERSION/cosign-linux-$ARCH" "$DL/cosign"
c_actual="$(sha256sum "$DL/cosign" | awk '{print $1}')"
[ "$cosign_sha" = "$c_actual" ] || fatal "cosign hash mismatch: expected $cosign_sha, got $c_actual"
install -m 0755 "$DL/cosign" "$STAGE/bin/cosign"
info "  cosign: verified against the pinned hash"

# ---- the private-stack components --------------------------------------------
m_name="release-$ARCH-$MONITORS_VERSION.tar.gz"
fetch "$GITHUB/urunc-dev/monitors-build/releases/download/$MONITORS_VERSION/$m_name" "$DL/monitors.tar.gz"
verify "$DL/monitors.tar.gz" "" "$m_name"

c_ver="${CONTAINERD_VERSION#v}"
c_name="containerd-$c_ver-linux-$ARCH.tar.gz"
fetch "$GITHUB/containerd/containerd/releases/download/$CONTAINERD_VERSION/$c_name" "$DL/containerd.tar.gz"
verify "$DL/containerd.tar.gz" \
    "$GITHUB/containerd/containerd/releases/download/$CONTAINERD_VERSION/$c_name.sha256sum" "$c_name"

fetch "$GITHUB/opencontainers/runc/releases/download/$RUNC_VERSION/runc.$ARCH" "$DL/runc"
verify "$DL/runc" \
    "$GITHUB/opencontainers/runc/releases/download/$RUNC_VERSION/runc.sha256sum" "runc.$ARCH"

n_ver="${NERDCTL_VERSION#v}"
n_name="nerdctl-$n_ver-linux-$ARCH.tar.gz"
fetch "$GITHUB/containerd/nerdctl/releases/download/$NERDCTL_VERSION/$n_name" "$DL/nerdctl.tar.gz"
verify "$DL/nerdctl.tar.gz" \
    "$GITHUB/containerd/nerdctl/releases/download/$NERDCTL_VERSION/SHA256SUMS" "$n_name"

cni_name="cni-plugins-linux-$ARCH-$CNI_VERSION.tgz"
fetch "$GITHUB/containernetworking/plugins/releases/download/$CNI_VERSION/$cni_name" "$DL/cni.tgz"
verify "$DL/cni.tgz" \
    "$GITHUB/containernetworking/plugins/releases/download/$CNI_VERSION/$cni_name.sha256" "$cni_name"

info "laying out the tree"
install -m 0755 "$DL/urunc" "$STAGE/bin/urunc"
install -m 0755 "$DL/containerd-shim-urunc-v2" "$STAGE/bin/containerd-shim-urunc-v2"
install -m 0755 "$DL/runc" "$STAGE/bin/runc"
tar -xzf "$DL/containerd.tar.gz" -C "$STAGE" bin/
tar -xzf "$DL/nerdctl.tar.gz" -C "$STAGE/bin" nerdctl
tar -xzf "$DL/cni.tgz" -C "$STAGE/libexec/cni"

mkdir -p "$TMP_DIR/monitors"
tar -xzf "$DL/monitors.tar.gz" -C "$TMP_DIR/monitors" --wildcards '*urunc/bin/*'
mon_bin="$TMP_DIR/monitors/urunc/bin"
for m in $MONITORS; do
    case "$m" in
        firecracker|cloud-hypervisor|solo5-hvt|solo5-spt) src_m="$m" ;;
        qemu) src_m="qemu-system-$ARCH_UNAME" ;;
        *) fatal "unknown monitor '$m' in the pins" ;;
    esac
    [ -f "$mon_bin/$src_m" ] || fatal "monitor '$m' not in $MONITORS_VERSION"
    install -m 0755 "$mon_bin/$src_m" "$STAGE/bin/$src_m"
done

# virtiofsd is how a guest gets the container rootfs when there is no block
# device to hand it. It comes from the same release and costs 3MB.
if [ "$VIRTIOFSD" = "true" ]; then
    [ -f "$mon_bin/virtiofsd" ] || fatal "virtiofsd not in $MONITORS_VERSION"
    install -m 0755 "$mon_bin/virtiofsd" "$STAGE/libexec/virtiofsd"
fi
chmod 0755 "$STAGE"/bin/*

# ---- guest boot assets (generic-boot / introspection) ------------------------
# The kernel comes from hull-assets (pulled with the oras we just bundled, from
# the same repo and tags brig and hull use). The initrd does not: hull-assets'
# initrd carries hull's agent, so it is thrown away and the brig-built one above
# takes its place. A fresh bundle.json records the urunc the agent was built
# against, so the installer can check coherence.
ASSETS_URUNC_REF=""
if [ "$VARIANT" != "stock" ]; then
    a_tag="$ASSETS_VERSION-linux-$ARCH"
    info "fetching the guest kernel $ASSETS_REPO:$a_tag with oras"
    ( cd "$STAGE/share/guest" \
      && "$STAGE/bin/oras" pull "$ASSETS_REGISTRY/$ASSETS_REPO:$a_tag" ) \
        || fatal "could not pull $ASSETS_REPO:$a_tag"
    case "$ARCH" in amd64) kernel=bzImage ;; arm64) kernel=Image ;; esac
    [ -f "$STAGE/share/guest/$kernel" ] || fatal "no $kernel in the guest assets"

    # Replace hull's initrd with the brig-built one.
    [ -f "$DL/container-initrd" ] || fatal "the brig container-initrd was not built"
    cp "$DL/container-initrd" "$STAGE/share/guest/container-initrd"
    magic="$(od -An -tx1 -N2 "$STAGE/share/guest/container-initrd" | tr -d ' \n')"
    [ "$magic" = "1f8b" ] && fatal "container-initrd is gzipped; it must stay uncompressed"
    ASSETS_URUNC_REF="$URUNC_REF"
    cat > "$STAGE/share/guest/bundle.json" <<JSON
{"ref": "$URUNC_REF", "urunit": "$URUNIT_REF", "built_by": "brig-build-bundle"}
JSON
    info "  kernel from hull-assets, initrd built for brig (urunc $URUNC_REF)"
fi

# ---- config files, systemd units, wrappers -----------------------------------
# Everything below is baked into the tree with the fixed /opt/brig layout, so the
# installer only unpacks it. install.sh retargets the snapshotter to overlayfs on
# a host without a thin pool, and fills in the rest of the host wiring.
info "writing config, units and wrappers"
mkdir -p "$STAGE/etc/cni/net.d" "$STAGE/etc/systemd" "$STAGE/etc/certs.d"

# urunc.toml -- explicit paths for the monitors we shipped; PATH for the rest.
{
    cat <<CFG
# urunc configuration, generated by build-bundle.sh for $PREFIX

[log]
level = "info"
syslog = false

[timestamps]
enabled = false
destination = "$LOG_DIR/timestamps.log"
CFG
    for m in $MONITORS; do
        case "$m" in
            firecracker) sect=firecracker; bin=firecracker ;;
            cloud-hypervisor) sect=cloud-hypervisor; bin=cloud-hypervisor ;;
            solo5-hvt) sect=hvt; bin=solo5-hvt ;;
            solo5-spt) sect=spt; bin=solo5-spt ;;
            qemu) sect=qemu; bin="qemu-system-$ARCH_UNAME" ;;
            *) continue ;;
        esac
        printf '\n[monitors.%s]\ndefault_memory_mb = 256\ndefault_vcpus = 1\npath = "%s/%s"\n' \
            "$sect" "$BIN_DIR" "$bin"
    done
    [ "$VIRTIOFSD" = "true" ] && printf '\n[extra_binaries.virtiofsd]\npath = "%s/virtiofsd"\noptions = "%s"\n' \
        "$LIBEXEC_DIR" "$VIRTIOFSD_OPTIONS"
} > "$STAGE/etc/urunc.toml"

# containerd.toml -- no grpc.gid: the systemd unit chgrps the socket to the brig
# group by name, so this file is host-independent.
cat > "$STAGE/etc/containerd.toml" <<CFG
version = 3
root = '$DATA_DIR/containerd'
state = '$RUN_DIR/containerd'
temp = '$RUN_DIR/tmp'
disabled_plugins = ['io.containerd.cri.v1.runtime', 'io.containerd.cri.v1.images', 'io.containerd.grpc.v1.cri']

[grpc]
  address = '$CONTAINERD_SOCK'

[debug]
  address = '$RUN_DIR/debug.sock'
  level = 'info'

[metrics]
  address = ''

[[plugins.'io.containerd.transfer.v1.local'.unpack_config]]
  platform = 'linux/$ARCH'
  snapshotter = '$SNAPSHOTTER'

[[plugins.'io.containerd.transfer.v1.local'.unpack_config]]
  platform = 'linux/$ARCH'
  snapshotter = 'overlayfs'

[plugins.'io.containerd.snapshotter.v1.devmapper']
  pool_name = '$POOL_NAME'
  root_path = '$DATA_DIR/devmapper-snap'
  base_image_size = '$POOL_BASE_IMAGE_SIZE'
  discard_blocks = true
  fs_type = '$POOL_FS'
CFG

# nerdctl.toml
cat > "$STAGE/etc/nerdctl.toml" <<CFG
debug = false
address = "unix://$CONTAINERD_SOCK"
namespace = "$NAMESPACE"
snapshotter = "$SNAPSHOTTER"
cni_path = "$CNI_DIR"
cni_netconfpath = "$ETC_DIR/cni/net.d"
data_root = "$DATA_DIR/nerdctl"
cgroup_manager = "systemd"
hosts_dir = ["$ETC_DIR/certs.d"]
CFG

# CNI bridge, off the host default 10.4.0.0/24.
gw="$(echo "$BRIDGE_SUBNET" | awk -F'[./]' '{print $1"."$2"."$3".1"}')"
cat > "$STAGE/etc/cni/net.d/10-brig-bridge.conflist" <<CNIEOF
{
  "cniVersion": "1.0.0",
  "name": "bridge",
  "nerdctlID": "brig-standalone",
  "nerdctlLabels": {},
  "plugins": [
    {
      "type": "bridge",
      "bridge": "$BRIDGE_NAME",
      "isGateway": true,
      "ipMasq": true,
      "hairpinMode": true,
      "ipam": {
        "type": "host-local",
        "ranges": [[{"subnet": "$BRIDGE_SUBNET", "gateway": "$gw"}]],
        "routes": [{"dst": "0.0.0.0/0"}]
      }
    },
    {"type": "portmap", "capabilities": {"portMappings": true}},
    {"type": "firewall", "ingressPolicy": "same-bridge"},
    {"type": "tuning"}
  ]
}
CNIEOF

# brig-env.sh -- sourced by the launchers so brig drives the private stack.
cat > "$STAGE/etc/brig-env.sh" <<CFG
# brig environment, generated by build-bundle.sh. Source before running brig.
export CONTAINERD_ADDRESS="unix://$CONTAINERD_SOCK"
export CONTAINERD_NAMESPACE="$NAMESPACE"
export CONTAINERD_SNAPSHOTTER="$SNAPSHOTTER"
export NERDCTL_TOML="$ETC_DIR/nerdctl.toml"
export CNI_PATH="$CNI_DIR"
export BRIG_RUNTIME="nerdctl"
export BRIG_RUNTIME_BIN="$BIN_DIR/nerdctl"
export BRIG_BOOT_ASSETS="$SHARE_DIR/guest"
export PATH="$BIN_DIR:\$PATH"
CFG

# systemd: the pool re-creation oneshot and the containerd service. The service
# hands the socket to the brig group by name once containerd is up.
cat > "$STAGE/etc/systemd/$POOL_SERVICE_NAME.service" <<UNIT
[Unit]
Description=brig device-mapper thin pool ($POOL_NAME)
DefaultDependencies=no
After=local-fs.target
Before=$SERVICE_NAME.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=$BIN_DIR/brig-pool-up

[Install]
WantedBy=multi-user.target
UNIT

cat > "$STAGE/etc/systemd/$SERVICE_NAME.service" <<UNIT
[Unit]
Description=brig standalone containerd ($PREFIX)
Documentation=https://github.com/brig-sh/brig
After=network.target local-fs.target
Requires=$POOL_SERVICE_NAME.service
After=$POOL_SERVICE_NAME.service

[Service]
Type=notify
Delegate=yes
KillMode=process
Restart=always
RestartSec=5
ExecStartPre=-/bin/mkdir -p $RUN_DIR
ExecStartPre=-/bin/chmod 0710 $RUN_DIR
Environment=PATH=$BIN_DIR:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
ExecStart=$BIN_DIR/containerd --config $ETC_DIR/containerd.toml
# Hand the socket to the brig group so a non-root member can drive the stack.
ExecStartPost=/bin/sh -c 'for _ in 1 2 3 4 5; do [ -S $CONTAINERD_SOCK ] && break; sleep 1; done; chgrp $BRIG_GROUP $CONTAINERD_SOCK 2>/dev/null || true; chmod 0660 $CONTAINERD_SOCK 2>/dev/null || true'
LimitNPROC=infinity
LimitCORE=infinity
TasksMax=infinity
OOMScoreAdjust=-999

[Install]
WantedBy=multi-user.target
UNIT

# brig-pool-up: re-create the loop-backed pool after a reboot.
cat > "$STAGE/bin/brig-pool-up" <<POOLUP
#!/bin/sh
# Re-create the loop backed thin pool after a reboot. Part of the brig bundle.
set -eu
POOL_NAME="$POOL_NAME"
DATA="$DATA_DIR/devmapper/data"
META="$DATA_DIR/devmapper/meta"
dmsetup info "\$POOL_NAME" >/dev/null 2>&1 && exit 0
[ -f "\$DATA" ] || exit 0
modprobe dm_thin_pool 2>/dev/null || true
DATA_DEV="\$(losetup -j "\$DATA" | cut -d: -f1)"
[ -n "\$DATA_DEV" ] || DATA_DEV="\$(losetup --find --show "\$DATA")"
META_DEV="\$(losetup -j "\$META" | cut -d: -f1)"
[ -n "\$META_DEV" ] || META_DEV="\$(losetup --find --show "\$META")"
SECTORS=\$(( \$(blockdev --getsize64 "\$DATA_DEV") / 512 ))
dmsetup create "\$POOL_NAME" --table "0 \$SECTORS thin-pool \$META_DEV \$DATA_DEV 128 32768"
POOLUP
chmod 0755 "$STAGE/bin/brig-pool-up"

write_brig_ctl
write_uninstaller

# ---- component manifest ------------------------------------------------------
# Licenses are recorded by hand. syft reads Go build info out of the Go
# binaries, but firecracker, cloud-hypervisor and the solo5 tenders are Rust and
# C, so their licenses have to come from somewhere else.
[ -x "$STAGE/bin/brig" ] && record brig "$BRIG_VERSION" "Apache-2.0" \
    "$GITHUB/$BRIG_REPO/releases/tag/$BRIG_VERSION" "$STAGE/bin/brig"
[ -x "$STAGE/bin/brigd" ] && record brigd "$BRIG_VERSION" "Apache-2.0" \
    "$GITHUB/$BRIG_REPO/releases/tag/$BRIG_VERSION" "$STAGE/bin/brigd"
record urunc "$URUNC_REF" "Apache-2.0" "$GITHUB/$URUNC_REPO/tree/$URUNC_BRANCH" "$STAGE/bin/urunc"
record containerd-shim-urunc-v2 "$URUNC_REF" "Apache-2.0" \
    "$GITHUB/$URUNC_REPO/tree/$URUNC_BRANCH" "$STAGE/bin/containerd-shim-urunc-v2"
record cosign "$COSIGN_VERSION" "Apache-2.0" \
    "$GITHUB/sigstore/cosign/releases/tag/$COSIGN_VERSION" "$STAGE/bin/cosign"
record oras "$ORAS_VERSION" "Apache-2.0" \
    "$GITHUB/oras-project/oras/releases/tag/$ORAS_VERSION" "$STAGE/bin/oras"
record containerd "$CONTAINERD_VERSION" "Apache-2.0" \
    "$GITHUB/containerd/containerd/releases/tag/$CONTAINERD_VERSION" "$STAGE/bin/containerd"
record ctr "$CONTAINERD_VERSION" "Apache-2.0" \
    "$GITHUB/containerd/containerd/releases/tag/$CONTAINERD_VERSION" "$STAGE/bin/ctr"
record runc "$RUNC_VERSION" "Apache-2.0" \
    "$GITHUB/opencontainers/runc/releases/tag/$RUNC_VERSION" "$STAGE/bin/runc"
record nerdctl "$NERDCTL_VERSION" "Apache-2.0" \
    "$GITHUB/containerd/nerdctl/releases/tag/$NERDCTL_VERSION" "$STAGE/bin/nerdctl"
record cni-plugins "$CNI_VERSION" "Apache-2.0" \
    "$GITHUB/containernetworking/plugins/releases/tag/$CNI_VERSION" "$STAGE/libexec/cni/bridge"
if [ "$VIRTIOFSD" = "true" ]; then
    record virtiofsd "$(echo "$MONITORS_VERSION" | sed 's/.*VFS_*-\(v[^_]*\).*/\1/')" \
        "Apache-2.0 AND BSD-3-Clause" \
        "$GITHUB/urunc-dev/monitors-build/releases/tag/$MONITORS_VERSION" \
        "$STAGE/libexec/virtiofsd"
fi
for m in $MONITORS; do
    case "$m" in
        firecracker) lic="Apache-2.0"; ver="$(echo "$MONITORS_VERSION" | sed 's/.*FC-\(v[^_]*\).*/\1/')" ;;
        cloud-hypervisor) lic="Apache-2.0 AND BSD-3-Clause"; ver="$(echo "$MONITORS_VERSION" | sed 's/.*CLH-\(v[^_]*\).*/\1/')" ;;
        solo5-hvt|solo5-spt) lic="ISC"; ver="$(echo "$MONITORS_VERSION" | sed 's/.*S5-\(v[^_]*\).*/\1/')" ;;
        qemu) lic="GPL-2.0-only"; ver="$(echo "$MONITORS_VERSION" | sed 's/.*QM-\(v[^-]*\).*/\1/')" ;;
    esac
    case "$m" in qemu) f="$STAGE/bin/qemu-system-$ARCH_UNAME" ;; *) f="$STAGE/bin/$m" ;; esac
    record "$m" "$ver" "$lic" \
        "$GITHUB/urunc-dev/monitors-build/releases/tag/$MONITORS_VERSION" "$f"
done
if [ "$VARIANT" != "stock" ]; then
    case "$ARCH" in amd64) kfile=bzImage ;; arm64) kfile=Image ;; esac
    [ -f "$STAGE/share/guest/$kfile" ] && record guest-kernel "$ASSETS_VERSION" "GPL-2.0" \
        "$ASSETS_REGISTRY/$ASSETS_REPO:$ASSETS_VERSION-linux-$ARCH" "$STAGE/share/guest/$kfile"
    [ -f "${usrc:-}/dist/urunit_static" ] && record urunit "$URUNIT_REF" "Apache-2.0" \
        "$GITHUB/$URUNIT_REPO/tree/$URUNIT_BRANCH" "$usrc/dist/urunit_static"
    [ -f "$STAGE/share/guest/container-initrd" ] && record container-initrd "built:$URUNC_REF" "Apache-2.0" \
        "$GITHUB/$URUNC_REPO/tree/$URUNC_BRANCH (packaging/container-initrd)" \
        "$STAGE/share/guest/container-initrd"
fi

info "writing the manifests"
cat > "$STAGE/pins.env" <<PINS
# Versions in this bundle. Generated by scripts/build-bundle.sh.
BUNDLE_VERSION=$VERSION
ARCH=$ARCH
VARIANT=$VARIANT
BRIG_VERSION=$([ -x "$STAGE/bin/brig" ] && echo "$BRIG_VERSION" || echo "")
BRIG_REPO=$BRIG_REPO
URUNC_VERSION=$URUNC_SOURCE
URUNC_REPO=$URUNC_REPO
URUNC_BRANCH=$URUNC_BRANCH
URUNC_REF=$URUNC_REF
URUNIT_REPO=$([ "$VARIANT" = "stock" ] && echo "" || echo "$URUNIT_REPO")
URUNIT_BRANCH=$([ "$VARIANT" = "stock" ] && echo "" || echo "$URUNIT_BRANCH")
URUNIT_REF=$URUNIT_REF
INITRD_SOURCE=$([ "$VARIANT" = "stock" ] && echo "" || echo "built:$URUNC_REF")
MONITORS_VERSION=$MONITORS_VERSION
MONITORS_INSTALLED="$MONITORS"
VIRTIOFSD_INSTALLED=$VIRTIOFSD
CONTAINERD_VERSION=$CONTAINERD_VERSION
RUNC_VERSION=$RUNC_VERSION
NERDCTL_VERSION=$NERDCTL_VERSION
CNI_VERSION=$CNI_VERSION
ORAS_VERSION=$ORAS_VERSION
COSIGN_VERSION=$COSIGN_VERSION
ASSETS_REPO=$([ "$VARIANT" = "stock" ] && echo "" || echo "$ASSETS_REPO")
ASSETS_VERSION=$([ "$VARIANT" = "stock" ] && echo "" || echo "$ASSETS_VERSION")
ASSETS_URUNC_REF=$ASSETS_URUNC_REF
PINS

{
    echo '{'
    printf '  "bundle": "%s",\n' "$NAME"
    printf '  "version": "%s",\n' "$VERSION"
    printf '  "arch": "linux/%s",\n' "$ARCH"
    printf '  "variant": "%s",\n' "$VARIANT"
    echo '  "components": ['
    n="$(wc -l < "$COMPONENTS")"
    i=0
    while IFS="$(printf '\t')" read -r cname cver clic curl_ csum; do
        i=$((i + 1))
        [ "$i" -lt "$n" ] && sep="," || sep=""
        printf '    {"name": "%s", "version": "%s", "license": "%s", "source": "%s", "sha256": "%s"}%s\n' \
            "$cname" "$cver" "$clic" "$curl_" "$csum" "$sep"
    done < "$COMPONENTS"
    echo '  ]'
    echo '}'
} > "$STAGE/components.json"

# Deterministic tar: sorted names, one fixed timestamp, root-owned, fixed
# directory and file modes, no extended headers. Fetched components are
# byte-identical per pin; the urunc binary and the initrd are byte-identical only
# if their builds are reproducible (fixed commit, SOURCE_DATE_EPOCH, same
# toolchain image), so a bundle's reproducibility rests on those builds too.
info "packing"
find "$STAGE" -type d -exec chmod 0755 {} +
find "$STAGE" -type f ! -perm -u+x -exec chmod 0644 {} +
find "$STAGE" -type f -perm -u+x -exec chmod 0755 {} +
MTIME="${SOURCE_DATE_EPOCH:-0}"
tar --sort=name \
    --mtime="@$MTIME" \
    --owner=0 --group=0 --numeric-owner \
    --format=gnu \
    -C "$TMP_DIR" -cf "$TMP_DIR/$NAME.tar" "$NAME"
gzip -n -9 -c "$TMP_DIR/$NAME.tar" > "$OUT/$NAME.tar.gz"

cp "$STAGE/pins.env" "$OUT/$NAME.pins.env"
cp "$STAGE/components.json" "$OUT/$NAME.components.json"

info "done"
info "  $OUT/$NAME.tar.gz  ($(du -h "$OUT/$NAME.tar.gz" | awk '{print $1}'))"
info "  sha256 $(sha256sum "$OUT/$NAME.tar.gz" | awk '{print $1}')"
