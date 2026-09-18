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
compiles one, from `urunc-dev/urunc` at branch `feat/unchanged_containers`, in a
`golang:1.26.4` container:

```console
# docker run --rm -v <urunc>:/app -w /app -e HOME=/tmp golang:1.26.4 \
    sh -c "git config --global --add safe.directory /app && make static"
```

The static urunc binary is cgo, so the build is native to the target architecture
rather than cross-compiled — the arm64 build runs under qemu/binfmt. The result,
urunc and its shim, goes into the tarball. `install.sh` never builds; it unpacks
what the build produced.

### The kernel comes from hull-assets, the initrd is built for brig

The two files a generic boot names are the guest kernel and the initrd, and they
come from different places.

**The kernel** comes from hull-assets, the OCI artifact hull and brig already
use, one tag per platform:

```
ghcr.io/nofireai/hull-assets:<version>-linux-<arch>   immutable
ghcr.io/nofireai/hull-assets:linux-<arch>             moving
```

The artifact's layers are the files themselves, each named by its
`org.opencontainers.image.title`. `build-bundle.sh` pulls the kernel out of it
with the bundled `oras`. The kernel is generic and not brig-specific.

**The initrd is not taken from hull-assets.** brig execs into a guest through an
in-guest agent, `urunit-agent`, whose wire protocol (`pkg/agentproto`) is a
contract with the urunc shim. The two agree only when both are built from the same
urunc commit, and hull-assets' prebuilt initrd carries hull's agent. So the build
assembles a brig initrd, with urunc's
`packaging/container-initrd/build-container-initrd.sh`, from four pieces:

- `container-init`, urunc's early-userspace script (mounts the shared rootfs,
  stages urunit and the agent, `switch_root`s into urunit);
- `urunit`, the tiny C init that becomes PID 1, built static from
  `NOFireAI/urunit` at branch `urunit_agent`;
- `urunit-agent`, built from the **same** urunc commit that produced the shim,
  so the protocol matches by construction;
- a static `busybox`.

urunc and the initrd ship in one tarball, built together, so their agent commit
matches by construction. The installer just fetches and unpacks the tarball; it
never builds an initrd.

**Two properties of the initrd are checked**, at build time and again when the
runtime boots it, because each fails in a way that does not name itself:

- `container-initrd` must not be compressed. The runtime appends the container's
  argv, environment and network identity to a copy of it, and concatenated cpio
  works only while both halves are uncompressed. A gzipped one accepts the append
  and boots without it.
- `busybox` must be built for this architecture. Under the wrong one it exits 127
  on every applet and panics init on the first line.

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
firecracker, but hvi is built in `brig-sh/hvi-vmm`, not in the monitors release
the build draws from. Adding it means either a second source in `build-bundle.sh`
or getting hvi into `monitors-build`.

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
3. Settled: the guest kernel comes from `hull-assets` by the same tags hull uses;
   the runtime is built from `urunc-dev/urunc` at `feat/unchanged_containers`; and
   the initrd is built for brig from `NOFireAI/urunit` at `urunit_agent` plus
   urunc's own `packaging/container-initrd`, so its agent matches the shim.
4. Does hvi join `monitors-build`, or does `build-bundle.sh` learn a second
   source?
5. Is `introspection` a variant at all, or `generic-boot` plus an opt-in flag?
   Everything it adds is additive, which argues for the flag.
