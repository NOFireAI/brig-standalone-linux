# NixOS VM test of the module. The test VM has no network, so no image can
# be pulled and no sandbox boots here. What it checks: the unit comes up,
# the socket appears, and `brig doctor` finds the runtime and the boot
# assets on a host built from the module alone.
{
  testers,
  module,
  brig-runtime,
}:
testers.nixosTest {
  name = "brig-runtime";

  nodes.machine = {
    imports = [ module ];
    services.brig = {
      enable = true;
      package = brig-runtime;
    };
    virtualisation.memorySize = 2048;
    virtualisation.diskSize = 4096;
  };

  testScript = ''
    machine.wait_for_unit("brig-containerd.service")
    machine.wait_for_file("/run/brig/containerd.sock")
    machine.succeed("test -c /dev/vhost-vsock")
    out = machine.succeed("brig doctor || true")
    print(out)
    assert "ok  runtime" in out, "doctor did not find nerdctl"
    assert "ok  boot" in out, "doctor did not find the boot assets"
    assert "ok  rootfs" in out, "doctor found no overlay root"
    machine.succeed("brig version | grep -q 0.5.0")
  '';
}
