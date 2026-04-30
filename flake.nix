{
  description = "Nix flake for provisioning cloud VMs (nixos-anywhere + disko).";

  nixConfig = {
    extra-substituters = [ "https://classix.cachix.org" ];
    extra-trusted-public-keys = [
      "classix.cachix.org-1:wwRxPZ1+4aY6IWpf+7xBxoc0MBrYQB9GsSNSKwLzqBo="
    ];
  };

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

    # Upstream Safe self-hosting orchestration (docker-compose, env files,
    # internal nginx config). We `docker compose up -d` against this verbatim
    # rather than re-implement the topology in Nix.
    safe-infrastructure = {
      url = "github:safe-global/safe-infrastructure";
      flake = false;
    };

    # Safe wallet web frontend — pinned to the same release tag as the
    # docker image (web-v1.88.0). Built statically (next export) by
    # `pkgs/safe-wallet-web` and served directly from the host nginx.
    safe-wallet-web = {
      url = "github:safe-global/safe-wallet-monorepo/web-v1.88.0";
      flake = false;
    };
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
        {
          config,
          lib,
          pkgs,
          ...
        }:
        {
          treefmt = {
            projectRootFile = "flake.nix";
            programs = {
              nixfmt.enable = true;
              statix.enable = true;
              deadnix.enable = true;
            };
          };

          # `nix build .#safe-wallet-web-static` — produces the static
          # `out/` directory served by the host nginx. Built with default
          # branding here; per-deploy values (domain, chain, appName) are
          # injected at module evaluation time via `pkgs.callPackage`
          # in `hosts/catacomb/ui.nix`.
          packages.safe-wallet-web-static = pkgs.callPackage ./pkgs/safe-wallet-web {
            src = inputs.safe-wallet-web;
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

          # `nix run .#lint` — runs the same toolchain as `nix fmt` but in
          # CI / fail-on-change mode. Equivalent to `nix flake check` for
          # this repo's purposes; useful as a single-command pre-push gate.
          # NOTE: treefmt does write fixes to disk in this mode (the
          # convention for treefmt-managed projects); commit them or revert.
          apps.lint = {
            type = "app";
            program = lib.getExe (
              pkgs.writeShellApplication {
                name = "lint";
                text = ''
                  set -eu
                  ${lib.getExe config.treefmt.build.wrapper} --fail-on-change
                  echo "✓ lint passed"
                '';
              }
            );
          };
        };

      flake = {
        # Idiomatic consumption: import these in your own flake's
        # nixosConfigurations alongside `disko.nixosModules.disko`, then set
        # `catacomb.*` options. See `local/flake.nix.example` for a worked
        # example.
        nixosModules =
          let
            mkCatacomb =
              { ... }:
              {
                imports = [ ./hosts/catacomb ];
                _module.args = {
                  inherit (inputs) safe-infrastructure;
                  inherit (inputs) safe-wallet-web;
                };
              };
          in
          {
            catacomb = mkCatacomb;
            default = mkCatacomb;
          };
      };
    };
}
