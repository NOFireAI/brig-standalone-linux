# Running brig without root

The install is root's: one tree under `/var/lib/brig`, a containerd on
`/run/brig/containerd.sock`, launchers in `/usr/local/bin`. Running brig does
not have to be. `brig-ctl rootless` gives the invoking user a containerd of
their own, and from then on `brig run`, `brig sh` and the rest need no sudo.

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

The layout is fixed at build time, so a bundle built for a prefix under `$HOME`
can be unpacked by the user who runs it, with no root anywhere in the install:

```console
$ PREFIX=$HOME/.local/share/brig/data \
  DATA_DIR=$HOME/.local/share/brig/agent \
  RUN_DIR=$XDG_RUNTIME_DIR/brig \
  ./scripts/build-bundle.sh --arch amd64 --version v0.2.0 --out dist
```

Unpack it, write a launcher that sources `etc/brig-env.sh` and execs
`bin/brig`, then run `bin/brig-rootless-setup.sh`. The two host prerequisites
above still apply, and the AppArmor profile has to name this prefix's
rootlesskit rather than another one's.

The prefix is baked into the generated configs, so a bundle built for one home
does not serve another. Making one tarball serve any user means rewriting those
paths at unpack time, which is what an `install.sh --user` mode would do. The
files that carry them are text: `etc/brig-env.sh`, `etc/*.toml` and the
generated scripts in `bin/`.
