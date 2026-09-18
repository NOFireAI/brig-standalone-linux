# Standalone urunc packaging and installer -- design

Status: P1 to P5 built. The generic urunc layer (P1-P4) was verified on xob0
(Ubuntu 24.04, amd64) and rpi5-6 (Debian 12, Raspberry Pi 5, arm64); P5 turned
it into the self-contained brig installer that is now the shipped product. See
README.md for the shipped behavior, "Decisions taken during implementation" for
where this document was overtaken, and "P5: the brig installer" below for the
conversion.
Target issue: NOFireAI/engineering#1272 (the brig self-contained bundle)
Scope of this document: the generic urunc layer and its conversion to brig.

## P5: the brig installer

The generic layer was always meant to be re-skinned for brig (P5 below). That is
now done and is what `install.sh` and `scripts/build-bundle.sh` produce.

- **One root, laid out like k3s.** Everything lives under `/var/lib/brig`, as
  two sibling trees: `data/` holds the immutable binaries, config and boot assets
  (the unpacked tarball) and `agent/` holds the containerd store, snapshots and
  pool. The socket stays in `/run/brig` and the launchers on the host `PATH`,
  exactly as k3s keeps its socket in `/run/k3s` and its binary in
  `/usr/local/bin` while everything else sits under `/var/lib/rancher/k3s`. This
  replaces the earlier `/opt/brig` + `/var/lib/brig` split: the immutable/mutable
  separation is kept, but as `data/` vs `agent/` under one root rather than two
  top-level directories.
- **One tarball, built by the release, unpacked by the installer.** The unit of
  distribution is a single per-arch tarball published by this repository's release
  workflow. It is a complete `/var/lib/brig/data` tree: every binary, every config
  file, the systemd units, the wrappers and the boot assets, laid out and ready.
  `scripts/build-bundle.sh` is where all the assembly and building happens;
  `install.sh` fetches that one tarball, verifies it, unpacks it, and wires it into
  the host. The installer builds nothing, runs no compiler and no docker, and
  fetches nothing else. Because the config files carry the fixed layout, the paths
  above are not configurable at install time.
- **Why three things are built (at release).** Most components are upstream release
  artifacts. Three have no upstream release and are compiled in the build: urunc
  (from `urunc-dev/urunc@feat/unchanged_containers`, CGO static, so native per arch
  under qemu/binfmt), urunit (from `NOFireAI/urunit@urunit_agent`, C static), and
  the brig `container-initrd`. brig execs into a guest through an in-guest agent
  (`urunit-agent`) whose protocol must match the urunc shim, so hull-assets'
  prebuilt initrd (hull's agent) is not usable; the build assembles a brig initrd
  from urunit + `urunit-agent` (from the same urunc commit as the shim) + busybox +
  urunc's `container-init`. The kernel still comes from `ghcr.io/nofireai/hull-assets`.
  Because urunc and the initrd ship in one tarball built together, their agent
  commit matches by construction.
- **The installer's own job** is the host wiring the tarball cannot carry: create
  the state and socket dirs, provision the device-mapper pool when the kernel
  supports it (brig defaults to overlayfs; `CONTAINERD_SNAPSHOTTER=devmapper`
  switches at runtime), create the `brig` group, drop the
  `/etc/urunc/config.toml` symlink and the `/usr/local/bin` launchers, write the
  `.install-stamp`, and -- after asking -- enable the systemd service and start it.
  It runs quiet with a progress bar by default, or verbose with a line per stage.
- **Non-root via a group.** A `brig` group owns the private containerd socket: the
  systemd unit chgrps the socket to that group by name once containerd is up (no
  gid is baked into `containerd.toml`, so the tarball stays host-independent). A
  member of the group runs `brig` through the `/usr/local/bin/brig` launcher, which
  sources `/var/lib/brig/data/etc/brig-env.sh` (pointing nerdctl at the private containerd
  and brig at the packed boot assets) and execs the real binary.

The rest of this document describes the generic urunc layer it is built on.

## Motivation

Issue #1272 describes the brig tree: a private containerd, the `brig-urunc`
shim, nerdctl, static VMMs, everything under `/var/lib/brig`,
nothing shared with the host. That is the right end state, but most of the work
in it is not brig-specific. It is "package urunc and everything it needs, then
put it on a machine in one command".

So we should build the generic thing first. One arch-specific tarball with
stock urunc and its dependencies, a k3s-style `curl | sh` installer, a
matching uninstaller, and devmapper set up for us rather than by hand. Once
that works, brig re-skins it: different root dir, different runtime class
name, a couple of extra binaries.

Installing urunc today means following
[docs/installation.md](https://github.com/urunc-dev/urunc/blob/main/docs/installation.md)
by hand. That document is ~500 lines and it touches the host's containerd
config, the host's `/usr/local/bin` and the host's thinpool. It works, and
every step of it is a step we can automate.

## Decisions taken during implementation

Four things changed once this went from design to a working installer.

**One base directory, not three.** Everything lives under `/var/lib/urunc`:
binaries, configuration, containerd state, the socket and the pool backing
files. The three-way split proposed below is the k3s shape, but a single root
is what makes uninstall a single `rm -rf` plus three recorded host objects.

**No LVM pool.** Loop backed files only. The `lvm` mode described below was
dropped.

**Sparse backing files.** `truncate`, not `fallocate`, so a 100G pool costs
nothing until it is used. The measured thin-pool stall is real, so
`INSTALL_URUNC_POOL_PREALLOC=true` switches back to `fallocate` for anyone who
hits it.

**No QEMU.** Not installed. `INSTALL_URUNC_MONITORS` can add it back from the
same monitors release. virtiofsd is kept, at 3MB, because it is the only rootfs
path left when the host has no device-mapper thin pool.

`/etc/urunc/config.toml` is left as a symlink into the tree, as the design
proposed. The upstream `URUNC_CONFIG` patch is still worth sending, and is not
needed for this to work.

## What testing found

Four things that only showed up on a real host. All four are folded into
`install.sh`.

1. **Pulls fail without `unpack_config`.** A hand written containerd config has
   no `[[plugins.'io.containerd.transfer.v1.local'.unpack_config]]` entry, and
   every pull dies with `no unpack platforms defined`. The installer writes one
   for the chosen snapshotter and one for overlayfs.

2. **nerdctl's default bridge collides with the host.** nerdctl creates its
   default network on 10.4.0.0/24, which a host nerdctl has usually already
   taken. The installer ships its own conflist on 10.44.0.0/24 with a `urunc0`
   bridge, both configurable.

3. **The snapshot filesystem has to be ext2.** Rumprun guests support nothing
   else (`pkg/unikontainers/unikernels/rumprun.go`), and with ext4 urunc fails
   with "can not use the container rootfs as the sandbox's guest rootfs through
   block or shared-fs". Linux guests read ext2 as well, so ext2 is the one
   default that works for every guest.

4. **solo5-hvt dies under the default seccomp profile on Ubuntu 24.04.** Exit
   159, SIGSYS. urunc applies its own hardcoded allowlist before executing the
   tender, with `DefaultAction: ActionTrap`, and upstream documents that
   allowlist as tested on Ubuntu 20.04 and 22.04 only. Both solo5 v0.9.3 and
   v0.12.1 fail identically here, and both boot with the profile off, so this
   is neither the packaging nor the solo5 version. It is the one thing the
   installer does not fix, and the README says so.

## What urunc actually needs

Surveyed against `urunc-dev/urunc` main at 609e07e. Four groups:

| Group | Components | Where they come from |
| --- | --- | --- |
| urunc itself | `urunc`, `containerd-shim-urunc-v2` | urunc releases (static, per-arch) |
| monitors | firecracker, cloud-hypervisor, solo5-hvt, solo5-spt, qemu + its firmware blobs, virtiofsd | `urunc-dev/monitors-build` releases |
| container plumbing | containerd, ctr, runc, nerdctl, CNI plugins | upstream releases |
| host bits we do not ship | `/dev/kvm`, device-mapper, `iptables`, a kernel with tun/tap | the distro |

Two things fall out of this that make the job much smaller than it looks.

First, upstream already publishes both halves of the artifact set. urunc
releases carry `urunc_static_$ARCH` and `containerd-shim-urunc-v2_static_$ARCH`
(12-14MB each). `monitors-build` publishes a single per-arch tarball with all
five monitors plus virtiofsd, already static, already versioned in the tag
name, e.g. `FC-v1.7.0_CLH-v50.0_S5-v0.12.1_VFS_-v1.13.0_QM-v10.1.1-9a44e` at
42MB compressed for amd64. So this is an assembly job, not a build farm. We
pin, fetch, verify and lay out. Building from source stays available behind a
flag for the cases where we need a patched urunc.

Second, `runc` is only needed for the Kubernetes path, where urunc delegates
pause and sidecar containers to it (`cmd/urunc/utils.go:98`, an `exec.LookPath`).
For a standalone non-k8s install it is still worth shipping, since nerdctl
users will want normal containers next to unikernels.

## Findings that constrain the design

These came out of reading the tree and poking the test hosts. Each one changes
a decision.

**1. `/etc/urunc/config.toml` is a hardcoded constant.**

```go
// pkg/unikontainers/urunc_config.go:25
const UruncConfigPath = "/etc/urunc/config.toml"
```

There is no env var and no flag. Both call sites (`cmd/urunc/create.go:77` and
`pkg/containerd-shim/guest_rootfs.go:62`) use the constant directly. So urunc
is relocatable in every path *except* its own config, and there can only be one
urunc configuration per host.

For a stock bundle the workaround is a symlink: the real file lives at
`$URUNC_ROOT/etc/config.toml` and `/etc/urunc/config.toml` points at it.
`toml.DecodeFile` opens through symlinks, so this works with no patch. The
installer records whether it created that symlink, and the uninstaller removes
it only when it still points into our tree.

We should also send a small patch upstream that honors a `URUNC_CONFIG`
environment variable and falls back to the constant. That is the one change
that makes two urunc installs coexist on a host, and brig will need it.

**2. containerd, nerdctl, runc and the CNI plugins are fully relocatable.**

containerd takes `root`, `state` and `grpc.address` in its config. nerdctl
reads `$NERDCTL_TOML` and honors `$CONTAINERD_ADDRESS`, `$CONTAINERD_NAMESPACE`,
`$CONTAINERD_SNAPSHOTTER` and `$CNI_PATH`. Verified on xob0 with the installed
nerdctl 2.0.3 and containerd 2.2.6. So a private stack needs no patched
binaries, only a config file and a systemd unit with the right `Environment=`
lines.

containerd resolves the shim by looking up `containerd-shim-urunc-v2` on its
own `PATH`. That is the hook we use: the private containerd unit gets
`Environment=PATH=$URUNC_ROOT/bin:/usr/sbin:/usr/bin:/sbin:/bin`, and the
private stack picks up the bundled shim while the host containerd keeps
picking up whatever it had.

**3. All three test hosts already run a host-wide urunc and a live thinpool.**

`nofire`, `xob0` and `nofire-cerno` are all Ubuntu 24.04 / x86_64 with
containerd 2.2.6. Each has `/usr/local/bin/urunc`, `/etc/urunc/config.toml`,
monitors in `/opt/urunc/bin`, and a devmapper pool in use: `devpool` on xob0
(loop-backed, 200GB), `ubuntu--vg-devpool` and a live `k3s-devpool` on the
other two.

So coexistence is a hard requirement, not a nice-to-have. The installer must
not write the host's `/etc/containerd/config.toml`, must not touch the host
pool, and must not restart the host containerd. Uninstall must leave all of
that exactly as it found it. These hosts are a good test bed precisely because
they will notice if we get it wrong.

It also means the default root cannot be assumed empty. `/opt/urunc` is
already populated on all three.

**4. The stock thinpool script is the slow configuration.**

`script/dm_create.sh` creates the backing files with `truncate`, which leaves
them sparse, on whatever filesystem `/var/lib/containerd` sits on, then loops
them. On ext4 that puts thin-pool metadata writes behind jbd2 commits and
`create_snap` stalls for tens of seconds. Measured previously: `fallocate`
instead of `truncate` cuts the stall rate from ~100% to ~16%, and moving off
the loop file onto a real block device removes it.

So we should not ship `dm_create.sh` as-is. The installer prefers a real
device, falls back to `fallocate`d loop files, and never uses `truncate`.

**5. QEMU's firmware blobs are most of the bundle.**

On xob0 the installed monitor set is 76MB of binaries, 3.2MB of virtiofsd and
273MB of QEMU `share/`. So a full bundle is ~380MB installed, and a bundle
without QEMU is ~90MB. That argues for two flavors, with QEMU opt-in. It also
matches #1272, which already wants QEMU treated as an optional plugin path.

## Layout

`/var/run/urunc` cannot hold the tree. `/var/run` is a symlink to `/run`,
which is tmpfs, so it is cleared on every boot. Sockets belong there, 380MB of
firmware blobs and an image store do not. We should use the three-way split
that k3s uses: immutable artifacts in one place, mutable state in another,
runtime sockets in tmpfs.

```
/opt/urunc/                          $URUNC_ROOT -- immutable, replaced wholesale on upgrade
  bin/                               urunc, containerd-shim-urunc-v2, containerd, ctr,
                                     nerdctl, runc, firecracker, cloud-hypervisor,
                                     solo5-hvt, solo5-spt, qemu-system-$ARCH
  libexec/                           virtiofsd
  libexec/cni/                       CNI plugins
  share/qemu/                        QEMU firmware blobs
  etc/config.toml                    urunc config (the symlink target)
  etc/containerd.toml                private containerd config
  etc/nerdctl.toml                   private nerdctl config
  etc/cni/net.d/                     private CNI network
  pins.env                           every bundled version, one KEY=value per line
  .install-stamp                     what this install created, for the uninstaller

/var/lib/urunc/                      mutable state
  containerd/                        containerd root (images, snapshots, content store)
  devmapper/                         thinpool backing files, loop mode only

/run/urunc/                          ephemeral
  containerd/                        containerd state dir
  containerd.sock                    the private socket

/etc/urunc/config.toml               symlink -> /opt/urunc/etc/config.toml
/usr/local/bin/urunc-ctl             wrapper: exports the env and execs ctr/nerdctl
/usr/local/bin/urunc-uninstall.sh    generated at install time
```

Everything except `/etc/urunc/config.toml` moves with `$URUNC_ROOT`, so a
second install for testing goes to `/opt/urunc-test` and collides with nothing
but the symlink.

`pins.env` is the manifest #1272 asks for, and the single one this install
carries: it is what `brig-ctl version` prints. (An earlier design also emitted a
`components.json` and per-bundle SBOMs; both were dropped as redundant with
`pins.env`.)

### On the existing `/opt/urunc`

The upstream `urunc-deploy` convention already uses `/opt/urunc/bin` and
`/opt/urunc/share` for monitors, and all three test hosts have that layout.
Our tree is a superset of it, so the paths do not conflict in shape, but a
hand-made install has no `.install-stamp`.

The installer should therefore refuse to write into an existing `$URUNC_ROOT`
that it did not create, and print what it found and how to proceed. Two escape
hatches: `INSTALL_URUNC_FORCE=1` to take it over, or a different
`INSTALL_URUNC_ROOT`. Silent adoption is how we would corrupt somebody's
working setup.

## The installer

```
curl -sfL https://get.urunc.io/install.sh | sh -
```

Knobs, k3s naming so it reads familiar:

| Variable | Default | Meaning |
| --- | --- | --- |
| `INSTALL_URUNC_VERSION` | latest release | urunc version to install |
| `INSTALL_URUNC_CHANNEL` | `stable` | `stable` or `nightly` |
| `INSTALL_URUNC_MONITORS_VERSION` | pinned tag | monitors-build release tag |
| `INSTALL_URUNC_ROOT` | `/opt/urunc` | bundle root |
| `INSTALL_URUNC_DATA_DIR` | `/var/lib/urunc` | mutable state |
| `INSTALL_URUNC_FLAVOR` | `full` | `full` or `slim` (slim drops QEMU, ~90MB) |
| `INSTALL_URUNC_SNAPSHOTTER` | `devmapper` | `devmapper`, `blockfile` or `overlayfs` |
| `INSTALL_URUNC_POOL_MODE` | `auto` | `lvm`, `loop`, `existing` or `none` |
| `INSTALL_URUNC_POOL_DEVICE` | unset | block device or VG to carve the pool from |
| `INSTALL_URUNC_POOL_SIZE` | `100G` | pool data size |
| `INSTALL_URUNC_TARBALL` | unset | install from a local tarball, no network |
| `INSTALL_URUNC_SKIP_START` | `false` | lay the tree down, do not start containerd |
| `INSTALL_URUNC_FORCE` | `false` | take over a foreign `$URUNC_ROOT` |

What it does, in order:

1. Preflight. Check root, arch (amd64/arm64), `/dev/kvm`, the `dm_thin_pool`
   module, `iptables`, and that `$URUNC_ROOT` is either absent or ours. Fail
   with one clear line each, before touching anything.
2. Resolve versions and write `pins.env`.
3. Fetch the urunc binaries, the monitors tarball, containerd, runc, nerdctl
   and the CNI plugins into a temp dir. Verify checksums, and signatures where
   upstream publishes them.
4. Lay out `$URUNC_ROOT` atomically: unpack into `$URUNC_ROOT.new`, then
   rename. A re-run is an upgrade, and a failed re-run leaves the old tree.
5. Set up storage (below).
6. Write the four config files, then the `/etc/urunc/config.toml` symlink.
7. Install `urunc-containerd.service`, plus the pool reload unit in loop mode.
8. Generate `urunc-uninstall.sh` from the stamp.
9. Start, then verify: the private `ctr plugin ls` shows the snapshotter `ok`,
   and a unikernel image runs end to end.

Offline install matters for the airgapped hosts, so `INSTALL_URUNC_TARBALL`
takes a pre-staged bundle and skips every download.

## Storage and the devmapper snapshotter

Three modes, chosen by `INSTALL_URUNC_POOL_MODE`, defaulting to `auto`.

**`lvm`**, preferred. Given a VG with free extents, or a whole device in
`INSTALL_URUNC_POOL_DEVICE`, create a thin pool LV. No loop devices, no jbd2 in
the path, and LVM reactivates it at boot, so no reload unit is needed. This is
what `auto` picks when it finds free extents.

**`loop`**, fallback. `fallocate` (never `truncate`) the data and metadata
files under `$DATA_DIR/devmapper`, `losetup` them, `dmsetup create` the pool.
Install `urunc-devpool.service` to re-create the pool before the private
containerd starts, ordered `Before=urunc-containerd.service`. This is stock
`dm_create.sh` with the sparse-file bug fixed and the naming made unique.

**`existing`**, for a pool the operator already manages. We only write the
containerd config, and the uninstaller never touches the pool.

**`none`** falls back to overlayfs. urunc still runs, but the block-rootfs
paths are unavailable, so we print that plainly.

The pool is named from the root: `urunc-devpool` by default. It must not be
`containerd-pool` or `devpool`, both of which are already taken on the test
hosts.

One extra check the stock scripts do not do. A leaked dm-thin *metadata
snapshot* poisons every later `create_snap` on that pool, and it presents as
unrelated container failures. Field 7 of `dmsetup status <pool>` is the tell:
`-` when clean, a block number when one is held. The installer checks it after
creating the pool, and the uninstaller releases one before removing the pool.

## Uninstall

`urunc-uninstall.sh`, generated at install time, driven by `.install-stamp`. It
removes what we created and nothing else. Order matters, because a pool with
live thin devices will not go away:

1. `systemctl stop urunc-containerd.service`, disable both units, remove them.
2. Delete containers, tasks and snapshots in the private containerd namespaces.
3. Release a held metadata snapshot if `dmsetup status` shows one.
4. `dmsetup remove` every `urunc-devpool-snap-*`, then the pool itself.
5. `losetup -d` our loop devices, or `lvremove` our LV. Nothing else.
6. Remove `/etc/urunc/config.toml` only if it still points into our tree.
7. Remove `$URUNC_ROOT`, `$DATA_DIR`, `/run/urunc` and the wrappers.

`--keep-data` keeps `$DATA_DIR` for a reinstall. The script is idempotent, and
a second run on a half-removed install finishes the job rather than failing.

## Verification

xob0 is the primary test host: 753GB free, no k3s, and a host urunc install to
prove we do not disturb. The others are for the k3s-adjacent case, where the
host runs a live `k3s-devpool` that we must leave alone.

Install to `/opt/urunc-test` with `INSTALL_URUNC_DATA_DIR=/var/lib/urunc-test`,
so the host's own `/opt/urunc` is out of the picture for the first pass.

The two pool modes fall out of the hosts for free. xob0 has no LVM volume
groups at all, so `auto` picks `loop` there. nofire and nofire-cerno both have
`ubuntu-vg`, so `auto` picks `lvm`. That covers both paths without contriving
anything.

Positive tests:

- the private `ctr -a /run/urunc/containerd.sock plugin ls` shows devmapper `ok`
- a unikernel image runs to completion through the private stack, on each of
  firecracker, cloud-hypervisor, hvt and spt
- a normal OCI container runs through the same stack via nerdctl, with working
  network
- re-running the installer upgrades in place and does not lose the image store

Negative tests, which are the ones that actually matter here:

- host `/etc/containerd/config.toml` byte-identical before and after
- host containerd never restarted, `systemctl show -p ActiveEnterTimestamp`
  unchanged
- host `devpool` still listed and still healthy after our install and after our
  uninstall
- installer refuses a foreign `$URUNC_ROOT` without `INSTALL_URUNC_FORCE`
- uninstall on a host where the pool was `existing` leaves the pool alone
- after uninstall, `losetup -a` and `dmsetup ls` show exactly what they showed
  before install

## Phases

- **P0 -- design.** This document. Decisions in the open questions below.
- **P1 -- bundle and install.** Fetch, verify, lay out, private containerd,
  nerdctl, configs, service. Snapshotter `overlayfs` only, so the storage work
  does not block the first end-to-end run.
- **P2 -- storage.** The three pool modes, the reload unit, the metadata-snap
  check.
- **P3 -- uninstall.** The stamp, the generated script, the negative tests.
- **P4 -- release.** A workflow that builds the per-arch tarballs, publishes
  `install.sh`, records `pins.env`, and cosign-signs the checksums.
- **P5 -- hand to brig.** Parameterize root, runtime class and socket path, and
  close the generic half of #1272.

P1 through P4 are built. P1 to P3 are verified end to end on xob0; P4's bundle
build, reproducibility, offline install and signature refusal are verified
there too, while the release and CI workflows themselves are unrun until this
lands in a repo. P5 is open.

## Open questions

1. **Where does this live?** A new repo, or in-tree in `urunc-dev/urunc` under
   `deployment/standalone/`? In-tree is where it belongs long term, since it is
   stock urunc and upstream already carries `urunc-deploy`. Starting in a
   NOFireAI repo is faster and lets us move without upstream review. I would
   start in-tree on a branch and see how the first review goes.
2. **Bundle containerd, or attach to the host's?** I would bundle. It is what
   #1272 wants, it is the only way uninstall is clean, and the test hosts prove
   the coexistence case is real. Attaching to an existing containerd can be a
   second mode later.
3. **QEMU in the default flavor?** It is 273MB of the 380MB. I would default to
   `slim` and make `full` explicit, given #1272 already treats QEMU as
   optional.
4. **Do we send the `URUNC_CONFIG` patch upstream now?** It is a ten-line
   change and it removes the only non-relocatable path in urunc. I think yes,
   early, so the symlink stays a fallback rather than the design.
5. **Where does `install.sh` get served from?** `get.urunc.io` would match the
   k3s feel. A raw GitHub URL works on day one.
