# Worked example consumer flake — copy somewhere private, edit the values
# at the top, lock, and deploy.
#
#   mkdir my-catacomb && cd my-catacomb
#   cp /path/to/nix-catacomb/consumer.example.nix flake.nix
#   $EDITOR flake.nix                # set domain, acmeEmail, sshAuthorizedKeys
#   nix flake lock
#
# Then provision a fresh VM (Debian/Ubuntu, our SSH key preinstalled,
# DNS A records pointing at it for both apex and `*.<domain>`) and:
#
#   nix run github:nix-community/nixos-anywhere -- \
#     --flake .#catacomb \
#     --target-host root@<vm-ip>
#
# Subsequent rebuilds:
#
#   nixos-rebuild switch --flake .#catacomb --target-host root@<vm-ip>
#
# Only the per-deploy identity at the top of `let` and a few NixOS-level
# overrides for the chosen cloud provider live here. Everything else
# (Catacomb branding, ETC chain config, RPC CORS proxy, cfg-service URL
# rewrite) is inherited from the library's `hosts/catacomb/defaultConfig.nix`.
{
  description = "My Catacomb deploy";

  inputs = {
    nix-catacomb.url = "github:classix-dev/nix-catacomb";
    nixpkgs.follows = "nix-catacomb/nixpkgs";
    disko.follows = "nix-catacomb/disko";
  };

  outputs =
    {
      nixpkgs,
      disko,
      nix-catacomb,
      ...
    }:
    let
      system = "x86_64-linux";

      # ── Per-deploy identity ────────────────────────────────────────────
      domain = "your.example.com";
      acmeEmail = "ops@your.example.com";
      timeZone = "UTC";

      # SSH key(s) that may log in to root post-install. NixOS replaces
      # whatever the cloud-init bootstrap put in /root/.ssh/authorized_keys
      # with exactly this list. Add your operator's pubkey before the
      # first deploy or you'll lock yourself out.
      sshAuthorizedKeys = [
        # "ssh-ed25519 AAAA... operator@laptop"
      ];
    in
    {
      nixosConfigurations.catacomb = nixpkgs.lib.nixosSystem {
        inherit system;
        modules = [
          disko.nixosModules.disko
          nix-catacomb.nixosModules.catacomb
          (
            { lib, modulesPath, ... }:
            {
              # ── Cloud-provider bootstrap (DigitalOcean shown) ───────────
              # Adjust if you're not on DO. The two `lib.mkForce` lines
              # below override defaults that `digital-ocean-config.nix`
              # sets and that collide with our disko layout. `cloud-init`
              # is needed because DO assigns the public IP via metadata,
              # NOT DHCP — without it, sshd is up but no IPv4 → all ports
              # time out.
              imports = [
                "${modulesPath}/profiles/qemu-guest.nix"
                "${modulesPath}/virtualisation/digital-ocean-config.nix"
              ];

              config = {
                fileSystems."/" = lib.mkForce {
                  device = "/dev/disk/by-partlabel/disk-main-root";
                  fsType = "ext4";
                };
                boot.loader.grub.devices = lib.mkForce [ "/dev/vda" ];

                networking.useDHCP = lib.mkForce false;
                services.cloud-init = {
                  enable = true;
                  network.enable = true;
                  settings.datasource_list = [
                    "ConfigDrive"
                    "DigitalOcean"
                  ];
                };

                # ── Catacomb options ───────────────────────────────────
                # Required: domain, acmeEmail, sshAuthorizedKeys, timeZone.
                # Everything else inherits from
                # `nix-catacomb/hosts/catacomb/defaultConfig.nix` —
                # uncomment any of the optional blocks below to override.
                catacomb = {
                  inherit
                    domain
                    acmeEmail
                    timeZone
                    sshAuthorizedKeys
                    ;

                  # ── Branding ────────────────────────────────────────
                  # Library defaults render the canonical Catacomb look
                  # (Classix-flavored: green accent, Michroma + Space
                  # Grotesk wordmark, classix.dev footer link). Override
                  # any subset to brand your deploy. Drop a key entirely
                  # to inherit the library default.
                  branding = {
                    appName = "Acme Multi-Sig";
                    tagline = "operator preview";
                    githubRepoLink = "https://github.com/your-org/your-fork";
                    footerLinks = [
                      {
                        label = "ops.acme.com";
                        url = "https://ops.acme.com";
                      }
                    ];
                    theme = {
                      textColor = "#ffffff";
                      backgroundColor = "#000000";
                    };

                    # Top-of-page modal shown once per browser session.
                    # Empty string (default) hides it entirely. Useful
                    # for demo / staging deploys.
                    notification = "Demo deploy — do not use with production assets.";

                    # SVG used as the wallet's favicon. Defaults to the
                    # library's ETC chain logo. Point at a path in your
                    # consumer flake to override:
                    # faviconSvg = ./my-favicon.svg;

                    # Disable the whole branding overlay (ship vanilla
                    # Safe with only `appName` swapped via the
                    # upstream-supported NEXT_PUBLIC_BRAND_NAME):
                    # enable = false;
                  };

                  # ── Optional: chains ───────────────────────────────
                  # Library default is Ethereum Classic mainnet (61),
                  # routed through a local CORS-injecting proxy at
                  # rpc.<domain>. To use a different chain, replace the
                  # whole `chains` attribute. Note that adding a chain
                  # also requires a parallel `txs` indexer per chain —
                  # the bundled compose project indexes one.
                  #
                  # chains.etc = {
                  #   chainId    = 61;
                  #   shortName  = "etc";
                  #   chainName  = "Ethereum Classic";
                  #   isTestnet  = false;
                  #   rpcUri     = "https://my-private-etc-node.example.com";
                  #   transactionService = "https://${domain}/txs";
                  #   blockExplorerUriTemplate = {
                  #     address = "https://blockscout.com/etc/mainnet/address/{{address}}";
                  #     txHash  = "https://blockscout.com/etc/mainnet/tx/{{txHash}}";
                  #     api     = "https://blockscout.com/etc/mainnet/api?module={{module}}&action={{action}}&address={{address}}&apiKey={{apiKey}}";
                  #   };
                  #   nativeCurrency = {
                  #     name    = "Ether Classic";
                  #     symbol  = "ETC";
                  #     decimals = 18;
                  #     logoUri = "https://${domain}/assets/etc-logo.svg";
                  #   };
                  #   chainLogoUri = "https://${domain}/assets/etc-logo.svg";
                  # };

                  # ── Optional: cfg-service service keys ─────────────
                  # Default `[ "WALLET_WEB" ]`. Add "MOBILE" if you also
                  # serve a mobile app pointing at this gateway.
                  # services = [ "WALLET_WEB" "MOBILE" ];
                };
              };
            }
          )
        ];
      };
    };
}
