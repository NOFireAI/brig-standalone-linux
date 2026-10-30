# Three variants, one tarball each

A variant is a **build-time** choice, not an install-time one. `install.sh`
fetches one tarball and unpacks it; whichever variant that tarball was built as
is the variant you get. `scripts/build-bundle.sh` builds them:

```console
$ scripts/build-bundle.sh --arch amd64 --version v0.1.0                      # generic-boot (default)
$ scripts/build-bundle.sh --arch amd64 --version v0.1.0 --variant stock
$ scripts/build-bundle.sh --arch amd64 --version v0.1.0 --variant introspection
```

The released tarball is a `generic-boot` build, so the plain

```console
# curl -fsSL https://raw.githubusercontent.com/NOFireAI/brig-standalone-linux/main/install.sh | sh -
```

installs `generic-boot`. `introspection` needs more than the build gives today;
the list is below.

## What each variant is

**`generic-boot`** (default) boots an ordinary OCI image, `ubuntu:latest`
included. urunc starts a VM, so it needs a kernel, and a stock container image
has none: on `ubuntu:latest` the whole of `/boot` is empty. The tarball carries a
kernel and an initrd from outside the image, named per run by annotation. This is
the runtime brig drives on Linux for `claude-code`, `codex`, `gemini`, `grok`,
`opencode` and `ubuntu` — six of the eight shipped profiles.

**`stock`** boots unikernels. A released urunc, the four monitors, containerd,
nerdctl. This is what boots a rumprun or Mirage image, and it is the one variant
whose urunc is fetched (`--urunc-version`) rather than built.

**`introspection`** is `generic-boot` plus the Option-C work: a sidecar spawned
per container by the shim, a telemetry kernel, and the `com.urunc.vmi.*`
annotations that tie them together.

## How generic-boot is built

The two parts a generic boot needs, the runtime and the assets, are both produced
by `build-bundle.sh` and packed into the tarball. The installer just unpacks them.

### The runtime is built, then packed

No urunc release publishes a binary that boots a generic container. So the build
compiles one, from `urunc-dev/urunc` at the commit `build-bundle.sh` pins
(`3c00b69`, on branch `feat/linux-hvi-v050`), in a
`golang:1.26.8` container:

```console
# docker run --rm -v <urunc>:/app -w /app -e HOME=/tmp golang:1.26.8 \
    sh -c "git config --global --add safe.directory /app && make static"
```

The static urunc binary is cgo, so it is built native to the target architecture
rather than cross-compiled. The release builds each arch on its own native runner
(amd64 on `ubuntu-24.04`, arm64 on `ubuntu-24.04-arm`), so no emulation is
involved; only a hand cross-build on one host falls back to qemu/binfmt. The
result, urunc and its shim, goes into the tarball. `install.sh` never builds; it
unpacks what the build produced.

### The kernel is fetched, the initrd is built for brig

The two files a generic boot names are the guest kernel and the initrd, and they
come from different places.

**The kernel** is fetched from hull-assets on both arches, the OCI artifact hull
and brig already boot from, one tag per platform, pulled with the bundled `oras`:

```
ghcr.io/nofireai/hull-assets:<version>-linux-<arch>   immutable
ghcr.io/nofireai/hull-assets:linux-<arch>             moving
```

The build resolves the `<version>` tag once. The bundled `cosign` checks the
signature on the digest it names, against the identity brig checks: the
`build-assets.yml` workflow in `NOFireAI/hull-assets`. The build then pulls that
digest. The artifact's layers are the files themselves, each named by its
`org.opencontainers.image.title`, so the kernel's sha256 is its layer digest in
the signed manifest.

The kernel is generic and not brig-specific. On arm64 it is the same file hull
boots on macOS. `pins.env` records it as `KERNEL_SOURCE`, by the digest the build
pulled. `share/guest/SHA256SUMS` holds the sha256 of the kernel and the initrd,
and each release publishes it as `<bundle>.boot-assets.sha256`: see the README.

**The initrd is not taken from hull-assets.** brig execs into a guest through the
exec agent in urunit, whose wire protocol (`pkg/agentproto`) is a contract with
the urunc shim. The two agree when urunit is the commit the shim's urunc pins in
`packaging/container-initrd/urunit.pin`, and hull-assets' prebuilt initrd may
carry another. So the build assembles a brig initrd, with urunc's
`packaging/container-initrd/build-container-initrd.sh`, from one binary:

- `/urunit`, built static from `NOFireAI/urunit` at the commit urunc pins. It is
  the early init (`/init` and `/vz-init` are links to it), the PID 1 supervisor
  and the exec agent.

urunc and the initrd ship in one tarball, built together, so their agent commit
matches by construction. The installer just fetches and unpacks the tarball; it
never builds an initrd.

**Two properties of the initrd are checked**, at build time and again when the
runtime boots it, because each fails in a way that does not name itself:

- `container-initrd` must not be compressed. The runtime appends the container's
  argv, environment and network identity to a copy of it, and concatenated cpio
  works only while both halves are uncompressed. A gzipped one accepts the append
  and boots without it.
- `urunit` must be built for this architecture. Under the wrong one the kernel
  cannot run init and panics.

The annotations that carry the pair are `com.urunc.unikernel.bootKernel` and
`com.urunc.unikernel.bootInitrd`, pointing into `share/guest/`. hull takes the
same pair on its command line on macOS, and urunc reads it out of the container's
OCI spec on Linux. That pair is the whole contract between brig and urunc.

## Why introspection is not a one-liner yet

Further off, for four reasons.

**The patches are not upstream.** Thirteen of them, kept locally under
`option-c-patches/urunc`, based on `bef4a2e` rather than `main`. Until they are
on a branch somewhere fetchable, there is nothing to build from. Upstream urunc
ignores annotations it does not recognise, so a stock binary given the Option-C
annotations boots nothing and reports no error worth reading.

**The artifacts are large.** The matrix consumes four products of one kernel
build, and they are not interchangeable:

| artifact | annotation | consumed by |
| --- | --- | --- |
| `arch/x86/boot/bzImage` | `com.urunc.vmi.boot_kernel` | hvi, qemu |
| `vmlinux.btf` | `com.urunc.vmi.boot_kernel` | firecracker, cloud-hypervisor |
| `vmlinux` (~392MB) | `com.urunc.vmi.kernel` | the symbol and BTF source |
| `vmlinux.BTF` | `com.urunc.vmi.btf` | hvi's in-VMM walk |

`boot_kernel` differs per monitor, an ELF for the loaders that want one and a
bzImage for the rest. And `vmlinux` at 392MB does not belong in a tarball that is
otherwise ~106MB, so these stay host inputs rather than becoming tarball content.

**The sidecar is a second binary with its own lifecycle.** The shim spawns and
reaps it per container. `build-bundle.sh` would install it as `bin/sidecar`;
where its build comes from is unsettled.

**hvi is a fifth monitor from a different repo.** The matrix scores hvi beside
firecracker, but hvi is released by `brig-sh/hvi-vmm`, not by the monitors
release the build draws from. `build-bundle.sh` fetches it as a second source.

## Running the matrix

`scripts/optc-matrix.sh` drives the introspection variant and scores what came
up. It checks the installed urunc for `com.urunc.vmi.boot_kernel` first and
refuses a stock binary, rather than printing a table of zeroes.

```console
# KBUILD=~/kbuild/linux-6.18.34-telem-builtin scripts/optc-matrix.sh
```

## Open questions

1. Does `generic-boot` ship as its own tarball, or as one tarball with the guest
   assets optional? A separate build keeps a stock tarball small.
2. Where do the Option-C patches live once they are pushed? A branch is enough to
   build from; upstream is better.
3. Settled: the guest kernel is fetched from `hull-assets`, by the same tags hull
   uses, and checked against its signature; the runtime is built from
   `urunc-dev/urunc` at a pinned commit
   (`3c00b69`, on `feat/linux-hvi-v050`); and the initrd is built for
   brig from `NOFireAI/urunit` at the commit that urunc pins, with urunc's own
   `packaging/container-initrd`, so its agent matches the shim. Both are
   commits because a branch tip moves with every push; the README's build
   section says how to move one.
4. Settled: `build-bundle.sh` fetches hvi from the `brig-sh/hvi-vmm` release
   hull ships on macOS (`v0.1.0-rc.1`). `scripts/fetch-hvi.sh` checks the
   cosign signature on its `SHA256SUMS`, the pinned sha256 of the tarball and
   the commit its manifest names.
5. Is `introspection` a variant at all, or `generic-boot` plus an opt-in flag?
   Everything it adds is additive, which argues for the flag.
