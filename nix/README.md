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
single-user nix, on 1 November 2026: `brig doctor` all `ok`, `brig run
ubuntu` booted, DNS and `apt-get update` worked in the guest, a file
written under `/work` appeared on the host, and the unit came back after a
reboot.
