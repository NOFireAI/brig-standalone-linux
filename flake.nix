{
  description = "Brig and the Linux microVM runtime it drives";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";

  outputs =
    { self, nixpkgs }:
    let
      systems = [
        "x86_64-linux"
        "aarch64-linux"
      ];
      forAll = f: nixpkgs.lib.genAttrs systems (system: f nixpkgs.legacyPackages.${system});
    in
    {
      packages = forAll (
        pkgs:
        let
          brig = pkgs.callPackage ./nix/brig.nix { };
          urunc = pkgs.callPackage ./nix/urunc.nix { };
          brig-guest = pkgs.callPackage ./nix/guest.nix { };
          brig-runtime = pkgs.callPackage ./nix/runtime.nix { inherit brig urunc brig-guest; };
        in
        {
          inherit
            brig
            urunc
            brig-guest
            brig-runtime
            ;
          default = brig-runtime;
        }
      );

      nixosModules.default = import ./nix/module.nix;

      # A NixOS machine with the module on, for a run with network:
      # nix build .#nixosConfigurations.demo.config.system.build.vm
      # then ./result/bin/run-demo-vm. The VM test under checks has no
      # network, so this is where a sandbox boots on a NixOS host.
      nixosConfigurations.demo = nixpkgs.lib.nixosSystem {
        system = "x86_64-linux";
        modules = [
          self.nixosModules.default
          (
            { pkgs, ... }:
            {
              services.brig.enable = true;
              services.brig.package = self.packages.x86_64-linux.brig-runtime;
              virtualisation.vmVariant.virtualisation = {
                memorySize = 4096;
                cores = 2;
                diskSize = 8192;
                graphics = false;
                forwardPorts = [
                  {
                    from = "host";
                    host.port = 2222;
                    guest.port = 22;
                  }
                ];
              };
              services.openssh.enable = true;
              services.openssh.settings.PermitRootLogin = "yes";
              users.users.root.initialPassword = "demo";
              system.stateVersion = "25.11";
            }
          )
        ];
      };

      checks = forAll (
        pkgs:
        let
          brig-runtime = self.packages.${pkgs.stdenv.hostPlatform.system}.brig-runtime;
        in
        {
          module = pkgs.callPackage ./nix/test.nix {
            module = self.nixosModules.default;
            inherit brig-runtime;
          };
        }
      );
    };
}
