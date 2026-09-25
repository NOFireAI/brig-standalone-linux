#!/bin/sh
#
# Copyright (c) 2026, NOFire AI
# SPDX-License-Identifier: Apache-2.0
#
# Build the self-contained brig bundle for one architecture -- the single tarball
# install.sh fetches and unpacks. This script is where all the building happens.
#
# The tarball is a complete /var/lib/brig/data tree: brig and brigd, cosign and oras, the
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
# --rootless adds the rootless path: rootlesskit, slirp4netns, nerdctl's two
# rootless launchers and brig-rootless-setup.sh. It is a separate artifact
# because a node install driven by root never uses any of it, and a user
# install cannot work without it.
#
# docker is required (the urunc/urunit builds run in containers). Building the
# arm64 pieces on an amd64 runner (or vice versa) needs binfmt/qemu registered,
# because the static urunc binary and urunit are CGO/C and are built native
# inside a target-arch container (docker run --platform).
#
# Produces, under --out:
#   brig-standalone-<version>-linux-<arch>.tar.gz          (the install tarball)
#   brig-standalone-<version>-linux-<arch>.pins.env        (the version manifest)
#
# and with --rootless, the same two named brig-standalone-<version>-rootless-*.

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
# Off by default: a node install driven by root never runs the rootless path,
# and shipping it costs ~39MB and four binaries that would go unused. --rootless
# builds the second artifact, which is the one a user install needs.
ROOTLESS=false

info() { echo "[build-bundle] $*" >&2; }
fatal() { echo "[build-bundle] ERROR: $*" >&2; exit 1; }

while [ $# -gt 0 ]; do
    case "$1" in
        --arch) ARCH="$2"; shift 2 ;;
        --version) VERSION="$2"; shift 2 ;;
        --out) OUT="$2"; shift 2 ;;
        --variant) VARIANT="$2"; shift 2 ;;
        --rootless) ROOTLESS=true; shift ;;
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
# The brig release this bundle carries. On Linux it is the brig a user gets,
# so it is pinned like every other component. Bump it with the brig release a
# bundle is cut for. BRIG_VERSION=latest still works for a local build.
BRIG_VERSION="${BRIG_VERSION:-v0.2.0}"
BRIG_REPO="${BRIG_REPO:-brig-sh/brig}"
URUNC_REPO="${URUNC_REPO:-urunc-dev/urunc}"
URUNC_BRANCH="${URUNC_BRANCH:-feat/unchanged_containers}"
URUNC_GO_IMAGE="${URUNC_GO_IMAGE:-golang:1.26.4}"
URUNIT_REPO="${URUNIT_REPO:-NOFireAI/urunit}"
URUNIT_BRANCH="${URUNIT_BRANCH:-urunit_agent}"
# Static musl busybox for the initrd, per arch. Extracted from this image so we
# do not depend on busybox.net, which publishes 1.35.0 for x86_64 only.
BUSYBOX_IMAGE="${BUSYBOX_IMAGE:-busybox:1.36.1-musl}"
MONITORS_VERSION="${MONITORS_VERSION:-FC-v1.7.0_CLH-v50.0_S5-v0.12.1_VFS_-v1.13.0_QM-v10.1.1-9a44e}"
CONTAINERD_VERSION="${CONTAINERD_VERSION:-v2.3.5}"
RUNC_VERSION="${RUNC_VERSION:-v1.5.1}"
NERDCTL_VERSION="${NERDCTL_VERSION:-v2.3.5}"
CNI_VERSION="${CNI_VERSION:-v1.9.1}"
# The rootless path. nerdctl's own tarball carries containerd-rootless.sh and
# its setuptool; these two are the pieces it shells out to and no other
# component pulls in.
ROOTLESSKIT_VERSION="${ROOTLESSKIT_VERSION:-v3.2.0}"
SLIRP4NETNS_VERSION="${SLIRP4NETNS_VERSION:-v1.3.5}"
ORAS_VERSION="${ORAS_VERSION:-v1.3.4}"
COSIGN_VERSION="${COSIGN_VERSION:-v3.1.3}"
COSIGN_SHA_LINUX_AMD64="4629c757b7618056f8ddd7e2625ae9fdd94c0372a65049520bc7d9df9efc7f71"
COSIGN_SHA_LINUX_ARM64="c5d324e091826b0d7a78eb16fef316450b4eb9aaec045611c08ba06f5e73220a"
MONITORS="${MONITORS:-firecracker cloud-hypervisor solo5-hvt solo5-spt}"
ASSETS_REGISTRY="${ASSETS_REGISTRY:-ghcr.io}"
ASSETS_REPO="${ASSETS_REPO:-nofireai/hull-assets}"
ASSETS_VERSION="${ASSETS_VERSION:-0.1.4}"
# amd64 kernel: a bunny-built Cloud-Hypervisor kernel image (a plain OCI image
# carrying the kernel at /.boot/kernel), extracted with docker like busybox is.
# Empty falls back to the hull-assets oras pull. arm64 has no such image, so it
# always takes the hull-assets path below.
KERNEL_IMAGE_AMD64="${KERNEL_IMAGE_AMD64:-harbor.nbfc.io/nubificus/bunny/linux-kernel-cloud-hypervisor:latest}"
VIRTIOFSD="${VIRTIOFSD:-true}"

# Fixed install layout, baked into the config files the bundle carries. install.sh
# unpacks the tree to exactly these paths, so they are not configurable there.
# k3s-style: the whole install lives under one root (/var/lib/brig) as two
# sibling trees -- the immutable bundle under data/ and mutable state under
# agent/ -- with the runtime socket in /run and the launchers on the host PATH.
# The layout is fixed at build time and baked into every wrapper, config and
# unit below. Root installs own /var/lib/brig; a bundle built for one user
# points these at that user's own directories, which is what makes an install
# without root possible.
PREFIX="${PREFIX:-/var/lib/brig/data}"
DATA_DIR="${DATA_DIR:-/var/lib/brig/agent}"
RUN_DIR="${RUN_DIR:-/run/brig}"
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
# The snapshotter brig is told to use by default. devmapper stays configured in
# containerd (below), so a user switches to it at runtime with no reinstall by
# exporting CONTAINERD_SNAPSHOTTER=devmapper before running brig.
SNAPSHOTTER=overlayfs
POOL_FS=ext2
POOL_BASE_IMAGE_SIZE=10GB
VIRTIOFSD_OPTIONS="--cache always --sandbox none"
BRIG_GROUP=brig

GITHUB="https://github.com"
NAME="brig-standalone-$VERSION-linux-$ARCH"
[ "$ROOTLESS" = true ] && NAME="brig-standalone-$VERSION-rootless-linux-$ARCH"
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

# brig-ctl: drive the private stack by hand. Baked with the fixed layout.
write_brig_ctl() {
    cat > "$STAGE/bin/brig-ctl" <<CTLENV
#!/bin/sh
# brig-ctl: run ctr, nerdctl and friends against the private brig stack.
set -eu
PREFIX="$PREFIX"
SERVICE_NAME="$SERVICE_NAME"
BRIG_ENV="$ETC_DIR/brig-env.sh"
ROOTLESS=$ROOTLESS

# brig-env.sh is the one place that works out what the caller's euid means:
# root drives the system stack, anyone else drives a rootless containerd whose
# socket is inside the rootlesskit namespace and at a different path entirely.
# Source it rather than answer that question again here. Repeating it is what
# broke: a rootless install got handed the root socket path, and every nerdctl
# and ctr call through this script failed on a socket that does not exist.
if [ -f "\$BRIG_ENV" ]; then
    . "\$BRIG_ENV"
fi

# What the bundle was built with, used only where brig-env.sh left a gap.
CONTAINERD_ADDRESS="\${CONTAINERD_ADDRESS:-$CONTAINERD_SOCK}"
CONTAINERD_NAMESPACE="\${CONTAINERD_NAMESPACE:-$NAMESPACE}"
CONTAINERD_SNAPSHOTTER="\${CONTAINERD_SNAPSHOTTER:-$SNAPSHOTTER}"
NERDCTL_TOML="\${NERDCTL_TOML:-$ETC_DIR/nerdctl.toml}"
CNI_PATH="\${CNI_PATH:-$CNI_DIR}"
CTLENV
    cat >> "$STAGE/bin/brig-ctl" <<'CTLBODY'
# brig-ctl carries the prefix it was built for, so a copy run straight out of
# an unpacked tarball drives whatever install sits at that path instead of the
# tree it was run from -- which silently repoints a live rootless setup.
# brig-uninstall.sh guards the same way. $0 without a slash came off PATH, and
# an unresolvable one is left alone rather than guessed at.
self="$0"
case "$self" in
    */*) ;;
    *) self="$(command -v -- "$self" 2>/dev/null || echo "")" ;;
esac
if [ -n "$self" ]; then
    self_prefix="$(cd "$(dirname -- "$self")/.." 2>/dev/null && pwd || echo "")"
    if [ -n "$self_prefix" ] && [ "$self_prefix" != "$PREFIX" ]; then
        echo "brig-ctl: this copy was built for $PREFIX but runs from $self_prefix." >&2
        echo "brig-ctl: use $PREFIX/bin/brig-ctl, or install this tree first." >&2
        exit 1
    fi
fi

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
        # A rootless install's daemon is a systemd --user unit, so asking the
        # system manager about it answers "could not be found" on a stack that
        # is running perfectly well.
        if command -v systemctl >/dev/null 2>&1; then
            if [ "$(id -u)" -eq 0 ]; then
                systemctl --no-pager status "$SERVICE_NAME.service" || true
            else
                systemctl --user --no-pager status "$SERVICE_NAME.service" || true
            fi
        fi
        echo
        "$PREFIX/bin/ctr" --address "$CONTAINERD_ADDRESS" plugin ls 2>/dev/null \
            | awk 'NR==1 || /snapshotter/ || /urunc/' ;;
    rootless)
        if [ "$ROOTLESS" != true ]; then
            echo "brig-ctl: this bundle was built without rootless support." >&2
            echo "brig-ctl: install a brig-standalone-*-rootless-* bundle instead." >&2
            exit 1
        fi
        exec "$PREFIX/bin/brig-rootless-setup.sh" "$@" ;;
    uninstall)
        exec "$PREFIX/bin/brig-uninstall.sh" "$@" ;;
    help|--help|-h)
        cat <<USAGE
brig-ctl <command> [args]

  ctr [args]        ctr against the private containerd
  nerdctl [args]    nerdctl against the private containerd
  run <image>       nerdctl run with the urunc runtime and snapshotter
  rootless          set this user up to run brig without sudo (rootless bundles)
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
# brig-rootless-setup.sh: give one user a containerd of their own, so brig runs
# without sudo. The system stack is root's -- $RUN_DIR is root-owned, and even
# with the socket group-readable a rootless nerdctl enters a user namespace
# that drops supplementary groups, so group membership never arrives. This
# writes the per-user half and starts it.
write_brig_rootless_setup() {
    cat > "$STAGE/bin/brig-rootless-setup.sh" <<SETUPENV
#!/bin/sh
# brig-rootless-setup.sh -- set the invoking user up to run brig without sudo.
# Generated by build-bundle.sh. Baked with the fixed layout.
set -eu
PREFIX="$PREFIX"
NAMESPACE="$NAMESPACE"
SNAPSHOTTER="$SNAPSHOTTER"
CNI_DIR="$CNI_DIR"
ETC_DIR="$ETC_DIR"
SETUPENV
    cat >> "$STAGE/bin/brig-rootless-setup.sh" <<'SETUPBODY'

say() { printf '  %-10s %s\n' "$1" "$2"; }
fatal() { echo "brig-rootless-setup: ERROR: $*" >&2; exit 1; }
owned_by_me() { [ "$(stat -c %u "$1" 2>/dev/null || echo -1)" = "$(id -u)" ]; }

# A rootless brig runs the monitor as the container image's user, and an image
# whose user is not root maps into this user's subuid range -- uid 501 in the
# image is 100500 on the host. A grant naming this user cannot reach that, and
# setfacl takes one uid at a time, so the range cannot be named either.
# --open-devices trades the per-user ACL for mode 0666 on these devices, which
# is what lets such an image run. See docs/rootless.md.
OPEN_DEVICES=false
for arg in "$@"; do
    case "$arg" in
        --open-devices) OPEN_DEVICES=true ;;
        --help|-h) echo "usage: brig-rootless-setup.sh [--open-devices]"; exit 0 ;;
        *) fatal "unknown argument '$arg'" ;;
    esac
done

# Whether this user can reach the device the way the monitor will. Group
# membership is deliberately not consulted: it does not survive the user
# namespace, so the kvm group that makes /dev/kvm openable at a login shell
# reaches nothing inside.
device_granted() {
    if [ "$OPEN_DEVICES" = true ]; then
        [ "$(stat -c %a "/dev/$1" 2>/dev/null || echo 0)" = 666 ]
    else
        getfacl -p "/dev/$1" 2>/dev/null | grep -q "^user:$(id -un):rw"
    fi
}

[ "$(id -u)" -ne 0 ] || fatal "run this as the user who will run brig, not as root"
[ -d "$PREFIX" ] || fatal "no brig bundle at $PREFIX"
command -v systemctl >/dev/null 2>&1 || fatal "this needs a systemd user session"

XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
export XDG_RUNTIME_DIR
[ -d "$XDG_RUNTIME_DIR" ] || fatal "no $XDG_RUNTIME_DIR; log in as this user first"
CONF="${XDG_CONFIG_HOME:-$HOME/.config}/brig"
DATA="${XDG_DATA_HOME:-$HOME/.local/share}/brig"
UNIT="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user/brig-containerd.service"
ROOTLESSKIT="$PREFIX/bin/rootlesskit"
ROOTLESS_SH="$PREFIX/bin/containerd-rootless.sh"

for f in "$ROOTLESSKIT" "$ROOTLESS_SH" "$PREFIX/bin/slirp4netns" "$PREFIX/bin/containerd"; do
    [ -x "$f" ] || fatal "$f is missing from this bundle"
done
command -v newuidmap >/dev/null 2>&1 || fatal "newuidmap is missing (apt install uidmap)"
grep -q "^$(id -un):" /etc/subuid 2>/dev/null ||
    fatal "no subuid range for $(id -un); add one to /etc/subuid and /etc/subgid"

# Ubuntu 24.04 and later refuse unprivileged user namespaces unless the binary
# that asks has a profile. Without this rootlesskit dies on its own re-exec:
# "fork/exec /proc/self/exe: operation not permitted".
# The profile names the binary by path, so a bundle installed somewhere else
# needs its own. Test for a profile covering this path, not for a file: the
# wrong test passes on a host that has one for a different prefix, and
# rootlesskit then fails at its own re-exec with permission denied.
RK_PROFILE="/etc/apparmor.d/$(printf '%s' "${ROOTLESSKIT#/}" | tr / .)"
if [ "$(sysctl -n kernel.apparmor_restrict_unprivileged_userns 2>/dev/null || echo 0)" = "1" ] &&
   ! grep -rqsF "$ROOTLESSKIT" /etc/apparmor.d/ 2>/dev/null; then
    say "apparmor" "allowing user namespaces for $ROOTLESSKIT (needs sudo)"
    sudo tee "$RK_PROFILE" >/dev/null <<PROF
abi <abi/4.0>,
include <tunables/global>

$ROOTLESSKIT flags=(unconfined) {
  userns,
  include if exists <local/brig-rootlesskit>
}
PROF
    sudo apparmor_parser -r "$RK_PROFILE"
fi

# The VMM runs as this user inside that namespace, where supplementary groups
# are gone -- so membership of the kvm group never reaches cloud-hypervisor and
# KVM_CREATE_VM returns EPERM. Grant the user directly. The udev rule is what
# makes it stick: a bare setfacl is wiped by the next event on the device.
# /dev/vhost-vsock is the same story one layer along: qemu takes vsock from the
# kernel device, where cloud-hypervisor implements it in userspace, so which
# devices a run needs depends on the monitor urunc picks. /dev/vhost-net is not
# in this list: a guest boots and reaches the network without it, and it has no
# udev database entry here, so a rule for it would never fire anyway.
#
# Two preconditions decide whether that rule can do anything, and neither says
# so when it is unmet. udev runs RUN+= without a shell and discards the result,
# so on a host without setfacl the rule is written, reloaded, triggered, and
# grants nothing. And a device whose module is not loaded has no udev database
# entry, so there is nothing for a rule to match or a trigger to reach -- a
# /dev node left behind by an unloaded module looks present and is unreachable.
# Both end as KVM_CREATE_VM returning EPERM on the first sandbox, three layers
# from the cause.
if [ "$OPEN_DEVICES" != true ]; then
    if ! command -v setfacl >/dev/null 2>&1 || ! command -v getfacl >/dev/null 2>&1; then
        fatal "setfacl is missing (apt install acl); the device grant is made with it"
    fi
fi
for m in kvm vhost_vsock; do
    [ -d "/sys/module/$m" ] || sudo modprobe "$m" >/dev/null 2>&1 || true
done

# Loading it now only covers this boot. Nothing asks for vhost_vsock again on
# the next one: the module has no hardware to autoload from, and nothing can
# open /dev/vhost-vsock to trigger it because the node only exists once the
# module does. So the host is told to keep loading it. kvm is not in here --
# that one autoloads from the CPU, which is why /dev/kvm is present on a host
# that never asked for it. Only what this kernel really has is written: an
# entry for an absent module is a warning on every boot.
MODULES_FILE=/etc/modules-load.d/brig.conf
MODULES_WANT="# brig: the vsock device the monitor gives the guest. Written by
# brig-rootless-setup.sh; the matching udev rule grants access to it.
vhost_vsock"
if [ -d /sys/module/vhost_vsock ] &&
   [ "$(cat "$MODULES_FILE" 2>/dev/null)" != "$MODULES_WANT" ]; then
    say "modules" "asking this host to load vhost_vsock at boot (needs sudo)"
    printf '%s\n' "$MODULES_WANT" | sudo tee "$MODULES_FILE" >/dev/null
fi

RULE_FILE=/etc/udev/rules.d/99-brig-kvm.rules
# Both rules name the mode, so the file says the whole truth about these
# devices and applying it moves them either way. Leaving the mode out of the
# default rule is what let --open-devices be one-way: udev does not undo a mode
# a previous rule set, so a host switched back kept 0666 while the setup
# reported it had granted one user.
if [ "$OPEN_DEVICES" = true ]; then
    RULE_WANT=$(cat <<RULE
# brig: --open-devices. The monitor runs as the container image's user, and an
# image whose user is not root maps into a subuid that no per-user grant can
# name. Mode 0666 is what lets those images run; it is wider than the ACL the
# default rule writes, and it is the whole reason this is opt-in.
KERNEL=="kvm", SUBSYSTEM=="misc", MODE="0666"
KERNEL=="vhost-vsock", SUBSYSTEM=="misc", MODE="0666"
RULE
)
else
    RULE_WANT=$(cat <<RULE
# brig: a rootless brig runs the VMM as the invoking user, inside a user
# namespace that drops supplementary groups, so the kvm group never reaches
# the monitor. Grant the user directly -- narrower than mode 0666, and
# reapplied on every event for these devices, which a one-shot setfacl is not.
# An image whose user is not root needs --open-devices instead.
KERNEL=="kvm", SUBSYSTEM=="misc", MODE="0660", RUN+="/usr/bin/setfacl -m u:$(id -un):rw /dev/kvm"
KERNEL=="vhost-vsock", SUBSYSTEM=="misc", MODE="0660", RUN+="/usr/bin/setfacl -m u:$(id -un):rw /dev/vhost-vsock"
RULE
)
fi

HAVE_DEV=""
NEED_DEV=""
for d in kvm vhost-vsock; do
    [ -e "/dev/$d" ] || continue
    HAVE_DEV="$HAVE_DEV $d"
    device_granted "$d" || NEED_DEV="$NEED_DEV $d"
done
# A rule that no longer says what this run wants is applied even when the
# devices already look reachable -- that is the --open-devices switch-back,
# where they are reachable precisely because the old rule is still in force.
[ -f "$RULE_FILE" ] && [ "$(cat "$RULE_FILE" 2>/dev/null)" = "$RULE_WANT" ] || RULE_STALE=true
if [ -n "$NEED_DEV" ] || [ "${RULE_STALE:-false}" = true ]; then
    if [ "$OPEN_DEVICES" = true ]; then
        say "devices" "opening$HAVE_DEV to every user of this host (needs sudo)"
    else
        say "devices" "granting $(id -un) access to$HAVE_DEV (needs sudo)"
    fi
    printf '%s\n' "$RULE_WANT" | sudo tee "$RULE_FILE" >/dev/null
    sudo udevadm control --reload-rules
    for d in $HAVE_DEV; do sudo udevadm trigger --subsystem-match=misc --sysname-match="$d"; done
    sudo udevadm settle --timeout=10 >/dev/null 2>&1 || true
    # Read the result back rather than trusting the trigger: udev reports
    # nothing to whoever asked, so a rule that reached nothing is otherwise
    # discovered by a sandbox failing to boot.
    for d in $HAVE_DEV; do
        device_granted "$d" && continue
        fatal "the rule did not reach /dev/$d.
  'udevadm info /dev/$d' says whether udev knows the device at all: a node left
  behind by an unloaded module has no entry there, and no rule can match it."
    done
fi

mkdir -p "$CONF/cni/net.d" "$DATA/nerdctl" "$(dirname "$UNIT")"

# CRI and NRI serve kubelets, and NRI cannot bind its socket under /var/run as
# a user. brig drives containerd directly, so neither is wanted.
cat > "$CONF/containerd.toml" <<CFG
version = 3
disabled_plugins = ['io.containerd.cri.v1.runtime', 'io.containerd.cri.v1.images', 'io.containerd.grpc.v1.cri', 'io.containerd.nri.v1.nri']

[grpc]
  address = '/run/containerd/containerd.sock'

[debug]
  level = 'info'
CFG

# The bundle's nerdctl.toml with every root-owned path moved under $HOME. No
# address: brig-env.sh sets it, and it resolves inside the namespace.
cat > "$CONF/nerdctl.toml" <<CFG
debug = false
namespace = "$NAMESPACE"
snapshotter = "$SNAPSHOTTER"
cni_path = "$CNI_DIR"
cni_netconfpath = "$CONF/cni/net.d"
data_root = "$DATA/nerdctl"
cgroup_manager = "systemd"
hosts_dir = ["$ETC_DIR/certs.d"]
CFG

cp "$ETC_DIR"/cni/net.d/* "$CONF/cni/net.d/" 2>/dev/null || true

# containerd-rootless.sh execs the first containerd on PATH, so the bundle goes
# in front: daemon and shims then come from one build.
cat > "$UNIT" <<CFG
[Unit]
Description=brig containerd (rootless, %u)
Documentation=https://github.com/brig-sh/brig

[Service]
Type=notify
# rootlesskit forks before containerd starts, so readiness arrives from a pid
# systemd did not spawn. Without this the unit times out on a daemon that is
# already serving.
NotifyAccess=all
Delegate=yes
KillMode=mixed
Restart=always
RestartSec=5
TimeoutStartSec=60
Environment=PATH=$PREFIX/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
# urunc looks for /etc/urunc/config.toml, and writing that symlink needs root.
# The shim inherits this from containerd, so the bundle's own config is found
# without touching /etc.
Environment=URUNC_CONFIG_FILE=$ETC_DIR/urunc.toml
ExecStart=$ROOTLESS_SH --config $CONF/containerd.toml
LimitNOFILE=infinity
LimitNPROC=infinity
TasksMax=infinity

[Install]
WantedBy=default.target
CFG

# Until this existed, sudo was the only way to run brig here, and every run
# wrote root-owned state into the invoking user's home. Any one of these stops
# an unprivileged brig dead, and brig doctor reports none of them.
for d in "$HOME/brig" "$HOME/.brig" "$HOME/.sigstore" "$CONF"; do
    [ -e "$d" ] || continue
    owned_by_me "$d" && continue
    say "reclaim" "$d belongs to root from an earlier sudo run; taking it back"
    sudo chown -R "$(id -u):$(id -g)" "$d"
done

# Without lingering the daemon dies with the last login shell of this user,
# taking every running sandbox with it.
loginctl enable-linger "$(id -un)" >/dev/null 2>&1 || true

systemctl --user daemon-reload
systemctl --user reset-failed brig-containerd.service 2>/dev/null || true
systemctl --user enable brig-containerd.service
# restart, not "enable --now": a daemon already running keeps its old PATH and
# environment, so a re-run after the bundle moved would leave containerd
# resolving shims and monitors out of the previous prefix.
systemctl --user restart brig-containerd.service

i=0
while [ "$i" -lt 15 ]; do
    [ -S "$XDG_RUNTIME_DIR/containerd-rootless/api.sock" ] && break
    i=$((i + 1)); sleep 1
done

say "state" "$(systemctl --user is-active brig-containerd.service)"
say "config" "$CONF"
say "data" "$DATA/nerdctl"
printf '\nNow run brig without sudo:  brig doctor && brig run ubuntu ~/some/project\n'
SETUPBODY
    chmod 0755 "$STAGE/bin/brig-rootless-setup.sh"
}

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

[ -f "$STAMP" ] || fatal "no install stamp at $STAMP, refusing to remove anything"

# shellcheck disable=SC1090
. "$STAMP"

# A user install owns nothing outside $HOME, so it comes down without root.
if [ "${INSTALL_MODE:-system}" = "user" ]; then
    [ "$(id -u)" -ne 0 ] \
        || fatal "this install belongs to a user; run the uninstaller as that user"
else
    [ "$(id -u)" -eq 0 ] || fatal "run this as root"
fi

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

if [ "${INSTALL_MODE:-system}" = "user" ] && command -v systemctl >/dev/null 2>&1; then
    systemctl --user stop brig-containerd.service >/dev/null 2>&1 || true
    systemctl --user disable brig-containerd.service >/dev/null 2>&1 || true
    rm -f "${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user/brig-containerd.service"
    systemctl --user daemon-reload >/dev/null 2>&1 || true
    info "stopped and disabled the rootless containerd unit"
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

if [ "${INSTALL_MODE:-system}" != "user" ] \
    && [ -n "${BRIDGE_NAME:-}" ] && ip link show "$BRIDGE_NAME" >/dev/null 2>&1; then
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

# brig-rootless-setup.sh writes the per-user config and containerd's data root
# outside the bundle, so a user install is only fully gone once those are too.
if [ "${INSTALL_MODE:-system}" = "user" ] && [ "$KEEP_DATA" != "true" ]; then
    rm -rf "${XDG_CONFIG_HOME:-$HOME/.config}/brig"
    rm -rf "$(dirname "${PREFIX:?}")/nerdctl"
    info "removed the per-user brig config and containerd data root"
fi

# data/ and agent/ are siblings under one root; drop it once both are gone. This
# is a no-op while --keep-data preserved agent/, or if anything else lives there.
rmdir "$(dirname "${PREFIX:?}")" 2>/dev/null || true

info "done"
UNEOF
    chmod 0755 "$STAGE/bin/brig-uninstall.sh"
}

fetch() {
    curl -sfL --retry 3 --retry-delay 2 -o "$2" "$1" || fatal "failed to download $1"
}

# Verify against an upstream sums file when the project publishes one. A
# component without published checksums is not fatal; the whole tarball is
# checksummed and signed at release time either way.
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

    # urunc's build-container-initrd.sh would fetch busybox from busybox.net,
    # which only publishes 1.35.0 for x86_64 (the aarch64 URL 404s). Supply a
    # static busybox for the target arch from the official musl image and pass
    # it via BUSYBOX so the script never downloads.
    info "extracting a static busybox ($BUSYBOX_IMAGE, linux/$ARCH)"
    docker run --rm --platform "linux/$ARCH" "$BUSYBOX_IMAGE" cat /bin/busybox > "$DL/busybox" \
        || fatal "could not extract busybox from $BUSYBOX_IMAGE"
    [ -s "$DL/busybox" ] || fatal "extracted busybox is empty"
    chmod 0755 "$DL/busybox"

    info "building the brig container-initrd (urunit + urunit-agent + busybox)"
    docker run --rm --platform "linux/$ARCH" \
        -v "$src":/app -v "$usrc/dist/urunit_static":/urunit-static:ro -v "$DL/busybox":/busybox-in:ro \
        -w /app -e HOME=/tmp -e URUNIT=/urunit-static -e BUSYBOX=/busybox-in -e TARGET_ARCH="$ARCH_UNAME" "$URUNC_GO_IMAGE" \
        sh -c "apt-get update >/dev/null 2>&1 && apt-get install -y cpio >/dev/null 2>&1 && git config --global --add safe.directory /app && ./packaging/container-initrd/build-container-initrd.sh /app/dist/container-initrd" \
        || fatal "container-initrd build failed"
    [ -s "$src/dist/container-initrd" ] || fatal "no container-initrd produced"
    cp "$src/dist/container-initrd" "$DL/container-initrd"
    chmod 0644 "$DL/container-initrd"
    info "  built container-initrd ($(stat -c%s "$DL/container-initrd") bytes)"
fi

# ---- brig + brigd ------------------------------------------------------------
# brig is not built here: its own release is fetched and repackaged into the tree.
# "latest", for a local build, resolves to brig's newest release (prereleases
# included).
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

if [ "$ROOTLESS" = true ]; then
    rk_name="rootlesskit-$ARCH_UNAME.tar.gz"
    fetch "$GITHUB/rootless-containers/rootlesskit/releases/download/$ROOTLESSKIT_VERSION/$rk_name" "$DL/rootlesskit.tar.gz"
    verify "$DL/rootlesskit.tar.gz" \
        "$GITHUB/rootless-containers/rootlesskit/releases/download/$ROOTLESSKIT_VERSION/SHA256SUMS" "$rk_name"

    # slirp4netns ships a bare binary and no sums file; verify records the hash.
    s4_name="slirp4netns-$ARCH_UNAME"
    fetch "$GITHUB/rootless-containers/slirp4netns/releases/download/$SLIRP4NETNS_VERSION/$s4_name" "$DL/slirp4netns"
    verify "$DL/slirp4netns" "" "$s4_name"
fi

info "laying out the tree"
install -m 0755 "$DL/urunc" "$STAGE/bin/urunc"
install -m 0755 "$DL/containerd-shim-urunc-v2" "$STAGE/bin/containerd-shim-urunc-v2"
install -m 0755 "$DL/runc" "$STAGE/bin/runc"
tar -xzf "$DL/containerd.tar.gz" -C "$STAGE" bin/
if [ "$ROOTLESS" = true ]; then
    # nerdctl's tarball carries the two rootless launchers beside the binary, so
    # they arrive already covered by the checksum verified above.
    tar -xzf "$DL/nerdctl.tar.gz" -C "$STAGE/bin" \
        nerdctl containerd-rootless.sh containerd-rootless-setuptool.sh
    chmod 0755 "$STAGE/bin/containerd-rootless.sh" "$STAGE/bin/containerd-rootless-setuptool.sh"
else
    tar -xzf "$DL/nerdctl.tar.gz" -C "$STAGE/bin" nerdctl
fi
tar -xzf "$DL/cni.tgz" -C "$STAGE/libexec/cni"

if [ "$ROOTLESS" = true ]; then
    # rootlesskit and slirp4netns are what containerd-rootless.sh shells out to.
    # rootlessctl comes along for debugging a live namespace; the docker proxy
    # does not, since nothing here speaks to dockerd.
    tar -xzf "$DL/rootlesskit.tar.gz" -C "$STAGE/bin" rootlesskit rootlessctl
    chmod 0755 "$STAGE/bin/rootlesskit" "$STAGE/bin/rootlessctl"
    install -m 0755 "$DL/slirp4netns" "$STAGE/bin/slirp4netns"
fi

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
# The kernel on amd64 comes from KERNEL_IMAGE_AMD64 (a bunny-built OCI image with
# the kernel at /.boot/kernel), extracted with docker; on arm64 (or if that is
# unset) it comes from hull-assets, pulled with the oras we just bundled. The
# initrd never does: hull-assets' initrd carries hull's agent, so it is thrown
# away and the brig-built one above takes its place. A fresh bundle.json records
# the urunc the agent was built against, so the installer can check coherence.
ASSETS_URUNC_REF=""
KERNEL_SOURCE=""
KERNEL_FROM_ASSETS=false
if [ "$VARIANT" != "stock" ]; then
    case "$ARCH" in amd64) kernel=bzImage ;; arm64) kernel=Image ;; esac
    if [ "$ARCH" = "amd64" ] && [ -n "$KERNEL_IMAGE_AMD64" ]; then
        info "extracting the guest kernel from $KERNEL_IMAGE_AMD64 (linux/amd64)"
        # Pull explicitly with retries: the registry sometimes resets the
        # connection mid-handshake, and one reset should not kill the build.
        kpull=""
        katt=1
        while [ "$katt" -le 5 ]; do
            if docker pull --platform linux/amd64 "$KERNEL_IMAGE_AMD64" >/dev/null 2>&1; then
                kpull=ok; break
            fi
            info "  pull attempt $katt/5 failed, retrying in $((katt * 3))s"
            sleep $((katt * 3))
            katt=$((katt + 1))
        done
        [ "$kpull" = ok ] || fatal "could not pull $KERNEL_IMAGE_AMD64 after 5 attempts"
        # A scratch-style image (no shell), so copy the kernel out of a throwaway
        # container instead of exec'ing cat inside it. The dummy command is never
        # run; docker create just needs one, and docker cp works on a created
        # container.
        kcid="$(docker create --platform linux/amd64 "$KERNEL_IMAGE_AMD64" /nonexistent)" \
            || fatal "could not create a container from $KERNEL_IMAGE_AMD64"
        docker cp "$kcid:/.boot/kernel" "$STAGE/share/guest/$kernel"; kcp=$?
        docker rm "$kcid" >/dev/null 2>&1 || true
        [ "$kcp" -eq 0 ] || fatal "could not copy /.boot/kernel from $KERNEL_IMAGE_AMD64"
        KERNEL_SOURCE="$KERNEL_IMAGE_AMD64"
    else
        a_tag="$ASSETS_VERSION-linux-$ARCH"
        info "fetching the guest kernel $ASSETS_REPO:$a_tag with oras"
        ( cd "$STAGE/share/guest" \
          && "$STAGE/bin/oras" pull "$ASSETS_REGISTRY/$ASSETS_REPO:$a_tag" ) \
            || fatal "could not pull $ASSETS_REPO:$a_tag"
        KERNEL_SOURCE="$ASSETS_REGISTRY/$ASSETS_REPO:$a_tag"
        KERNEL_FROM_ASSETS=true
    fi
    [ -s "$STAGE/share/guest/$kernel" ] || fatal "no $kernel in the guest assets"

    # Replace hull's initrd with the brig-built one.
    [ -f "$DL/container-initrd" ] || fatal "the brig container-initrd was not built"
    cp "$DL/container-initrd" "$STAGE/share/guest/container-initrd"
    magic="$(od -An -tx1 -N2 "$STAGE/share/guest/container-initrd" | tr -d ' \n')"
    [ "$magic" = "1f8b" ] && fatal "container-initrd is gzipped; it must stay uncompressed"
    ASSETS_URUNC_REF="$URUNC_REF"
    cat > "$STAGE/share/guest/bundle.json" <<JSON
{"ref": "$URUNC_REF", "urunit": "$URUNIT_REF", "built_by": "brig-build-bundle"}
JSON
    info "  kernel from $KERNEL_SOURCE, initrd built for brig (urunc $URUNC_REF)"
fi

# ---- config files, systemd units, wrappers -----------------------------------
# Everything below is baked into the tree with the fixed /var/lib/brig layout, so the
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

# Both snapshotters are configured so either can serve images. brig selects one
# at runtime via CONTAINERD_SNAPSHOTTER (default overlayfs).
[[plugins.'io.containerd.transfer.v1.local'.unpack_config]]
  platform = 'linux/$ARCH'
  snapshotter = 'devmapper'

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
#
# Every value defers to one already in the environment, so a caller can point
# a single knob elsewhere without editing this file.
CFG
if [ "$ROOTLESS" = true ]; then
    cat >> "$STAGE/etc/brig-env.sh" <<CFG
# Root drives the system stack. A non-root user cannot: nerdctl decides
# rootless from its own euid, and a rootless nerdctl enters a user
# namespace that drops supplementary groups, so membership of the
# $BRIG_GROUP group buys nothing in there. A non-root user gets a containerd
# of their own instead -- see brig-rootless-setup.sh -- and every path below
# moves under their home to match.
if [ "\$(id -u)" -eq 0 ]; then
    export CONTAINERD_ADDRESS="\${CONTAINERD_ADDRESS:-unix://$CONTAINERD_SOCK}"
    export NERDCTL_TOML="\${NERDCTL_TOML:-$ETC_DIR/nerdctl.toml}"
else
    # The address is the one inside the rootlesskit namespace nerdctl re-enters,
    # not a path on the host: containerd-rootless.sh binds the user's runtime
    # directory onto /run/containerd in there.
    export CONTAINERD_ADDRESS="\${CONTAINERD_ADDRESS:-unix:///run/containerd/containerd.sock}"
    export NERDCTL_TOML="\${NERDCTL_TOML:-\${XDG_CONFIG_HOME:-\$HOME/.config}/brig/nerdctl.toml}"
fi
CFG
else
    cat >> "$STAGE/etc/brig-env.sh" <<CFG
# This bundle carries no rootless path, so there is one layout: the system
# stack, which only root can drive.
export CONTAINERD_ADDRESS="\${CONTAINERD_ADDRESS:-unix://$CONTAINERD_SOCK}"
export NERDCTL_TOML="\${NERDCTL_TOML:-$ETC_DIR/nerdctl.toml}"
CFG
fi
cat >> "$STAGE/etc/brig-env.sh" <<CFG
export CONTAINERD_NAMESPACE="\${CONTAINERD_NAMESPACE:-$NAMESPACE}"
# brig's default snapshotter; export CONTAINERD_SNAPSHOTTER=devmapper to switch.
# devmapper needs the system thin pool, so a rootless stack stays on overlayfs.
export CONTAINERD_SNAPSHOTTER="\${CONTAINERD_SNAPSHOTTER:-$SNAPSHOTTER}"
export CNI_PATH="\${CNI_PATH:-$CNI_DIR}"
export BRIG_RUNTIME="\${BRIG_RUNTIME:-nerdctl}"
export BRIG_RUNTIME_BIN="\${BRIG_RUNTIME_BIN:-$BIN_DIR/nerdctl}"
export BRIG_BOOT_ASSETS="\${BRIG_BOOT_ASSETS:-$SHARE_DIR/guest}"
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
Wants=$POOL_SERVICE_NAME.service
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
[ "$ROOTLESS" = true ] && write_brig_rootless_setup
write_uninstaller

info "writing pins.env"
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
PREFIX=$PREFIX
DATA_DIR=$DATA_DIR
RUN_DIR=$RUN_DIR
ROOTLESS=$ROOTLESS
ROOTLESSKIT_VERSION=$([ "$ROOTLESS" = true ] && echo "$ROOTLESSKIT_VERSION" || echo "")
SLIRP4NETNS_VERSION=$([ "$ROOTLESS" = true ] && echo "$SLIRP4NETNS_VERSION" || echo "")
MONITORS_VERSION=$MONITORS_VERSION
MONITORS_INSTALLED="$MONITORS"
VIRTIOFSD_INSTALLED=$VIRTIOFSD
CONTAINERD_VERSION=$CONTAINERD_VERSION
RUNC_VERSION=$RUNC_VERSION
NERDCTL_VERSION=$NERDCTL_VERSION
CNI_VERSION=$CNI_VERSION
ORAS_VERSION=$ORAS_VERSION
COSIGN_VERSION=$COSIGN_VERSION
KERNEL_SOURCE=$KERNEL_SOURCE
ASSETS_REPO=$([ "$KERNEL_FROM_ASSETS" = true ] && echo "$ASSETS_REPO" || echo "")
ASSETS_VERSION=$([ "$KERNEL_FROM_ASSETS" = true ] && echo "$ASSETS_VERSION" || echo "")
ASSETS_URUNC_REF=$ASSETS_URUNC_REF
PINS

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

info "done"
info "  $OUT/$NAME.tar.gz  ($(du -h "$OUT/$NAME.tar.gz" | awk '{print $1}'))"
info "  sha256 $(sha256sum "$OUT/$NAME.tar.gz" | awk '{print $1}')"
