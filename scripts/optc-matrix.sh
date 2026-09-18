#!/usr/bin/env bash
#
# Copyright (c) 2026, NOFire AI
# SPDX-License-Identifier: Apache-2.0
#
# Option-C matrix against a standalone urunc install.
#
# Boots a generic container image (ubuntu:latest by default) under each monitor
# and scores what came up. Adapted from the optc-matrix.sh preserved off nofire
# and nofire-cerno, which drove the host-wide install in the k8s.io namespace.
# This one talks to the private stack instead, so it needs no host containerd
# and leaves none of its state behind.
#
# It does NOT work against a stock urunc. The com.urunc.vmi.* annotations come
# from the Option-C patch series, and upstream ignores annotations it does not
# know, so a stock binary boots nothing and fails the same way an unannotated
# run does. The preflight below says so rather than letting you read it off a
# table of zeroes.
#
#   KBUILD=~/kbuild/linux-6.18.34-telem-builtin scripts/optc-matrix.sh

set -uo pipefail

URUNC_ROOT="${URUNC_ROOT:-/var/lib/urunc}"
CTL="$URUNC_ROOT/bin/urunc-ctl"
NERDCTL="$URUNC_ROOT/bin/nerdctl"

IMG="${IMG:-ubuntu:latest}"
WAIT="${WAIT:-60}"
MONITORS="${MONITORS:-firecracker}"
SNAPSHOTTER="${SNAPSHOTTER:-devmapper}"

# Where the telemetry kernel build and the VMI payloads live. These are host
# paths on the testbed, not something the bundle carries: vmlinux alone is
# ~392MB. See docs/introspection-followup.md.
KBUILD="${KBUILD:-$HOME/kbuild/linux-6.18.34-telem-builtin}"
VMI_DIR="${VMI_DIR:-/opt/urunc-vmi}"
BTF="${BTF:-$VMI_DIR/vmlinux.BTF}"
VMI_INITRD="${VMI_INITRD:-$VMI_DIR/vmi-initrd}"

RESULTS="${RESULTS:-$HOME/optc-results}"
OUT_DIR="${OUT_DIR:-$URUNC_ROOT/run/vmi}"

die() { echo "optc-matrix: $*" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || die "run this as root"
[ -x "$CTL" ] || die "no standalone urunc at $URUNC_ROOT. Install it first."

# Go keeps its string literals, so the annotations this needs are visible in
# the binary when the Option-C series is in the build.
if ! grep -qa "com.urunc.vmi.boot_kernel" "$URUNC_ROOT/bin/urunc"; then
    echo "optc-matrix: the installed urunc has no com.urunc.vmi.* support." >&2
    echo "  Apply the Option-C patch series and install that build:" >&2
    echo "    INSTALL_URUNC_DIST=<urunc>/dist sh install.sh" >&2
    die "refusing to produce a table of zeroes"
fi

boot_image() {
    case "$1" in
        firecracker|cloud-hypervisor) echo "$KBUILD/vmlinux.btf" ;;
        *) echo "$KBUILD/arch/x86/boot/bzImage" ;;
    esac
}

for f in "$KBUILD/vmlinux" "$VMI_INITRD"; do
    [ -e "$f" ] || die "missing $f"
done

mkdir -p "$RESULTS" "$OUT_DIR"

echo "host: $(hostname)   date: $(date -u +%FT%TZ)   image: $IMG"
echo "urunc: $("$URUNC_ROOT/bin/urunc" --version 2>&1 | head -1)"
sed -n 's/^URUNC_\(VERSION\|SOURCE\)=/  &/p' "$URUNC_ROOT/pins.env" 2>/dev/null

printf "\n%-18s %-5s %-5s %-6s %-6s %-8s %-8s %-6s %s\n" \
    MONITOR boot panic rootfs marker egress ctrlsock rich invmm

for hv in $MONITORS; do
    name="optc$(echo "$hv" | tr -cd 'a-z')"
    out="$OUT_DIR/$name.ndjson"
    "$CTL" nerdctl rm -f "$name" >/dev/null 2>&1
    rm -f "$out" "$RESULTS/$name.console"

    EXTRA=()
    [ "$hv" = hvi ] && EXTRA=(--annotation "com.urunc.vmi.btf=$BTF"
                              --annotation "com.urunc.vmi.events=/boot/hvi-ev.ndjson"
                              --annotation "com.urunc.vmi.introspect_interval=3")

    WL='echo VMIMARK; curl -sSm15 -o/dev/null -wEG=%{http_code} https://1.1.1.1; sleep 300'

    if ! "$CTL" nerdctl run -d --name "$name" --memory 2g \
            --runtime io.containerd.urunc.v2 --snapshotter "$SNAPSHOTTER" \
            --annotation com.urunc.unikernel.unikernelType=linux \
            --annotation "com.urunc.unikernel.hypervisor=$hv" \
            --annotation com.urunc.unikernel.mountRootfs=true \
            --annotation com.urunc.unikernel.binary=/boot/vmlinux \
            --annotation com.urunc.vmi.introspect=true \
            --annotation "com.urunc.vmi.kernel=$KBUILD/vmlinux" \
            --annotation "com.urunc.vmi.boot_kernel=$(boot_image "$hv")" \
            --annotation "com.urunc.vmi.initrd=$VMI_INITRD" \
            --annotation "com.urunc.vmi.output=$out" \
            ${EXTRA[@]+"${EXTRA[@]}"} \
            "$IMG" bash -lc "$WL" >"$RESULTS/$name.start" 2>&1; then
        printf "%-18s %-5s %-5s %-6s %-6s %-8s %-8s %-6s %s\n" \
            "$hv" START-FAILED - - - - - - -
        tail -3 "$RESULTS/$name.start" | sed 's/^/    /'
        continue
    fi

    "$CTL" nerdctl logs -f "$name" > "$RESULTS/$name.console" 2>&1 &
    follower=$!
    sleep "$WAIT"

    pid="$(pgrep -x "$hv" 2>/dev/null | tail -1)"
    sock=no; invmm=0
    if [ -n "$pid" ]; then
        test -S "/proc/$pid/root/urunc-telem.sock" && sock=yes
        invmm=$(grep -ac '"source":"mem"' "/proc/$pid/root/boot/hvi-ev.ndjson" 2>/dev/null)
        invmm=${invmm:-0}
        cp "/proc/$pid/root/boot/hvi-ev.ndjson" "$RESULTS/$name.hvi-ev.ndjson" 2>/dev/null
    fi
    kill "$follower" 2>/dev/null
    cp "$out" "$RESULTS/$name.ndjson.copy" 2>/dev/null
    "$CTL" nerdctl rm -f "$name" >/dev/null 2>&1

    log="$RESULTS/$name.console"
    b=$(grep -ac "Linux version" "$log")
    k=$(grep -ac "Kernel panic" "$log")
    rf=$(grep -ac "EXT4-fs (vda)" "$log")
    mk=$(grep -a VMIMARK "$log" | grep -avc "^\[")
    eg=$(grep -a "EG=" "$log" | grep -av "^\[" | grep -oE "EG=[0-9]+" | tail -1)
    rich=$(grep -ac '"provenance":"rich"' "$out" 2>/dev/null); rich=${rich:-0}

    printf "%-18s %-5s %-5s %-6s %-6s %-8s %-8s %-6s %s\n" \
        "$hv" "${b:-0}" "${k:-0}" "${rf:-0}" "${mk:-0}" "${eg:-none}" "$sock" "$rich" "$invmm"
    sleep 3
done
echo MATRIX_DONE
