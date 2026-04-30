{
  description = "Nix flake for provisioning cloud VMs (nixos-anywhere + disko).";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

    flake-parts.url = "github:hercules-ci/flake-parts";
    flake-parts.inputs.nixpkgs-lib.follows = "nixpkgs";

    nixos-anywhere.url = "github:nix-community/nixos-anywhere";
    nixos-anywhere.inputs.nixpkgs.follows = "nixpkgs";

    disko.url = "github:nix-community/disko";
    disko.inputs.nixpkgs.follows = "nixpkgs";

    treefmt-nix.url = "github:numtide/treefmt-nix";
    treefmt-nix.inputs.nixpkgs.follows = "nixpkgs";

    # TODO(safe-wallet): pin upstream SafeWallet monorepo here once URL is confirmed.
    # safe-wallet.url = "github:<owner>/<safe-wallet-monorepo>";
    # safe-wallet.flake = false;
  };

  outputs =
    inputs@{ flake-parts, ... }:
    flake-parts.lib.mkFlake { inherit inputs; } {
      systems = [
        "x86_64-linux"
        "aarch64-linux"
      ];

      imports = [ inputs.treefmt-nix.flakeModule ];

      perSystem =
        { config, pkgs, ... }:
        {
          treefmt = {
            projectRootFile = "flake.nix";
            programs = {
              nixfmt.enable = true;
              statix.enable = true;
              deadnix.enable = true;
            };
          };

          checks = {
            inherit (config.treefmt.build) wrapper;
            statix =
              pkgs.runCommand "statix-check"
                {
                  nativeBuildInputs = [ pkgs.statix ];
                }
                ''
                  cd ${./.}
                  statix check .
                  touch $out
                '';
            deadnix =
              pkgs.runCommand "deadnix-check"
                {
                  nativeBuildInputs = [ pkgs.deadnix ];
                }
                ''
                  cd ${./.}
                  deadnix --fail .
                  touch $out
                '';
          };

          devShells.default = pkgs.mkShell {
            packages = with pkgs; [
              nixos-anywhere
              inputs.disko.packages.${pkgs.system}.disko
              nixfmt
              statix
              deadnix
            ];
          };
        };

      flake = {
        nixosConfigurations.catacomb = inputs.nixpkgs.lib.nixosSystem {
          system = "x86_64-linux";
          specialArgs = { inherit inputs; };
          modules = [
            inputs.disko.nixosModules.disko
            ./hosts/catacomb/configuration.nix
          ];
        };
      };
    };
}
