{
  lib,
  buildGoModule,
  fetchFromGitHub,
}:

# urunc and its containerd shim, from the branch the Linux runtime bundle
# builds (feat/linux-hvi-v050). No urunc release reads the boot annotations
# Brig sets or knows the hvi monitor, so a release is not an option yet. The
# commit is the one the bundle release records in its pins.env as URUNC_REF.
buildGoModule (finalAttrs: {
  pname = "urunc";
  version = "0-unstable-2026-10-29";

  src = fetchFromGitHub {
    owner = "urunc-dev";
    repo = "urunc";
    rev = "3c00b69ff9ac1b8bb260975cdc63d18a7043558b";
    hash = "sha256-NbH+6nQWLEgcI2VBmtA/50EHbMB8Q1k4RJk67miYXtU=";
  };

  vendorHash = "sha256-08PC8ethomYCZTBfP1PVCCXgXeyrSHHoozcVsWmqJUE=";

  subPackages = [
    "cmd/urunc"
    "cmd/containerd-shim-urunc-v2"
  ];

  # libcontainer's nsenter is C, so the urunc binary needs cgo. The shim
  # does not, but one derivation builds both.
  env.CGO_ENABLED = 1;
  tags = [
    "netgo"
    "osusergo"
  ];

  ldflags = [
    "-s"
    "-w"
    "-X main.version=${finalAttrs.version}"
  ];

  # The shim execs the OCI runtime that go-runc names, and the upstream
  # Makefile seds that name from runc to urunc in the vendored source before
  # it builds. go-runc v1.0.0 declares it as a const, so a linker flag cannot
  # set it. The vendor directory is a copy by this point, with the store's
  # read-only permissions.
  postConfigure = ''
    f=vendor/github.com/containerd/go-runc/runc.go
    chmod u+w "$(dirname $f)" $f
    grep -q 'DefaultCommand = "runc"' $f
    sed -i 's/DefaultCommand = "runc"/DefaultCommand = "urunc"/' $f
  '';

  # The tests want KVM and a monitor.
  doCheck = false;

  meta = {
    description = "Container runtime that boots the container as a microVM";
    homepage = "https://github.com/urunc-dev/urunc";
    license = lib.licenses.asl20;
    platforms = lib.platforms.linux;
  };
})
