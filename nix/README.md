# Brig with its Linux runtime, from Nix

The flake at the root of this repository builds Brig together with the
runtime it drives on Linux, so one `nix build` gives a host everything a
sandbox needs.

| Package | What it is |
| --- | --- |
| `brig` | `brig`, `brigd` and `brig-broker`, built from the Brig release. The same expression as `pkgs/by-name/br/brig` in nixpkgs. |
| `urunc` | `urunc` and `containerd-shim-urunc-v2`, built from the commit the bundle release pins. |
| `brig-guest` | The guest kernel, the initrd, the signed checksum files and the static monitors (`hvi`, `cloud-hypervisor`, `virtiofsd`), taken from the bundle release tarball. |
| `brig-runtime` | The default. `brig` wrapped with the environment the bundle's `brig-env.sh` sets, `brig-containerd` to run containerd with the bundle's config, and a systemd unit. containerd, nerdctl and the CNI plugins come from nixpkgs. |

Only root drives this stack, as with the bundle's node-wide install. There
is no rootless path.

## Install on a host with nix

```sh
nix build github:NOFireAI/brig-standalone-linux#brig-runtime
sudo cp result/lib/systemd/system/brig-containerd.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now brig-containerd
sudo ./result/bin/brig doctor
sudo ./result/bin/brig run ubuntu ~/demo
```

`nix build` needs flakes on. A fresh single-user nix has them off; put
`experimental-features = nix-command flakes` in `~/.config/nix/nix.conf`.

`nix profile install` on the same output puts `brig` on your PATH with its
shell completions. Run it under `sudo` with the full path, since `sudo`
resets PATH.

The host needs `/dev/kvm` and the `vhost_vsock` module:

```sh
sudo modprobe vhost_vsock
echo vhost_vsock | sudo tee /etc/modules-load.d/brig.conf
```

## NixOS

The flake exports a module. With it, the unit, the kernel modules and the
directories are declared, and `brig` is on PATH:

```nix
{
  inputs.brig-runtime.url = "github:NOFireAI/brig-standalone-linux";
  outputs = { nixpkgs, brig-runtime, ... }: {
    nixosConfigurations.host = nixpkgs.lib.nixosSystem {
      system = "x86_64-linux";
      modules = [
        brig-runtime.nixosModules.default
        {
          services.brig.enable = true;
          services.brig.package = brig-runtime.packages.x86_64-linux.brig-runtime;
        }
      ];
    };
  };
}
```

`nix flake check` runs a NixOS VM test of the module: the unit comes up,
the socket appears, `brig doctor` finds the runtime and the boot assets.
The test VM has no network, so it boots no sandbox. It needs KVM on the
host that runs it.

A sandbox needs network, which the test VM has not. To boot one on NixOS,
give the configuration above a VM variant and build that:

```nix
virtualisation.vmVariant.virtualisation = {
  memorySize = 4096;
  cores = 2;
  diskSize = 8192;
  graphics = false;
};
```

```sh
nix build .#nixosConfigurations.host.config.system.build.vm
./result/bin/run-nixos-vm
```

Three things only showed up on NixOS, because a single-user nix store on
Debian is writable by root and `/usr/sbin` and `/lib` exist there:

- nerdctl writes a lock and one conflist per sandbox network into the CNI
  config directory, so that directory is `/var/lib/brig/agent/cni/net.d`,
  seeded from the store when `brig-containerd` starts.
- urunc runs `/usr/sbin/mke2fs` by default to build the overlay-block
  rootfs. `urunc.toml` points it at the nixpkgs `mke2fs`.
- urunc binds `/lib`, `/lib64` and `/usr/lib` into the monitor's rootfs for
  a dynamically linked monitor. NixOS has no `/lib` or `/usr/lib`, and the
  monitors here are static. `nix/urunc-optional-libdirs.patch` skips a
  directory that is not there, as upstream already does for `/lib64`.

## Why some pieces are binaries

Three things in `brig-guest` are not built here. The guest kernel comes from
`hull-assets`, whose repository is not public. The initrd is assembled by
`scripts/build-bundle.sh` from `urunit` and busybox. `hvi` is a static build
from `brig-sh/hull`. All three are taken from the bundle release tarball,
pinned by the sha256 its signed `checksums.txt` lists.

`virtiofsd` and `cloud-hypervisor` are in nixpkgs, but the nixpkgs builds
are dynamically linked. `urunc` pivots into a monitor rootfs of its own
before it spawns them, and a dynamically linked binary cannot find its
interpreter in there. The bundle carries static builds, so those are used.

## State and paths

Same as the bundle's node-wide install: state under `/var/lib/brig/agent`,
the containerd socket at `/run/brig/containerd.sock`, the CNI bridge
`brig0` on `10.44.0.0/24`.

## Tested

Debian 12 on a GCP `n2-standard-4` with nested virtualization and
single-user nix, on 2 November 2026, following the steps above on a host
with nothing else on it: `nix build` from this repository took 2 minutes
(binaries from cache.nixos.org, `brig` and `urunc` built from source),
`brig doctor` all `ok`, a sandbox booted in 14 seconds on first pull,
`apt-get update` ran in the guest, a file written under `/work/demo`
appeared on the host, nothing was written under `/nix/store`, `nix store
verify` passed on the closure, and the unit, `vhost_vsock` and a new
sandbox came back after a reboot.

NixOS 26.11, built from the module with user-mode network, run as a qemu
VM on a Debian host on 2 November 2026, so the sandbox was a third level
of virtualization:
`brig doctor` all `ok`, `brig run ubuntu` pulled the image and booted, the
guest agent answered within seconds, `brig sh` ran commands in the guest in
about a second, DNS resolved, a file written under `/work` appeared on the
host.

On a scripted host, run `brig telemetry off` or `on` once first. The
first `brig run` on a tty otherwise waits on the consent prompt, and
`brig run` without `-d` stays attached.

Not tested: aarch64, a NixOS host on real hardware.
