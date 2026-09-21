# Running brig without root

A default install is root's: one tree under `/var/lib/brig`, a containerd on
`/run/brig/containerd.sock`, launchers in `/usr/local/bin`, and only root can
drive it. Running brig does not have to be root's, and there are two ways out.

The rootless path is a build-time option, so it is a second bundle rather than
something every install carries. A node that only runs brig as root ships none
of it.

| bundle | `install.sh` | result |
| --- | --- | --- |
| `brig-standalone-<v>-linux-<arch>` | as root, no flags | the default: root only |
| `...-rootless-linux-<arch>` | as root, `--rootless` | root, plus `brig-ctl rootless` for each user who wants it |
| `...-rootless-linux-<arch>` | as any user | everything under `$HOME`, that user only |

`install.sh` fetches the right one: the rootless bundle when you pass
`--rootless` or run it unprivileged, the plain one otherwise. A user install
against a plain bundle is refused rather than laid down half-working, since the
rootless path lives in the bundle and not in the installer.

On a machine where root installed the rootless bundle, each user opts in once:

```console
$ brig-ctl rootless
$ brig doctor && brig run claude ~/code/demo
```

## Why the brig group is not enough

The systemd unit hands the containerd socket to the `brig` group, which looks
like it should be all a normal user needs. It is not. nerdctl decides whether
it is rootless from its own euid, so a non-root caller is always pushed down
the rootless path, and a rootless nerdctl re-execs inside a user namespace
where supplementary groups are dropped. `id -G` in there returns `0 65534`. The
group never arrives, whatever the socket's mode says.

So a non-root user needs their own containerd rather than access to root's.
That is what the setup writes: a rootless containerd running this bundle's own
containerd binary and shims, a `nerdctl.toml` with the data root and CNI config
under `$HOME`, and a systemd user unit with lingering on so the daemon outlives
the login shell.

## What still needs root, once per host

Two things, and an unprivileged user can do neither:

- **An AppArmor profile for rootlesskit.** Ubuntu 24.04 and later set
  `kernel.apparmor_restrict_unprivileged_userns=1`, and the profile names the
  binary by path. rootlesskit prints the exact profile to install when it hits
  this.
- **Device access.** The VMM runs as the user inside that namespace, so the
  `kvm` group does not reach it and `KVM_CREATE_VM` returns `EPERM`. The setup
  grants the user directly with a udev rule over `/dev/kvm` and
  `/dev/vhost-vsock`. A plain `setfacl` does not survive the next event on the
  device, which is why it is a rule. The rule needs `setfacl` to exist
  (`apt install acl`) and the device's module to be loaded -- udev runs `RUN+=`
  without a shell and reports nothing, and a `/dev` node whose module was never
  loaded has no udev entry for a rule to match, so either one silently grants
  nothing. The setup checks for both and reads the grant back afterwards. It also
  writes `/etc/modules-load.d/brig.conf` so `vhost_vsock` comes back after a
  reboot: the module has no hardware to autoload from, and the node it creates
  is the only thing anyone could open to trigger it, so a host that has it
  today does not have it tomorrow. `kvm` needs no such help -- it autoloads
  from the CPU, which is why `/dev/kvm` is present on a host that never asked
  for it.

`brig-ctl rootless` does both with sudo, once, and says so as it goes. After
that any number of users run it and are unprivileged from then on.

`/dev/vhost-net` is not in the grant: a guest boots and reaches the network
without it. Which devices a run needs at all depends on the monitor urunc
picks -- qemu takes vsock from the kernel device, cloud-hypervisor implements
it in userspace.

### Images whose user is not root

The grant names one user, and that is not always who asks for the device. urunc
runs the monitor as the container image's user, and in a rootless install that
user is mapped through `/etc/subuid`: with `0 1000 1` / `1 100000 65536` in the
namespace's `uid_map`, an image running as root gets a monitor running as you,
while an image running as uid 501 gets one running as 100500. The first is
covered by the grant and boots; the second is not, and dies the same way an
ungranted host does:

```text
Fatal error: CreateHypervisor(VmCreate(Permission denied (os error 13)))
```

`setfacl` grants one uid at a time, so the subuid range cannot be named. Run
the setup with `--open-devices` to put these devices at mode `0666` instead,
which is what lets such an image run:

```console
$ brig-ctl rootless --open-devices
```

That is wider than the default grant -- every user of the host can then open
`/dev/kvm` -- which is why it is asked for rather than assumed. The narrow fix
belongs upstream in urunc, which has no reason to run the *monitor* as the
image's user: the image's user governs what runs inside the guest, and the
monitor is the host-side process that boots it.

## Installing into a home directory

`install.sh --user` puts the whole thing under `$HOME` and touches nothing
else. It is what a non-root caller gets by default, and it needs the rootless
bundle, which the installer selects on its own. On a machine where you have no
root at all:

```console
$ curl -fsSL https://raw.githubusercontent.com/NOFireAI/brig-standalone-linux/main/install.sh | sh -
$ ~/.local/bin/brig doctor && ~/.local/bin/brig run claude ~/code/demo
```

The tree lands in `~/.local/share/brig`, as `data/` and `agent/` the way
`/var/lib/brig` holds them; the launchers go in `~/.local/bin` and the socket
in `$XDG_RUNTIME_DIR`. The last stage runs `brig-rootless-setup.sh`, so the
daemon is up when the installer returns. `brig-ctl uninstall` takes it down
again as the same user.

The published tarball is generated for `/var/lib/brig/data`, so a user install
rewrites that path once the tree is in place. Nine generated files carry it:
`etc/brig-env.sh`, `etc/*.toml`, the systemd units and the scripts in `bin/`.
No binary does. The installer greps for the old prefix afterwards and fails if
any of it survived, which is what keeps that list honest as the bundle grows.

Two things differ from a root install. A thin pool needs `losetup` and
`dmsetup`, which a user namespace does not get, so a user install is overlayfs
only. And the tree is one copy per user where a root install is shared, so with
root and several users, `brig-ctl rootless` against one shared install is the
better trade.

The host prerequisites above still apply. `install.sh --user` reports both
before it unpacks anything, and the rootless setup asks sudo once to fix them.
The AppArmor profile names this prefix's rootlesskit, so a profile written for
`/var/lib` does not cover a tree in `$HOME`.

Building for a prefix directly is still an option, for an air-gapped host or a
layout of your own:

```console
$ PREFIX=$HOME/.local/share/brig/data \
  DATA_DIR=$HOME/.local/share/brig/agent \
  RUN_DIR=$XDG_RUNTIME_DIR/brig \
  ./scripts/build-bundle.sh --arch amd64 --version v0.2.0 --out dist
```

`pins.env` records that layout, so `install.sh` retargets from what the bundle
was built with rather than assuming the default.
