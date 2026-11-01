{
  lib,
  stdenv,
  runCommand,
  makeWrapper,
  brig,
  urunc,
  brig-guest,
  containerd,
  nerdctl,
  cni-plugins,
  iptables,
  nftables,
  util-linux,
  cosign,
  oras,
}:

# The Linux runtime around brig: containerd with the urunc shim, the CNI
# bridge, the monitors and the guest assets, wired the way the runtime bundle
# wires them. State lives under /var/lib/brig/agent and the socket under
# /run/brig, so a host that had the bundle and one that has this package
# look the same to brig. Only root drives this stack; there is no rootless
# path here.
let
  stateDir = "/var/lib/brig/agent";
  runDir = "/run/brig";
  sock = "${runDir}/containerd.sock";
  goarch = if stdenv.hostPlatform.isAarch64 then "arm64" else "amd64";

  etc = runCommand "brig-runtime-etc" { } ''
    mkdir -p $out/etc/cni/net.d $out/etc/certs.d

    cat > $out/etc/containerd.toml <<EOF
    version = 3
    root = '${stateDir}/containerd'
    state = '${runDir}/containerd'
    temp = '${runDir}/tmp'
    disabled_plugins = ['io.containerd.cri.v1.runtime', 'io.containerd.cri.v1.images', 'io.containerd.grpc.v1.cri']

    [grpc]
      address = '${sock}'

    [debug]
      address = '${runDir}/debug.sock'
      level = 'info'

    [metrics]
      address = ""

    [[plugins.'io.containerd.transfer.v1.local'.unpack_config]]
      platform = 'linux/${goarch}'
      snapshotter = 'overlayfs'
    EOF

    cat > $out/etc/nerdctl.toml <<EOF
    debug = false
    address = "unix://${sock}"
    namespace = "brig"
    snapshotter = "overlayfs"
    cni_path = "${cni-plugins}/bin"
    cni_netconfpath = "$out/etc/cni/net.d"
    data_root = "${stateDir}/nerdctl"
    cgroup_manager = "systemd"
    hosts_dir = ["$out/etc/certs.d"]
    EOF

    # brig asks urunc for hvi on Linux. cloud-hypervisor stays declared for a
    # run that names it. urunc.toml names each monitor by path, so
    # containerd's PATH does not matter for them.
    cat > $out/etc/urunc.toml <<EOF
    [log]
    level = "info"
    syslog = false

    [timestamps]
    enabled = false
    destination = "${stateDir}/log/timestamps.log"

    [monitors.hvi]
    default_memory_mb = 256
    default_vcpus = 1
    path = "${brig-guest}/bin/hvi"

    [monitors.cloud-hypervisor]
    default_memory_mb = 256
    default_vcpus = 1
    path = "${brig-guest}/bin/cloud-hypervisor"

    [extra_binaries.virtiofsd]
    path = "${brig-guest}/bin/virtiofsd"
    options = "--cache always --sandbox none"
    EOF

    cat > $out/etc/cni/net.d/10-brig-bridge.conflist <<EOF
    {
      "cniVersion": "1.0.0",
      "name": "bridge",
      "nerdctlID": "brig-standalone",
      "nerdctlLabels": {},
      "plugins": [
        {
          "type": "bridge",
          "bridge": "brig0",
          "isGateway": true,
          "ipMasq": true,
          "hairpinMode": true,
          "ipam": {
            "type": "host-local",
            "ranges": [[{"subnet": "10.44.0.0/24", "gateway": "10.44.0.1"}]],
            "routes": [{"dst": "0.0.0.0/0"}]
          }
        },
        {"type": "portmap", "capabilities": {"portMappings": true}},
        {"type": "firewall", "ingressPolicy": "same-bridge"},
        {"type": "tuning"}
      ]
    }
    EOF
  '';

  # What nerdctl runs on the client side: the CNI plugins call iptables, and
  # brig enforces an egress policy with nft and nsenter.
  clientPath = lib.makeBinPath [
    nerdctl
    urunc
    iptables
    nftables
    util-linux
    cosign
    oras
  ];

  # containerd finds the shim on its own PATH.
  daemonPath = lib.makeBinPath [
    containerd
    urunc
    iptables
    util-linux
  ];
in
runCommand "brig-runtime"
  {
    nativeBuildInputs = [ makeWrapper ];
    passthru = {
      inherit
        etc
        brig
        urunc
        brig-guest
        ;
    };
    meta = {
      description = "Brig with the Linux microVM runtime it drives";
      mainProgram = "brig";
      platforms = [
        "x86_64-linux"
        "aarch64-linux"
      ];
    };
  }
  ''
    mkdir -p $out/bin $out/lib/systemd/system

    # The same values etc/brig-env.sh sets in the bundle. Each one defers to
    # the environment, so a caller can point one knob elsewhere.
    for p in brig brigd; do
      makeWrapper ${brig}/bin/$p $out/bin/$p \
        --set-default CONTAINERD_ADDRESS "unix://${sock}" \
        --set-default CONTAINERD_NAMESPACE brig \
        --set-default CONTAINERD_SNAPSHOTTER overlayfs \
        --set-default NERDCTL_TOML "${etc}/etc/nerdctl.toml" \
        --set-default CNI_PATH "${cni-plugins}/bin" \
        --set-default BRIG_RUNTIME nerdctl \
        --set-default BRIG_RUNTIME_BIN "${nerdctl}/bin/nerdctl" \
        --set-default BRIG_BOOT_ASSETS "${brig-guest}/share/guest" \
        --prefix PATH : "${clientPath}"
    done
    ln -s ${brig}/bin/brig-broker $out/bin/brig-broker
    ln -s ${nerdctl}/bin/nerdctl $out/bin/nerdctl

    cat > $out/bin/brig-containerd <<EOF
    #!${stdenv.shell}
    # The containerd brig drives. Run as root.
    set -eu
    mkdir -p ${runDir} ${stateDir}/log
    chmod 0710 ${runDir}
    export PATH="${daemonPath}:\$PATH"
    export URUNC_CONFIG_FILE="${etc}/etc/urunc.toml"
    exec ${containerd}/bin/containerd --config ${etc}/etc/containerd.toml "\$@"
    EOF
    chmod +x $out/bin/brig-containerd

    cat > $out/lib/systemd/system/brig-containerd.service <<EOF
    [Unit]
    Description=brig containerd
    Documentation=https://github.com/brig-sh/brig
    After=network.target local-fs.target

    [Service]
    Type=notify
    Delegate=yes
    KillMode=process
    Restart=always
    RestartSec=5
    ExecStart=$out/bin/brig-containerd
    LimitNPROC=infinity
    LimitCORE=infinity
    TasksMax=infinity
    OOMScoreAdjust=-999

    [Install]
    WantedBy=multi-user.target
    EOF

    # Shell completion from the brig package.
    ln -s ${brig}/share $out/share
  ''
