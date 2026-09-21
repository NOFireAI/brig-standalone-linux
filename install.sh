#!/bin/sh
#
# Copyright (c) 2026, NOFire AI
# SPDX-License-Identifier: Apache-2.0
#
# brig installer for Linux.
#
# Fetches one release tarball -- built and published by THIS repository, which
# bundles everything: brig itself (from brig-sh/brig's release), the urunc runtime,
# the monitors, the boot assets, and every config file, systemd unit and wrapper,
# laid out as a /var/lib/brig/data tree. install.sh unpacks it and wires it into the host:
# a private containerd, a device-mapper pool, a unix group for the socket, and
# (optionally) a systemd service. It builds nothing and fetches nothing else.
#
#   curl -fsSL https://raw.githubusercontent.com/NOFireAI/brig-standalone-linux/main/install.sh | sh -
#
# Two output modes, both with a progress bar:
#   quiet    (default) one progress bar and the final summary
#   verbose  (INSTALL_BRIG_VERBOSE=true) a line per stage as well
#
# Run install.sh --help for the environment variables it honors.

set -eu

# ---------------------------------------------------------------- pins

# The one artifact this installer fetches: a per-arch tarball released by this
# repository, which runs release.yml and bundles the whole brig runtime.
# "latest" resolves to its newest release.
DEFAULT_RELEASE_REPO="NOFireAI/brig-standalone-linux"
DEFAULT_RELEASE_VERSION="latest"

GITHUB="https://github.com"

# The layout the tarball is built with, and the one a root install uses.
# k3s-style: one root (/var/lib/brig) with two sibling trees -- the immutable
# bundle under data/ and mutable state under agent/ -- the socket in /run, and
# the launchers on the host PATH.
BUILD_ROOT_DIR="/var/lib/brig"
BUILD_PREFIX="$BUILD_ROOT_DIR/data"
BUILD_DATA_DIR="$BUILD_ROOT_DIR/agent"
BUILD_RUN_DIR="/run/brig"

# Root installs into the host layout, a normal user into their home. --system
# and --user force it, for a root user who wants a home install or the reverse.
if [ "$(id -u)" -eq 0 ]; then
    INSTALL_MODE="${INSTALL_BRIG_MODE:-system}"
else
    INSTALL_MODE="${INSTALL_BRIG_MODE:-user}"
fi

# The tarball's configs carry the build layout as literal paths, so a user
# install rewrites them once the tree is down: see retarget_tree.
set_layout() {
    if [ "$INSTALL_MODE" = "user" ]; then
        ROOT_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/brig"
        RUN_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/brig"
        LAUNCH_DIR="$HOME/.local/bin"
    else
        ROOT_DIR="$BUILD_ROOT_DIR"
        RUN_DIR="$BUILD_RUN_DIR"
        LAUNCH_DIR="/usr/local/bin"
    fi
    PREFIX="$ROOT_DIR/data"     # immutable binaries, config, boot assets
    DATA_DIR="$ROOT_DIR/agent"  # mutable state: containerd store, snapshots, pool

    BIN_DIR="$PREFIX/bin"
    ETC_DIR="$PREFIX/etc"
    CONTAINERD_SOCK="$RUN_DIR/containerd.sock"
    STAMP="$PREFIX/.install-stamp"
    PINS="$PREFIX/pins.env"
}

SERVICE_NAME="brig-containerd"
POOL_SERVICE_NAME="brig-devpool"
POOL_NAME="brig-devpool"
NAMESPACE="brig"

# Keyless cosign records the workflow that built an artifact. checksums.txt is
# signed by this repository's release workflow, so verification is bound to it.
SIG_IDENTITY_REGEXP="${INSTALL_BRIG_SIG_IDENTITY:-^https://github.com/NOFireAI/brig-standalone-linux/.github/workflows/release.yml@refs/tags/}"
SIG_OIDC_ISSUER="${INSTALL_BRIG_SIG_ISSUER:-https://token.actions.githubusercontent.com}"

# ---------------------------------------------------------------- logging

# say() prints a stage detail, only in verbose mode. warn()/fatal() always print,
# on a fresh line so they never land on top of the progress bar.
VERBOSE=false
BAR_ACTIVE=false

_break_bar() { if [ "$BAR_ACTIVE" = "true" ]; then printf '\n' >&2; BAR_ACTIVE=false; fi; }
say()   { if [ "$VERBOSE" = "true" ]; then _break_bar; echo "    $*" >&2; fi; }
warn()  { _break_bar; echo "[brig-install] WARNING: $*" >&2; }
fatal() { _break_bar; echo "[brig-install] ERROR: $*" >&2; exit 1; }

STEP=0
TOTAL=9
BAR_WIDTH=28

# progress <label>: advance the bar one stage. In quiet mode it redraws a single
# in-place bar; in verbose mode it prints a numbered stage line instead.
progress() {
    STEP=$((STEP + 1))
    if [ "$VERBOSE" = "true" ]; then
        _break_bar
        echo "[brig-install] ($STEP/$TOTAL) $1" >&2
        return 0
    fi
    pct=$(( STEP * 100 / TOTAL ))
    filled=$(( STEP * BAR_WIDTH / TOTAL ))
    bar=""; i=0
    while [ "$i" -lt "$BAR_WIDTH" ]; do
        if [ "$i" -lt "$filled" ]; then bar="$bar#"; else bar="$bar."; fi
        i=$((i + 1))
    done
    printf '\r[brig-install] [%s] %3d%%  %-22.22s' "$bar" "$pct" "$1" >&2
    BAR_ACTIVE=true
    if [ "$STEP" -ge "$TOTAL" ]; then _break_bar; fi
    # Never let a false test above become progress's return status: under `set -e`
    # a non-zero return from this standalone call would abort the install.
    return 0
}

usage() {
    cat >&2 <<'USAGE'
Usage: install.sh [--help] [--verbose] [--quiet] [--system|--user]

Fetches the brig release tarball and installs it. As root the tree goes to
/var/lib/brig/data with state in /var/lib/brig and the socket in /run/brig. As a
normal user it goes to ~/.local/share/brig instead and nothing outside $HOME is
touched, which needs the host prepared once: see docs/rootless.md. It builds
nothing.

  INSTALL_BRIG_RELEASE_REPO   repo that publishes the tarball
                              (default: NOFireAI/brig-standalone-linux)
  INSTALL_BRIG_RELEASE_VERSION  release tag, or "latest" (default: latest)
  INSTALL_BRIG_BUNDLE         a local tarball (or URL) to install instead of
                              fetching the release
  INSTALL_BRIG_MODE           system | user (default: user unless root)
  INSTALL_BRIG_GROUP          unix group granted the socket (default: brig)
  INSTALL_BRIG_USER           user added to that group (default: $SUDO_USER)
  INSTALL_BRIG_SYSTEMD        ask | yes | no. Install the systemd service?
                              (default: ask; non-interactive falls back to yes)
  INSTALL_BRIG_VERBOSE        true for a line per stage (default: false, quiet)
  INSTALL_BRIG_SKIP_START     true to lay the tree down without starting it
  INSTALL_BRIG_SKIP_SIGCHECK  true to install a remote tarball unverified
  INSTALL_BRIG_FORCE          true to take over a /var/lib/brig/data we did not create
  INSTALL_BRIG_SNAPSHOTTER    set to overlayfs to skip devmapper pool setup
                              (brig defaults to overlayfs; export
                              CONTAINERD_SNAPSHOTTER=devmapper to switch at runtime)
  INSTALL_BRIG_POOL_SIZE      thin pool data size (default: 100G, sparse)
  INSTALL_BRIG_POOL_PREALLOC  true to fallocate the pool backing files
  INSTALL_BRIG_DEBUG          true for set -x
USAGE
}

# ---------------------------------------------------------------- environment

setup_env() {
    set_layout

    RELEASE_REPO="${INSTALL_BRIG_RELEASE_REPO:-$DEFAULT_RELEASE_REPO}"
    RELEASE_VERSION="${INSTALL_BRIG_RELEASE_VERSION:-$DEFAULT_RELEASE_VERSION}"
    RELEASE_RESOLVED=""
    BUNDLE="${INSTALL_BRIG_BUNDLE:-}"

    BRIG_GROUP="${INSTALL_BRIG_GROUP:-brig}"
    BRIG_USER="${INSTALL_BRIG_USER:-${SUDO_USER:-}}"
    SYSTEMD_CHOICE="${INSTALL_BRIG_SYSTEMD:-ask}"

    case "${INSTALL_BRIG_VERBOSE:-false}" in true|1) VERBOSE=true ;; esac
    SKIP_START="${INSTALL_BRIG_SKIP_START:-false}"
    SKIP_SIGCHECK="${INSTALL_BRIG_SKIP_SIGCHECK:-false}"
    FORCE="${INSTALL_BRIG_FORCE:-false}"

    # brig uses overlayfs by default; a user switches at runtime by exporting
    # CONTAINERD_SNAPSHOTTER=devmapper. devmapper is still configured in
    # containerd, and its thin pool is provisioned when the kernel supports it
    # (unless the user opts out with INSTALL_BRIG_SNAPSHOTTER=overlayfs).
    SNAPSHOTTER=overlayfs
    WANT_DEVMAPPER=true
    [ "${INSTALL_BRIG_SNAPSHOTTER:-}" = "overlayfs" ] && WANT_DEVMAPPER=false
    # A thin pool needs losetup and dmsetup, which a user namespace does not
    # get. A user install is overlayfs only.
    [ "$INSTALL_MODE" = "user" ] && WANT_DEVMAPPER=false
    POOL_SIZE="${INSTALL_BRIG_POOL_SIZE:-100G}"
    POOL_META_SIZE="${INSTALL_BRIG_POOL_META_SIZE:-10G}"
    POOL_PREALLOC="${INSTALL_BRIG_POOL_PREALLOC:-false}"

    case "${INSTALL_BRIG_DEBUG:-false}" in true|1) set -x ;; esac

    TMP_DIR="$(mktemp -d -t brig-install.XXXXXX)"
    trap cleanup_tmp EXIT INT TERM
}

cleanup_tmp() {
    [ -n "${TMP_DIR:-}" ] && [ -d "$TMP_DIR" ] && rm -rf "$TMP_DIR"
    return 0
}

# ---------------------------------------------------------------- preflight

verify_system() {
    if [ "$INSTALL_MODE" = "system" ]; then
        [ "$(id -u)" -eq 0 ] \
            || fatal "a system install must run as root. Run with --user to install into \$HOME"
    elif [ "$(id -u)" -eq 0 ]; then
        fatal "a user install must not run as root: the tree would land root-owned in a home"
    fi

    case "$(uname -s)" in
        Linux) ;;
        *) fatal "brig's runtime installs on Linux only, this is $(uname -s)" ;;
    esac

    case "$(uname -m)" in
        x86_64|amd64) ARCH=amd64 ;;
        aarch64|arm64) ARCH=arm64 ;;
        *) fatal "unsupported architecture $(uname -m)" ;;
    esac

    for tool in curl tar sha256sum sed awk truncate; do
        command -v "$tool" >/dev/null 2>&1 || fatal "'$tool' is required and was not found"
    done

    command -v iptables >/dev/null 2>&1 || warn "iptables not found, urunc cannot set up NAT for guests"

    # Probe for devmapper thin-pool support so the pool can be provisioned (and
    # devmapper made switchable at runtime). Missing tools or a kernel without
    # CONFIG_DM_THIN_PROVISIONING is not an error: devmapper is simply skipped
    # and brig runs on overlayfs.
    DM_AVAILABLE=false
    if [ "$WANT_DEVMAPPER" = "true" ] \
        && command -v dmsetup >/dev/null 2>&1 \
        && command -v losetup >/dev/null 2>&1 \
        && command -v blockdev >/dev/null 2>&1; then
        modprobe dm_thin_pool 2>/dev/null || true
        dmsetup targets 2>/dev/null | grep -q '^thin-pool' && DM_AVAILABLE=true
    fi

    HAVE_SYSTEMD=true
    command -v systemctl >/dev/null 2>&1 || HAVE_SYSTEMD=false
}

# What a user install cannot do for itself, in two classes. Nothing here can
# fix the first, so the install stops; brig-rootless-setup.sh asks sudo for the
# second, so those are reported and left to it. Each is a confusing failure
# somewhere else if it goes unchecked: rootlesskit dies on its own re-exec
# without the AppArmor profile, KVM_CREATE_VM returns EPERM without access to
# the device, and newuidmap is setuid-root.
verify_rootless_prereqs() {
    miss=""
    once=""
    [ -d "${XDG_RUNTIME_DIR:-/run/user/$(id -u)}" ] \
        || miss="$miss\n  no ${XDG_RUNTIME_DIR:-/run/user/$(id -u)}: log in as this user first"
    [ "$HAVE_SYSTEMD" = "true" ] \
        || miss="$miss\n  no systemctl: a user install needs a systemd user session"
    command -v newuidmap >/dev/null 2>&1 \
        || miss="$miss\n  newuidmap is missing:  sudo apt install uidmap"
    command -v setfacl >/dev/null 2>&1 \
        || miss="$miss\n  setfacl is missing:  sudo apt install acl"
    grep -q "^$(id -un):" /etc/subuid 2>/dev/null && grep -q "^$(id -un):" /etc/subgid 2>/dev/null \
        || miss="$miss\n  no subuid range:  sudo usermod --add-subuids 100000-165535 --add-subgids 100000-165535 $(id -un)"

    # Readable here is the wrong question. The monitor runs inside a user
    # namespace where this user's supplementary groups are gone, so the kvm
    # group that makes /dev/kvm openable at this prompt reaches nothing in
    # there -- testing r/w passes on exactly the hosts that then fail to boot a
    # sandbox. Look for what the setup actually grants: this user by name, or a
    # mode that covers everyone.
    for d in kvm vhost-vsock; do
        [ -e "/dev/$d" ] || continue
        getfacl -p "/dev/$d" 2>/dev/null | grep -q "^user:$(id -un):rw" && continue
        [ "$(stat -c %a "/dev/$d" 2>/dev/null || echo 0)" = 666 ] && continue
        once="$once\n  no access to /dev/$d from inside the user namespace"
    done

    # The profile names the binary by path, so the one a /var/lib install left
    # behind does not cover a tree in $HOME.
    if [ "$(sysctl -n kernel.apparmor_restrict_unprivileged_userns 2>/dev/null || echo 0)" = "1" ] \
        && ! grep -rqsF "$BIN_DIR/rootlesskit" /etc/apparmor.d/ 2>/dev/null; then
        once="$once\n  no AppArmor profile for $BIN_DIR/rootlesskit"
    fi

    if [ -n "$miss" ]; then
        # shellcheck disable=SC2059
        printf "[brig-install] ERROR: this host is not set up for a rootless brig:$miss\n\n  See docs/rootless.md.\n" >&2
        exit 1
    fi
    if [ -n "$once" ]; then
        # Counted, not assumed: this said "two" whatever it had found, which
        # reads as a second thing the reader has missed.
        n=$(printf '%b' "$once" | grep -c '^  ')
        if [ "$n" = 1 ]; then what="one host setting is"; else what="$n host settings are"; fi
        # shellcheck disable=SC2059
        printf "[brig-install] WARNING: $what still missing:$once\n" >&2
        warn "brig-rootless-setup.sh will ask for sudo once to set those up"
    fi
}

# An existing prefix is only ours if we stamped it.
verify_root_dir() {
    PRIOR_POOL_CREATED=""
    PRIOR_ETC_CREATED=""
    PRIOR_ETC_BACKUP=""
    PRIOR_GROUP_CREATED=""
    [ -e "$PREFIX" ] || return 0
    if [ -f "$STAMP" ]; then
        PRIOR_POOL_CREATED="$(awk -F= '$1 == "POOL_CREATED" {print $2}' "$STAMP")"
        PRIOR_ETC_CREATED="$(awk -F= '$1 == "ETC_SYMLINK_CREATED" {print $2}' "$STAMP")"
        PRIOR_ETC_BACKUP="$(awk -F= '$1 == "ETC_SYMLINK_BACKUP" {print $2}' "$STAMP")"
        PRIOR_GROUP_CREATED="$(awk -F= '$1 == "GROUP_CREATED" {print $2}' "$STAMP")"
        say "found an existing brig install at $PREFIX, upgrading in place"
        return 0
    fi
    if [ "$FORCE" = "true" ]; then
        warn "$PREFIX exists and was not created by this installer, taking it over"
        return 0
    fi
    fatal "$PREFIX exists and has no install stamp.
    Set INSTALL_BRIG_FORCE=true to take it over."
}

# Ask whether to install the systemd service, before the progress bar starts so
# the prompt is not drawn over. In a non-interactive run (no controlling tty)
# there is no one to ask, so default to yes; INSTALL_BRIG_SYSTEMD forces it.
ask_systemd() {
    INSTALL_SYSTEMD=false
    # The per-user daemon is a systemd --user unit, written by
    # brig-rootless-setup.sh, so there is nothing to ask about.
    [ "$INSTALL_MODE" = "user" ] && return 0
    if [ "$HAVE_SYSTEMD" != "true" ]; then
        [ "$SYSTEMD_CHOICE" = "yes" ] && warn "systemd not found, cannot install the service"
        return 0
    fi
    case "$SYSTEMD_CHOICE" in
        yes) INSTALL_SYSTEMD=true; return 0 ;;
        no)  INSTALL_SYSTEMD=false; return 0 ;;
    esac
    # ask. Opening it is the test, because /dev/tty passes -r with no
    # controlling terminal and then fails to open, which printed the prompt and
    # an error before defaulting anyway. The open goes in a subshell: dash
    # treats a redirection failure on a compound command as fatal, even as an
    # if condition, and takes the whole script with it.
    if (: </dev/tty) 2>/dev/null; then
        printf '[brig-install] Install and enable the %s systemd service now? [Y/n] ' "$SERVICE_NAME" >&2
        read -r ans </dev/tty || ans=y
        case "$ans" in n|N|no|NO) INSTALL_SYSTEMD=false ;; *) INSTALL_SYSTEMD=true ;; esac
    else
        INSTALL_SYSTEMD=true
        say "no tty to prompt on, installing the systemd service (set INSTALL_BRIG_SYSTEMD=no to skip)"
    fi
}

# ---------------------------------------------------------------- fetch

# curl with a real download progress bar in both modes: it is the one long step.
fetch_bar() {
    curl -fL --retry 3 --retry-delay 2 --progress-bar -o "$2" "$1" \
        || fatal "download failed: $1"
}
fetch_quiet() {
    curl -sfL --retry 2 -o "$2" "$1"
}

resolve_release_version() {
    [ -n "$RELEASE_RESOLVED" ] && return 0
    if [ "$RELEASE_VERSION" = "latest" ]; then
        RELEASE_RESOLVED="$(curl -sfL "https://api.github.com/repos/$RELEASE_REPO/releases" \
            | sed -n 's/.*"tag_name": *"\([^"]*\)".*/\1/p' | head -1)"
        [ -n "$RELEASE_RESOLVED" ] \
            || fatal "could not find a release in $RELEASE_REPO. Set INSTALL_BRIG_RELEASE_VERSION."
    else
        RELEASE_RESOLVED="$RELEASE_VERSION"
    fi
}

# Put the release tarball in $TMP_DIR/bundle.tar.gz, from a local path, a URL, or
# the release. A remote tarball is verified against the release's cosign-signed
# checksums.txt; a local path is taken as given (the airgapped case).
fetch_tarball() {
    TARBALL="$TMP_DIR/bundle.tar.gz"
    case "$BUNDLE" in
        "")
            resolve_release_version
            ARCHIVE="brig-standalone-$RELEASE_RESOLVED-linux-$ARCH.tar.gz"
            base="$GITHUB/$RELEASE_REPO/releases/download/$RELEASE_RESOLVED"
            say "fetching $ARCHIVE from $RELEASE_REPO ($RELEASE_RESOLVED)"
            _break_bar
            fetch_bar "$base/$ARCHIVE" "$TARBALL"
            verify_tarball "$base" "$ARCHIVE" "$TARBALL"
            ;;
        http://*|https://*)
            ARCHIVE="${BUNDLE##*/}"
            say "fetching $BUNDLE"
            _break_bar
            fetch_bar "$BUNDLE" "$TARBALL"
            verify_tarball "${BUNDLE%/*}" "$ARCHIVE" "$TARBALL"
            ;;
        *)
            [ -f "$BUNDLE" ] || fatal "tarball '$BUNDLE' not found"
            say "installing from the local tarball $BUNDLE"
            cp "$BUNDLE" "$TARBALL"
            ;;
    esac
}

# checksums.txt covers every asset and carries the one signature.
verify_tarball() {
    base="$1"; name="$2"; file="$3"
    if [ "$SKIP_SIGCHECK" = "true" ]; then
        warn "INSTALL_BRIG_SKIP_SIGCHECK is set, not verifying the tarball"
        return 0
    fi
    fetch_quiet "$base/checksums.txt" "$TMP_DIR/checksums.txt" \
        || { warn "no checksums.txt next to the tarball, cannot verify"; return 0; }

    if command -v cosign >/dev/null 2>&1 \
       && fetch_quiet "$base/checksums.txt.pem" "$TMP_DIR/checksums.txt.pem" \
       && fetch_quiet "$base/checksums.txt.sig" "$TMP_DIR/checksums.txt.sig"; then
        if cosign verify-blob \
            --certificate "$TMP_DIR/checksums.txt.pem" \
            --signature "$TMP_DIR/checksums.txt.sig" \
            --certificate-identity-regexp "$SIG_IDENTITY_REGEXP" \
            --certificate-oidc-issuer "$SIG_OIDC_ISSUER" \
            "$TMP_DIR/checksums.txt" >/dev/null 2>&1; then
            say "checksums.txt signature verified"
        else
            warn "could not verify the checksums.txt signature, checking the hash only"
        fi
    else
        say "cosign not present, checking the hash only"
    fi

    expected="$(awk -v n="$name" '$2 == n || $2 == "*"n {print $1; exit}' "$TMP_DIR/checksums.txt")"
    [ -n "$expected" ] || fatal "$name is not listed in checksums.txt"
    actual="$(sha256sum "$file" | awk '{print $1}')"
    [ "$expected" = "$actual" ] || fatal "checksum mismatch for $name"
    say "verified $name"
}

# ---------------------------------------------------------------- unpack

# Unpack the tarball and move its tree into $PREFIX atomically: stage into
# $PREFIX/<part>.new and rename, so a failed run leaves the old install intact.
# State dirs and the socket dir are created here too.
unpack_tarball() {
    mkdir -p "$TMP_DIR/x"
    tar -xzf "$TARBALL" -C "$TMP_DIR/x" || fatal "could not unpack the tarball"
    root="$(find "$TMP_DIR/x" -mindepth 1 -maxdepth 1 -type d | head -1)"
    { [ -n "$root" ] && [ -d "$root/bin" ]; } || fatal "the tarball does not look like a brig tree"
    [ -f "$root/pins.env" ] || fatal "the tarball has no pins.env"

    a_arch="$(awk -F= '$1 == "ARCH" {print $2}' "$root/pins.env")"
    [ -z "$a_arch" ] || [ "$a_arch" = "$ARCH" ] \
        || fatal "the tarball is for linux/$a_arch, this host is linux/$ARCH"

    mkdir -p "$PREFIX"
    for d in bin libexec etc share; do
        [ -d "$root/$d" ] || continue
        rm -rf "$PREFIX/$d.new"
        mv "$root/$d" "$PREFIX/$d.new"
        [ -d "$PREFIX/$d" ] && rm -rf "$PREFIX/$d.old" && mv "$PREFIX/$d" "$PREFIX/$d.old"
        mv "$PREFIX/$d.new" "$PREFIX/$d"
        rm -rf "$PREFIX/$d.old"
    done
    [ -f "$root/pins.env" ] && cp "$root/pins.env" "$PREFIX/pins.env"
    chmod 0755 "$PREFIX"

    mkdir -p "$DATA_DIR/containerd" "$DATA_DIR/nerdctl" "$DATA_DIR/log" "$RUN_DIR"
    retarget_tree
    # No snapshotter retargeting: the tarball's configs default brig to overlayfs
    # and keep devmapper configured in containerd, so CONTAINERD_SNAPSHOTTER=devmapper
    # switches at runtime without rewriting anything.
}

# Move the tree's idea of where it lives. The generated wrappers, configs and
# units carry the build layout as literal paths; no binary does. The grep at the
# end is what keeps that true: a tenth file added upstream fails the install
# here instead of half-working on the host.
retarget_tree() {
    b_prefix="$(awk -F= '$1 == "PREFIX" {print $2}' "$PINS" 2>/dev/null)"
    b_data="$(awk -F= '$1 == "DATA_DIR" {print $2}' "$PINS" 2>/dev/null)"
    b_run="$(awk -F= '$1 == "RUN_DIR" {print $2}' "$PINS" 2>/dev/null)"
    # Bundles built before pins.env recorded the layout used the default one.
    [ -n "$b_prefix" ] || b_prefix="$BUILD_PREFIX"
    [ -n "$b_data" ] || b_data="$BUILD_DATA_DIR"
    [ -n "$b_run" ] || b_run="$BUILD_RUN_DIR"

    if [ "$b_prefix" = "$PREFIX" ] && [ "$b_data" = "$DATA_DIR" ] && [ "$b_run" = "$RUN_DIR" ]; then
        return 0
    fi

    grep -rIl -e "$b_prefix" -e "$b_data" -e "$b_run" "$BIN_DIR" "$ETC_DIR" 2>/dev/null \
        | while read -r f; do
            sed -i "s|$b_data|$DATA_DIR|g; s|$b_prefix|$PREFIX|g; s|$b_run|$RUN_DIR|g" "$f" \
                || fatal "could not retarget $f"
            say "retargeted ${f#"$PREFIX/"}"
        done

    left="$(grep -rIl -e "$b_prefix" -e "$b_data" -e "$b_run" "$BIN_DIR" "$ETC_DIR" 2>/dev/null || true)"
    [ -z "$left" ] || fatal "retargeting left the build layout behind in:
    $left"
    say "retargeted the tree from $b_prefix to $PREFIX"
}

# ---------------------------------------------------------------- group

# The brig group owns the private containerd socket, so a non-root user can drive
# the stack. The systemd unit chgrps the socket to this group by name.
setup_group() {
    # Nothing owns the socket but this user: it lives in their runtime dir.
    if [ "$INSTALL_MODE" = "user" ]; then
        say "user install, not creating a group"
        return 0
    fi

    GROUP_CREATED=false
    command -v getent >/dev/null 2>&1 || { warn "getent not found, cannot manage the $BRIG_GROUP group"; return 0; }
    if getent group "$BRIG_GROUP" >/dev/null 2>&1; then
        GROUP_CREATED="${PRIOR_GROUP_CREATED:-false}"
    elif command -v groupadd >/dev/null 2>&1; then
        if groupadd --system "$BRIG_GROUP" 2>/dev/null || groupadd "$BRIG_GROUP" 2>/dev/null; then
            GROUP_CREATED=true
            say "created the $BRIG_GROUP group"
        else
            warn "could not create the $BRIG_GROUP group"
            return 0
        fi
    else
        warn "groupadd not found, skipping the $BRIG_GROUP group"
        return 0
    fi
    if [ -n "$BRIG_USER" ] && [ "$BRIG_USER" != "root" ] \
       && id "$BRIG_USER" >/dev/null 2>&1 && command -v usermod >/dev/null 2>&1; then
        if usermod -aG "$BRIG_GROUP" "$BRIG_USER" 2>/dev/null; then
            say "added $BRIG_USER to the $BRIG_GROUP group (re-login to pick it up)"
        else
            warn "could not add $BRIG_USER to $BRIG_GROUP"
        fi
    fi
}

# ---------------------------------------------------------------- storage

pool_exists() { dmsetup info "$1" >/dev/null 2>&1; }

check_held_metadata_snap() {
    held="$(dmsetup status "$1" 2>/dev/null | awk '{print $7}')"
    if [ -n "$held" ] && [ "$held" != "-" ]; then
        warn "pool $1 is holding a metadata snapshot ($held)."
        warn "Release it with: dmsetup message $1 0 release_metadata_snap"
    fi
}

setup_storage() {
    POOL_CREATED=false
    POOL_LOOP_DATA=""
    POOL_LOOP_META=""
    if [ "$DM_AVAILABLE" != "true" ]; then
        say "devmapper thin-pool unavailable, skipping pool setup (brig uses overlayfs)"
        return 0
    fi

    dm_dir="$DATA_DIR/devmapper"
    mkdir -p "$dm_dir" "$DATA_DIR/devmapper-snap"
    data="$dm_dir/data"; meta="$dm_dir/meta"

    if pool_exists "$POOL_NAME"; then
        say "device-mapper pool $POOL_NAME already exists, reusing it"
        POOL_CREATED="${PRIOR_POOL_CREATED:-false}"
        POOL_LOOP_DATA="$(losetup -j "$data" 2>/dev/null | cut -d: -f1)"
        POOL_LOOP_META="$(losetup -j "$meta" 2>/dev/null | cut -d: -f1)"
        check_held_metadata_snap "$POOL_NAME"
        return 0
    fi

    for f in "$data:$POOL_SIZE" "$meta:$POOL_META_SIZE"; do
        path="${f%%:*}"; size="${f##*:}"
        [ -f "$path" ] && continue
        if [ "$POOL_PREALLOC" = "true" ]; then
            fallocate -l "$size" "$path" || fatal "fallocate failed for $path"
        else
            truncate -s "$size" "$path" || fatal "truncate failed for $path"
        fi
    done

    POOL_LOOP_DATA="$(losetup -j "$data" | cut -d: -f1)"
    [ -n "$POOL_LOOP_DATA" ] || POOL_LOOP_DATA="$(losetup --find --show "$data")"
    POOL_LOOP_META="$(losetup -j "$meta" | cut -d: -f1)"
    [ -n "$POOL_LOOP_META" ] || POOL_LOOP_META="$(losetup --find --show "$meta")"

    sectors=$(( $(blockdev --getsize64 "$POOL_LOOP_DATA") / 512 ))
    dmsetup create "$POOL_NAME" \
        --table "0 $sectors thin-pool $POOL_LOOP_META $POOL_LOOP_DATA 128 32768" \
        || fatal "dmsetup create failed for $POOL_NAME"
    POOL_CREATED=true
    say "created device-mapper pool $POOL_NAME"
    check_held_metadata_snap "$POOL_NAME"
}

# ---------------------------------------------------------------- host wiring

# The three host-global things the tarball cannot carry: the urunc config symlink
# at a hardcoded path, the brig launchers on PATH, and (below) the systemd units.
host_integration() {
    # /etc/urunc/config.toml is a hardcoded constant in urunc.
    ETC_SYMLINK_CREATED=false
    ETC_SYMLINK_BACKUP=""
    # A user install cannot write /etc, and does not need to: the user unit
    # passes URUNC_CONFIG_FILE, which the shim inherits from containerd.
    if [ "$INSTALL_MODE" = "user" ]; then
        write_launchers
        return 0
    fi
    target="/etc/urunc/config.toml"
    mkdir -p /etc/urunc
    if [ -L "$target" ] && [ "$(readlink "$target")" = "$ETC_DIR/urunc.toml" ]; then
        ETC_SYMLINK_CREATED="${PRIOR_ETC_CREATED:-false}"
        ETC_SYMLINK_BACKUP="${PRIOR_ETC_BACKUP:-}"
    elif [ -e "$target" ] || [ -L "$target" ]; then
        ETC_SYMLINK_BACKUP="$target.pre-brig-install"
        mv "$target" "$ETC_SYMLINK_BACKUP"
        ln -s "$ETC_DIR/urunc.toml" "$target"
        ETC_SYMLINK_CREATED=true
        warn "a file was already at $target, saved as $ETC_SYMLINK_BACKUP"
    else
        ln -s "$ETC_DIR/urunc.toml" "$target"
        ETC_SYMLINK_CREATED=true
    fi

    write_launchers
}

# brig and brigd launchers: source the env, then exec the real binary. Kept off
# the tree so `brig` is on a normal PATH while the tree stays relocatable.
write_launchers() {
    mkdir -p "$LAUNCH_DIR"
    for prog in brig brigd; do
        [ -x "$BIN_DIR/$prog" ] || continue
        cat > "$LAUNCH_DIR/$prog" <<LAUNCH
#!/bin/sh
# brig launcher, generated by install.sh.
[ -f "$ETC_DIR/brig-env.sh" ] && . "$ETC_DIR/brig-env.sh"
exec "$BIN_DIR/$prog" "\$@"
LAUNCH
        chmod 0755 "$LAUNCH_DIR/$prog"
    done
}

# ---------------------------------------------------------------- stamp

write_stamp() {
    cat > "$STAMP" <<STAMPEOF
# What this install created. The uninstaller removes exactly this. Generated.
INSTALL_MODE=$INSTALL_MODE
PREFIX=$PREFIX
DATA_DIR=$DATA_DIR
RUN_DIR=$RUN_DIR
INSTALL_DATE=$(date -u +%Y-%m-%dT%H:%M:%SZ)
NAMESPACE=$NAMESPACE
SNAPSHOTTER=$SNAPSHOTTER
BRIDGE_NAME=brig0
SERVICE_NAME=$SERVICE_NAME
POOL_SERVICE_NAME=$POOL_SERVICE_NAME
SYSTEMD_INSTALLED=$INSTALL_SYSTEMD
POOL_NAME=$([ "$DM_AVAILABLE" = "true" ] && echo "$POOL_NAME" || echo "")
POOL_CREATED=$POOL_CREATED
POOL_LOOP_DATA=$POOL_LOOP_DATA
POOL_LOOP_META=$POOL_LOOP_META
BRIG_GROUP=$BRIG_GROUP
GROUP_CREATED=${GROUP_CREATED:-false}
BRIG_LAUNCHER=$LAUNCH_DIR/brig
BRIGD_LAUNCHER=$LAUNCH_DIR/brigd
ETC_SYMLINK=$([ "$INSTALL_MODE" = "user" ] && echo "" || echo "/etc/urunc/config.toml")
ETC_SYMLINK_CREATED=$ETC_SYMLINK_CREATED
ETC_SYMLINK_BACKUP=$ETC_SYMLINK_BACKUP
STAMPEOF
    chmod 0600 "$STAMP"
}

# ---------------------------------------------------------------- systemd

install_systemd() {
    [ "$INSTALL_SYSTEMD" = "true" ] || { say "not installing a systemd service"; return 0; }
    unit_dir="$ETC_DIR/systemd"
    [ -f "$unit_dir/$SERVICE_NAME.service" ] || fatal "the tarball carries no $SERVICE_NAME.service"

    if [ "$DM_AVAILABLE" = "true" ] && [ -f "$unit_dir/$POOL_SERVICE_NAME.service" ]; then
        systemctl enable "$unit_dir/$POOL_SERVICE_NAME.service" >/dev/null 2>&1 \
            || fatal "failed to enable $POOL_SERVICE_NAME.service"
    else
        # No pool on this host: drop the soft dependency so containerd starts
        # without a dangling reference to a service that was never enabled.
        sed -i "/^Wants=$POOL_SERVICE_NAME\.service\$/d;/^After=$POOL_SERVICE_NAME\.service\$/d" \
            "$unit_dir/$SERVICE_NAME.service" 2>/dev/null || true
    fi
    systemctl enable "$unit_dir/$SERVICE_NAME.service" >/dev/null 2>&1 \
        || fatal "failed to enable $SERVICE_NAME.service"
    systemctl daemon-reload
    say "enabled $SERVICE_NAME.service"
}

# ---------------------------------------------------------------- start

start_stack() {
    if [ "$SKIP_START" = "true" ]; then
        say "INSTALL_BRIG_SKIP_START is set, not starting containerd"
        return 0
    fi
    # A user install's daemon is rootless containerd under a systemd --user
    # unit. brig-rootless-setup.sh writes that unit and starts it, and is also
    # what a second user on a shared system install runs, so the per-user work
    # lives there and not here.
    if [ "$INSTALL_MODE" = "user" ]; then
        [ -x "$BIN_DIR/brig-rootless-setup.sh" ] \
            || fatal "the tarball carries no brig-rootless-setup.sh"
        _break_bar
        "$BIN_DIR/brig-rootless-setup.sh" || fatal "the rootless setup failed"
        return 0
    fi
    if [ "$INSTALL_SYSTEMD" != "true" ]; then
        say "no systemd service; start containerd yourself:"
        say "  $BIN_DIR/containerd --config $ETC_DIR/containerd.toml"
        return 0
    fi
    systemctl restart "$SERVICE_NAME.service" || fatal "failed to start $SERVICE_NAME.service"
    i=0
    while [ "$i" -lt 30 ]; do
        [ -S "$CONTAINERD_SOCK" ] && break
        i=$((i + 1)); sleep 1
    done
    [ -S "$CONTAINERD_SOCK" ] || fatal "containerd did not create $CONTAINERD_SOCK.
    Check: journalctl -u $SERVICE_NAME.service -n 50"

    out="$("$BIN_DIR/ctr" --address "$CONTAINERD_SOCK" plugin ls 2>&1)" \
        || fatal "could not talk to the private containerd"
    say "containerd up, brig default snapshotter: $SNAPSHOTTER"
    if [ "$DM_AVAILABLE" = "true" ]; then
        state="$(echo "$out" | awk '$2 == "devmapper" {print $4}')"
        if [ "$state" = "ok" ]; then
            say "devmapper is ready; export CONTAINERD_SNAPSHOTTER=devmapper to use it"
        else
            warn "devmapper pool set up but the snapshotter is not ok. Check $POOL_NAME."
        fi
    fi
}

# ---------------------------------------------------------------- main

main() {
    while [ $# -gt 0 ]; do
        case "$1" in
            --help|-h) usage; exit 0 ;;
            --verbose|-v) INSTALL_BRIG_VERBOSE=true ;;
            --quiet|-q) INSTALL_BRIG_VERBOSE=false ;;
            --system) INSTALL_MODE=system ;;
            --user) INSTALL_MODE=user ;;
            *) fatal "unknown option: $1 (see --help)" ;;
        esac
        shift
    done

    setup_env
    verify_system
    if [ "$INSTALL_MODE" = "user" ]; then
        verify_rootless_prereqs
    fi
    verify_root_dir
    ask_systemd

    # Now the tracked pipeline. Total stages depend on whether systemd is on.
    TOTAL=8
    [ "$INSTALL_SYSTEMD" = "true" ] && TOTAL=9

    progress "group";        setup_group
    progress "download";     fetch_tarball
    progress "unpack";       unpack_tarball
    progress "storage";      setup_storage
    progress "wiring";       host_integration
    progress "record";       write_stamp
    if [ "$INSTALL_SYSTEMD" = "true" ]; then
        progress "systemd";  install_systemd
    fi
    progress "start";        start_stack
    progress "done"

    ver="$(awk -F= '$1 == "BUNDLE_VERSION" {print $2}' "$PINS" 2>/dev/null)"
    grp_note=""
    start_note="  started:   $SERVICE_NAME.service"
    if [ "$INSTALL_MODE" = "user" ]; then
        start_note="  started:   brig-containerd.service (systemd --user)"
        case ":$PATH:" in
            *":$LAUNCH_DIR:"*) ;;
            *) grp_note="  path:      $LAUNCH_DIR is not on your PATH; add it to run brig by name
" ;;
        esac
    else
        getent group "$BRIG_GROUP" >/dev/null 2>&1 \
            && grp_note="  group:     $BRIG_GROUP owns the socket, which is not enough to run
             brig as a normal user: see docs/rootless.md, or run
             $BIN_DIR/brig-ctl rootless as that user
"
        [ "$INSTALL_SYSTEMD" = "true" ] || start_note="  not started: no systemd service was installed"
    fi

    cat >&2 <<DONE

[brig-install] brig ${ver:-installed} is installed ($INSTALL_MODE)

  prefix:    $PREFIX
  state:     $DATA_DIR
  socket:    $CONTAINERD_SOCK
  snapshotter: $SNAPSHOTTER
${grp_note}${start_note}

  brig doctor
  brig run claude ~/code/demo
  $BIN_DIR/brig-ctl status
  $BIN_DIR/brig-ctl uninstall

DONE
}

main "$@"
