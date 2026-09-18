# Standalone brig

[brig](https://github.com/brig-sh/brig) and the whole Linux runtime it drives,
installed by one command and removed by another.

```
curl -fsSL https://raw.githubusercontent.com/NOFireAI/brig-standalone-linux/main/install.sh | sh -
```

brig runs a coding agent inside a microVM sandbox. On Linux it drives `nerdctl`
over containerd with the `urunc` shim, so a sandbox is a microVM rather than a
container sharing the host kernel.

`install.sh` fetches **one release tarball** — built and published by this
repository — and unpacks it. That tarball is a complete `/var/lib/brig/data`
tree: brig, brigd, the urunc runtime, the monitors, the boot assets, and every
config file, systemd unit and wrapper. The installer builds nothing and fetches
nothing else; it lays the tree down and wires it into the host.

The layout follows k3s: one root under `/var/lib/brig`, with the immutable
bundle and the mutable state as sibling trees, the socket in `/run`, and the
launchers on the host `PATH`:

```
/var/lib/brig/data    immutable: binaries, configuration, boot assets (the tarball)
/var/lib/brig/agent   mutable state: containerd store, snapshots, the pool
/run/brig             the private containerd socket
/usr/local/bin/brig   the launcher (also brigd)
```

These paths are fixed: the tarball's config files carry them, so they are not
configurable at install time. The host keeps its own containerd, its own
snapshotter and its own `/usr/local/bin`, except for the brig launcher. The full
list is under [What it touches outside the base directories](#what-it-touches-outside-the-base-directories).

## Install

```console
# curl -fsSL https://raw.githubusercontent.com/NOFireAI/brig-standalone-linux/main/install.sh | sh -
```

The installer resolves the newest release of the publishing repo, downloads its
per-architecture tarball, verifies it, unpacks it to `/var/lib/brig/data`, sets up the
device-mapper pool and the `brig` group, and — after asking — installs the
systemd service and starts it.

It asks one question:

```
[brig-install] Install and enable the brig-containerd systemd service now? [Y/n]
```

Answer `n` to lay the tree down without a service; the installer then prints the
command to run containerd by hand. A non-interactive run (piped from `curl` with
no controlling terminal) takes the default, yes. `INSTALL_BRIG_SYSTEMD=yes` or
`=no` skips the prompt entirely.

Two output modes, both with a progress bar:

```console
# curl -fsSL .../install.sh | sh -                          # quiet: one bar + summary
# curl -fsSL .../install.sh | INSTALL_BRIG_VERBOSE=true sh - # verbose: a line per stage
```

The tarball download shows `curl`'s own progress bar in both.

Point the installer at the repository that publishes the tarball with
`INSTALL_BRIG_RELEASE_REPO`, and pin a release with `INSTALL_BRIG_RELEASE_VERSION`.

### From a local tarball (airgapped)

`INSTALL_BRIG_BUNDLE` installs from a path or URL instead of resolving a release.
A URL is verified the same way a release is; a local path is taken as given, so
verify it on a machine that has cosign, copy it across, then:

```console
# INSTALL_BRIG_BUNDLE=./brig-standalone-v0.1.0-linux-amd64.tar.gz sh install.sh
```

### Verifying

A downloaded tarball is checked against the release's `checksums.txt`, which the
release workflow signs with keyless cosign. When `cosign` is on the host, the
signature is verified against the publishing workflow's identity; the SHA-256 is
always checked. `INSTALL_BRIG_SKIP_SIGCHECK=true` installs a remote tarball
unverified. To check it yourself:

```console
$ cosign verify-blob checksums.txt \
    --certificate checksums.txt.pem --signature checksums.txt.sig \
    --certificate-identity-regexp '^https://github.com/NOFireAI/brig-standalone-linux/.github/workflows/release.yml@refs/tags/' \
    --certificate-oidc-issuer https://token.actions.githubusercontent.com
$ sha256sum -c checksums.txt --ignore-missing
```

## What you get

```
/var/lib/brig/
  data/                    immutable, unpacked from the tarball:
    bin/            brig, brigd, urunc, containerd-shim-urunc-v2, containerd, ctr,
                    runc, nerdctl, cosign, oras, firecracker, cloud-hypervisor,
                    solo5-hvt, solo5-spt, brig-ctl, brig-pool-up, brig-uninstall.sh
    libexec/        virtiofsd
    libexec/cni/    CNI plugins
    etc/            urunc.toml, containerd.toml, nerdctl.toml, brig-env.sh,
                    cni/net.d/, systemd/, certs.d/
    share/guest/    Image or bzImage, container-initrd, bundle.json
    share/completions/  bash, zsh, fish completions
    pins.env        every bundled version, the one manifest
    .install-stamp  what this install created, read by the uninstaller
  agent/                   mutable state, created at install:
    containerd/     containerd root: images, snapshots, content store
    nerdctl/        nerdctl state
    devmapper/      thin pool backing files
    devmapper-snap/ snapshot metadata
    log/

/run/brig/
  containerd.sock the private socket
  containerd/     containerd state
```

Everything in `/var/lib/brig/data` comes from the tarball, verbatim. QEMU is not in it: it
is 273MB of the 380MB monitor set and the other four monitors do not need it (a
maintainer can produce a tarball with it by rebuilding — see
[Where the tarball comes from](#where-the-tarball-comes-from)). virtiofsd is, at
3MB, because it is how a guest gets the container rootfs when there is no block
device to hand it. See [Guest rootfs](#guest-rootfs).

## Running brig

The installer puts a `brig` launcher on `/usr/local/bin`. It sources
`/var/lib/brig/data/etc/brig-env.sh` and execs the real binary in `/var/lib/brig/data/bin`, so
brig reaches the private containerd and the boot assets with no environment to
set by hand.

```console
$ brig doctor
$ mkdir -p ~/code/demo
$ brig run claude ~/code/demo
```

`brig doctor` prints one line per check. `runtime` `ok` means brig found the
private `nerdctl`; `boot` `!!` is normal before the first run, since brig would
otherwise fetch assets on first use, and here they are already in place.

The `brig` group owns the socket, so a normal user can run brig once they are in
it. The install adds `$SUDO_USER` for you. Add anyone else with:

```console
# usermod -aG brig <user>
```

and have them log in again to pick up the group. (The systemd service hands the
socket to the group by name once containerd is up.)

## Driving the runtime by hand

`brig-ctl` wraps the private stack for when you want `ctr` or `nerdctl`
directly, without exporting anything.

```console
# /var/lib/brig/data/bin/brig-ctl status
# /var/lib/brig/data/bin/brig-ctl nerdctl ps -a
# /var/lib/brig/data/bin/brig-ctl ctr images ls
# /var/lib/brig/data/bin/brig-ctl run <image>
# /var/lib/brig/data/bin/brig-ctl version
```

`brig-ctl env` prints the exports the launcher uses:

```console
# eval "$(/var/lib/brig/data/bin/brig-ctl env)"
# nerdctl run --runtime io.containerd.urunc.v2 <image>
```

## Removing it

```console
# /var/lib/brig/data/bin/brig-ctl uninstall
```

The uninstaller reads `.install-stamp` and removes exactly what the install
created: the two trees, the `/run/brig` directory, the systemd units, the CNI
bridge, the `/etc/urunc/config.toml` symlink, the `brig` and `brigd` launchers,
and the `brig` group if it created one. A pool it did not create, a symlink that
no longer points into the tree, and anything belonging to the host are left
alone. `--keep-data` keeps the state under `/var/lib/brig/agent` for a reinstall.

## Configuration

Everything is driven by environment variables and a couple of flags.
`install.sh --help` lists them all. The whole set:

| Variable | Default | Meaning |
| --- | --- | --- |
| `INSTALL_BRIG_RELEASE_REPO` | `NOFireAI/brig-standalone-linux` | repo that publishes the tarball |
| `INSTALL_BRIG_RELEASE_VERSION` | `latest` | release tag to fetch, or `latest` |
| `INSTALL_BRIG_BUNDLE` | unset | a local tarball path, or a URL, to install instead |
| `INSTALL_BRIG_GROUP` | `brig` | unix group granted the socket |
| `INSTALL_BRIG_USER` | `$SUDO_USER` | user added to that group |
| `INSTALL_BRIG_SYSTEMD` | `ask` | `ask`, `yes` or `no`: install the systemd service |
| `INSTALL_BRIG_VERBOSE` | `false` | `true` for a line per stage (also `--verbose`) |
| `INSTALL_BRIG_SNAPSHOTTER` | unset | set to `overlayfs` to skip devmapper pool setup |
| `INSTALL_BRIG_POOL_SIZE` | `100G` | thin pool data size, sparse |
| `INSTALL_BRIG_POOL_PREALLOC` | `false` | `true` to `fallocate` the backing files |
| `INSTALL_BRIG_SKIP_START` | `false` | lay the tree down without starting it |
| `INSTALL_BRIG_SKIP_SIGCHECK` | `false` | install a remote tarball unverified |
| `INSTALL_BRIG_FORCE` | `false` | take over an `/var/lib/brig/data` we did not create |
| `INSTALL_BRIG_DEBUG` | `false` | `set -x` |

Flags: `--help`, `--verbose`, `--quiet`.

Re-running the installer upgrades in place: it lays down a newer tarball and
keeps the image store, the pool and the pool's ownership.

### The pool is sparse

The backing files are created with `truncate`, so a 100G pool costs nothing
until it is used. On ext4 a sparse backing file puts thin-pool metadata writes
behind the journal, and `create_snap` can stall. If you see that, set
`INSTALL_BRIG_POOL_PREALLOC=true` and the files are `fallocate`d instead.

### The snapshot filesystem is ext2

The tarball's containerd config formats snapshots as ext2, because rumprun
unikernels can read nothing else. Linux guests read ext2, ext3 and ext4, so ext2
is the one value that works for every guest.

### brig defaults to overlayfs; devmapper is switchable

brig is told to use the **overlayfs** snapshotter by default, but devmapper is
still configured in containerd. When the host kernel has device-mapper
thin-pool support, the installer provisions the pool so devmapper is ready to
use; to switch a run onto it, export `CONTAINERD_SNAPSHOTTER=devmapper` before
running brig — no reinstall. On a kernel without thin-pool support the pool is
silently skipped and overlayfs is the only option. Set
`INSTALL_BRIG_SNAPSHOTTER=overlayfs` to skip the pool setup even where it is
supported.

## Where the tarball comes from

The tarball is not assembled on the host. This repository's release workflow runs
[`scripts/build-bundle.sh`](scripts/build-bundle.sh), which does all the building
and publishes one tarball per architecture, building each on its own native runner
(amd64 on `ubuntu-24.04`, arm64 on `ubuntu-24.04-arm`). That build needs docker;
the install does not. Running `build-bundle.sh` by hand to cross-build the other
architecture needs qemu/binfmt instead of a native runner.

`build-bundle.sh` fetches the components that have upstream releases and builds
the three that do not:

| Component | Source | In the tarball |
| --- | --- | --- |
| brig, brigd | `brig-sh/brig` release | fetched, verified against its signed `checksums.txt` |
| urunc, containerd-shim-urunc-v2 | built from `urunc-dev/urunc` @ `feat/unchanged_containers` | CGO-static, built in a Go container |
| urunit | built from `NOFireAI/urunit` @ `urunit_agent` | C-static; goes into the initrd |
| container-initrd | built from the above | assembled for brig, not fetched |
| guest kernel (amd64) | `harbor.nbfc.io/nubificus/bunny/linux-kernel-cloud-hypervisor` | fetched; extracted from the bunny image's `/.boot/kernel` |
| guest kernel (arm64) | `ghcr.io/nofireai/hull-assets` | fetched; the same kernel hull and brig use |
| monitors, virtiofsd | `urunc-dev/monitors-build` | fetched |
| containerd, runc, nerdctl, CNI | upstream releases | fetched, upstream checksums |
| cosign | `sigstore/cosign` | fetched, pinned by sha256 |
| oras | `oras-project/oras` | fetched, its published checksums |

Then it generates the config files, systemd units, `brig-ctl` and the
uninstaller, and packs the whole `/var/lib/brig/data` tree.

### Why the initrd is brig's own, not hull-assets'

brig execs into a guest through an in-guest agent, `urunit-agent`, whose wire
protocol (`pkg/agentproto`) is a contract with the urunc shim. The two agree only
when both are built from the same urunc commit, and hull-assets' prebuilt initrd
carries hull's agent. So `build-bundle.sh` builds a brig initrd with urunc's own
`packaging/container-initrd` tooling, from `urunit`, a `urunit-agent` built from
the same urunc commit as the shim, a static `busybox`, and urunc's
`container-init`. The urunc binary and the initrd's agent ship in one tarball, so
they always match. Only the kernel is fetched rather than built — it is generic:
on amd64 from the bunny Cloud-Hypervisor kernel image, on arm64 from hull-assets.

Two properties of the initrd are checked when the build packs it and again when
the runtime boots it, because each fails in a way that does not name itself:
`container-initrd` must not be compressed (the runtime appends the container's
argv, environment and network identity to a copy of it, and a gzipped one accepts
the append and boots without it), and `busybox` must be built for the target
architecture, or it panics init on its first line.

The boot assets land in `share/guest/` and the launcher points brig at them
through `BRIG_BOOT_ASSETS`, so brig uses the packed assets rather than fetching
anything on first run. The annotations that carry them are
`com.urunc.unikernel.bootKernel` and `com.urunc.unikernel.bootInitrd`.

## What it touches outside the base directories

Six things, all recorded in `.install-stamp` and all undone by the uninstaller.

1. `/etc/urunc/config.toml`, a symlink to `etc/urunc.toml` in the tree. urunc
   reads that path from a hardcoded constant
   (`pkg/unikontainers/urunc_config.go`), so there is nowhere else to put it. An
   existing file is saved as `config.toml.pre-brig-install` and restored on
   uninstall.
2. `/usr/local/bin/brig` and `/usr/local/bin/brigd`, launchers that source
   `etc/brig-env.sh` and exec the real binaries in the tree. Removed on
   uninstall only while they still point into the tree.
3. The `brig` group, created if it did not exist and removed on uninstall only
   if this install created it.
4. The two systemd units, if you let the installer add them.
5. The device-mapper pool `brig-devpool` and its loop devices, which are
   kernel-global objects.
6. The `brig0` CNI bridge.

Nothing else. The host's `/etc/containerd/config.toml` is not read or written,
and the host containerd is never restarted.

## Known issue: solo5-hvt and seccomp

On Ubuntu 24.04 (kernel 6.8) a solo5-hvt guest dies with exit 159, which is
SIGSYS:

```console
# brig-ctl run harbor.nbfc.io/nubificus/urunc/hello-hvt-rumprun:latest unikernel
# echo $?
159
```

urunc applies its own syscall allowlist before executing `solo5-hvt`, with
`DefaultAction: ActionTrap`. The allowlist is hardcoded in
`pkg/unikontainers/hypervisors/hvt.go` and upstream documents it as tested on
Ubuntu 20.04 and 22.04 only, with a warning that other platforms may fail.

This is not a packaging problem and it is not the solo5 version. Both solo5
v0.9.3 and v0.12.1 fail identically on this kernel under the default profile,
and both boot cleanly with the profile off:

```console
# brig-ctl run --security-opt seccomp=unconfined <hvt image> unikernel
Solo5: solo5_exit(0) called
```

urunc only applies the filter when the OCI spec carries seccomp, so turning the
container profile off skips it. The other three monitors are unaffected:
firecracker, cloud-hypervisor and solo5-spt all sandbox themselves and do not go
through this path.

Upstream ships [goscall](https://github.com/nubificus/goscall) for working out
the syscalls a given solo5-hvt actually needs, which is what updating the
allowlist would take.

## Variants

Which tarball you install decides the variant; the installer does not choose one.
`build-bundle.sh` builds three:

- **`generic-boot`** (the default, and the brig path) boots an ordinary OCI
  image, `ubuntu:latest` included, which is what six of the eight shipped brig
  profiles need.
- **`stock`** boots unikernels only.
- **`introspection`** is `generic-boot` plus the Option-C telemetry work.

The released tarball is a `generic-boot` build.
[docs/variants.md](docs/variants.md) has the detail and what is left for
`introspection`.

## Guest rootfs

urunc gives a guest its rootfs in one of three ways, and picks the first that
works: a block device, virtiofs, or 9pfs.

The block device is the container's own snapshot, which needs the devmapper
snapshotter, which needs a kernel with `CONFIG_DM_THIN_PROVISIONING`. brig
defaults to the overlayfs snapshotter, whose snapshot is not a block device, so
the rootfs then goes over virtiofs — which is why virtiofsd is always installed.
Switching to devmapper (`CONTAINERD_SNAPSHOTTER=devmapper`, where the pool was
provisioned) is what gets a block-device rootfs.

What can use it is narrower than it sounds:

| Monitor | Shared fs | Notes |
| --- | --- | --- |
| cloud-hypervisor | virtiofs | works |
| qemu | virtiofs, 9pfs | not installed by default |
| firecracker | none | `SupportsSharedfs` is false |
| solo5-hvt, solo5-spt | none | `SupportsSharedfs` is false |

The guest has to agree. Linux guests read virtiofs. Rumprun reads ext2 only, and
Unikraft reads 9pfs but not virtiofs, so both need a block device or QEMU.

So on a host with no thin-pool support, a Linux guest on cloud-hypervisor works
and a firecracker or solo5 image that needs a rootfs does not.

### One socket for all of them

urunc hardcodes the virtiofsd socket as `/tmp/vhostqemu`, in `shared_fs.go`,
`cloud_hypervisor.go` and `qemu.go`. It is not derived from the container or the
install, so two guests using virtiofs at the same time, or two installs on one
host, contend for that one path. This is the one place where a second install is
not fully isolated from the first. It needs fixing upstream, not here.

## Where this has been run

The generic urunc layer underneath this installer was verified on the hosts
below. The brig layer on top (brig/brigd, the group, the launchers, the single
tarball) is newer; an end-to-end `brig run` on the split layout is the next thing
to check on a host.

| Host | Platform | Result |
| --- | --- | --- |
| xob0 | Ubuntu 24.04, kernel 6.8, amd64 | install, upgrade, uninstall; guests on firecracker, cloud-hypervisor and solo5-spt |
| rpi5-6 | Debian 12, kernel 6.12 rpt-rpi-2712, Raspberry Pi 5, arm64 | install, uninstall; guest on solo5-spt |
| jetson6 | Ubuntu 22.04, kernel 7.1.0-rc6, Jetson, arm64, GICv3 | install, uninstall; arm64 guest on firecracker |

On every one of them the host's containerd config, `dmsetup` and `losetup` state
were byte identical after uninstall to a capture taken before the install, and
the host containerd was never restarted.

### arm64 notes

The stack installs and runs on arm64. On jetson6, a GICv3 host, an arm64
unikernel boots under firecracker and answers on the address the CNI bridge gave
it.

**Where the arm64 images are.** The sample images under
`harbor.nbfc.io/nubificus/urunc` are almost all amd64 only. The multi-arch
images live under `ghcr.io/urunc-dev/unikernel-build` instead:
`nginx-fc-linux`, `redis-fc-linux`, `httpreply-fc`, `nginx-fc`,
`rumprun-httpreply-hvt` and `rumprun-httpreply-spt` all publish an index with
amd64 and arm64. Use those on arm64.

**Cloud-hypervisor does not run on a Raspberry Pi 5.** The Pi's GIC is not one
cloud-hypervisor can build a vGIC on. A GICv3 host such as jetson6 does not have
this problem.

**A kernel without thin provisioning has no devmapper.** The installer checks
`dmsetup targets` during preflight; where the thin-pool target is missing it
silently skips the pool, so brig runs on overlayfs and devmapper is simply not
available. On overlayfs the guest rootfs goes over virtiofs, which only
cloud-hypervisor and qemu can do.

## Requirements

Linux on amd64 or arm64, root to install, and `curl`, `tar`, `sha256sum`,
`dmsetup`, `losetup`, `iptables`. The installer only fetches and unpacks a
prebuilt tarball — it needs no `docker`, no compiler and no build. `/dev/kvm` is
needed at run time by the KVM-based monitors (firecracker, cloud-hypervisor,
solo5-hvt), but the installer does not check for it; solo5-spt runs without it.
brig itself then runs as any user in the `brig` group.
