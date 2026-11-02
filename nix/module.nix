# NixOS module: services.brig. Runs the containerd that brig drives, loads
# the kernel modules a sandbox needs and puts brig on PATH. The same layout
# as the bundle's node-wide install, so a host that had the bundle and one
# that has this module look the same to brig. Only root drives the stack.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.services.brig;
in
{
  options.services.brig = {
    enable = lib.mkEnableOption "the brig sandbox runtime";

    package = lib.mkOption {
      type = lib.types.package;
      description = "The brig-runtime package to run and install.";
    };
  };

  config = lib.mkIf cfg.enable {
    environment.systemPackages = [ cfg.package ];

    boot.kernelModules = [
      "kvm"
      "vhost_vsock"
    ];

    # containerd's state and the socket directory, created before the unit
    # starts. brig-containerd creates them too; this keeps them across the
    # unit's absence.
    systemd.tmpfiles.rules = [
      "d /var/lib/brig/agent 0755 root root -"
      "d /run/brig 0710 root root -"
    ];

    # The unit comes from the package, so this module and a host that copies
    # the file by hand run the same definition. NixOS ignores [Install] in a
    # packaged unit, so the target is named here.
    systemd.packages = [ cfg.package ];
    systemd.services.brig-containerd.wantedBy = [ "multi-user.target" ];
  };
}
