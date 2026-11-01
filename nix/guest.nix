{
  lib,
  stdenvNoCC,
  fetchurl,
}:

# The guest kernel, the container-initrd and the monitors, taken from the
# Linux runtime bundle release. The kernel is built by hull-assets, whose
# repository is not public, the initrd is assembled by scripts/build-bundle.sh
# from urunit and busybox, and hvi is a static binary from brig-sh/hull. Until
# those build here, the bundle tarball is the source, pinned by the sha256 its
# signed checksums.txt lists.
#
# virtiofsd and cloud-hypervisor come from the same tarball although nixpkgs
# has both: urunc pivots into a monitor rootfs of its own before it spawns
# them, and a dynamically linked binary cannot find its interpreter in there.
# The bundle's builds are static.
#
# brig checks the kernel and initrd against share/guest/SHA256SUMS, and that
# file against the release's checksums.txt, whose cosign signature and
# certificate sit beside it, the way the bundle's installer leaves them.
let
  version = "0.1.0-rc21";
  base = "https://github.com/NOFireAI/brig-standalone-linux/releases/download/v${version}";
  release =
    name: hash:
    fetchurl {
      url = "${base}/${name}";
      sha256 = hash;
    };
  checksums = release "checksums.txt" "441bc9aaded057ed301b9e7bec265c4d75d2c418f32fc75a45dd841736ce67fa";
  signature = release "checksums.txt.sig" "bcfb6a50348c2f3a760419c5e2ad290bbe816ee57f77c2653543d7c1b1e83dc6";
  certificate = release "checksums.txt.pem" "d2cd0ff6918724d50dbe22d915a3dd9ee5cd3b26a26d4b0d52cdbf950bf84744";
  arch =
    stdenvNoCC.hostPlatform.go.GOARCH
      or (if stdenvNoCC.hostPlatform.isAarch64 then "arm64" else "amd64");
  hashes = {
    amd64 = "3a376bb1da931c876d512643a205fd6ccefc6a8f6f696bdc6c548a477ef3205f";
    arm64 = "bcf280444a78adca58c5e89336edc6c55893f3da6416bc9bc2a103ad0e4c9b36";
  };
in
stdenvNoCC.mkDerivation {
  pname = "brig-guest";
  inherit version;

  src = fetchurl {
    url = "${base}/brig-standalone-v${version}-linux-${arch}.tar.gz";
    sha256 = hashes.${arch};
  };

  dontBuild = true;
  dontFixup = true;

  installPhase = ''
    runHook preInstall
    mkdir -p $out/share $out/bin
    cp -r share/guest $out/share/guest
    cp ${checksums} $out/share/guest/checksums.txt
    cp ${signature} $out/share/guest/checksums.txt.sig
    cp ${certificate} $out/share/guest/checksums.txt.pem
    install -m 0755 bin/hvi bin/cloud-hypervisor $out/bin/
    install -m 0755 libexec/virtiofsd $out/bin/virtiofsd
    runHook postInstall
  '';

  meta = {
    description = "Guest kernel, initrd and monitors for Brig sandboxes on Linux";
    homepage = "https://github.com/NOFireAI/brig-standalone-linux";
    sourceProvenance = [ lib.sourceTypes.binaryNativeCode ];
    license = lib.licenses.asl20;
    platforms = [
      "x86_64-linux"
      "aarch64-linux"
    ];
  };
}
