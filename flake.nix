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

      checks = forAll (
        pkgs:
        let
          brig-runtime = self.packages.${pkgs.system}.brig-runtime;
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
