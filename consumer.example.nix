# Worked example consumer flake — copy somewhere private, edit the values
# at the top, lock, and deploy.
#
#   mkdir my-catacomb && cd my-catacomb
#   cp /path/to/nix-catacomb/consumer.example.nix flake.nix
#   $EDITOR flake.nix                # set domain, acmeEmail, sshAuthorizedKeys, chains
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
# nix-catacomb is library-only and ships almost no defaults — every
# required `catacomb.*` option must be set explicitly here. Options
# without a `default = ...` in `hosts/catacomb/options.nix` are
# required; the rest fall back to library defaults.
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
      hostName = "my-safe";

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

                catacomb = {
                  inherit
                    domain
                    acmeEmail
                    timeZone
                    hostName
                    sshAuthorizedKeys
                    ;

                  bootDevice = "/dev/vda";
                  tlsEnabled = true;

                  # ── Branding ────────────────────────────────────────
                  # `appName` defaults to "Safe Wallet" (vanilla). Theme
                  # colours have no library default and must be set —
                  # they're surfaced via cfg-service to clients on every
                  # chain.
                  branding = {
                    appName = "Acme Multi-Sig";

                    theme = {
                      textColor = "#ffffff";
                      backgroundColor = "#000000";
                    };

                    # Drop a self-contained branding pack here for
                    # source-tree overlays (custom React patches +
                    # assets + env vars). Typical shape: a
                    # `./branding/default.nix` that returns
                    # `{ patches; postPatch; extraEnv; }`.
                    #
                    # pack = import ./branding { };
                  };

                  # ── Chains (required) ──────────────────────────────
                  # Declare each chain you want registered with
                  # cfg-service. The primary chain is also wired into
                  # the bundled `txs` indexer and the wallet bundle.
                  primaryChain = "etc";
                  chains.etc = {
                    chainId    = 61;
                    shortName  = "etc";
                    chainName  = "Ethereum Classic";
                    isTestnet  = false;
                    rpcUri     = "https://my-private-etc-node.example.com";
                    transactionService = "https://${domain}/txs";
                    blockExplorerUriTemplate = {
                      address = "https://blockscout.com/etc/mainnet/address/{{address}}";
                      txHash  = "https://blockscout.com/etc/mainnet/tx/{{txHash}}";
                      api     = "https://blockscout.com/etc/mainnet/api?module={{module}}&action={{action}}&address={{address}}&apiKey={{apiKey}}";
                    };
                    nativeCurrency = {
                      name    = "Ether Classic";
                      symbol  = "ETC";
                      decimals = 18;
                      logoUri = "https://${domain}/assets/etc-logo.svg";
                    };
                    chainLogoUri = "https://${domain}/assets/etc-logo.svg";
                  };

                  # Directory served at `/assets/`. Use it for any chain
                  # logo referenced from a chain config above. Optional.
                  # staticAssets = ./assets;

                  # ── Optional: cfg-service service keys ─────────────
                  # Default `[ "WALLET_WEB" ]`. Add "MOBILE" if you also
                  # serve a mobile app pointing at this gateway.
                  # services = [ "WALLET_WEB" "MOBILE" ];
                };

                # ── Chain-RPC plumbing (consumer responsibility) ────────
                # If your chain's public RPC doesn't return CORS headers
                # (most don't), the wallet's browser-side fetches will
                # fail preflight. A common pattern is to terminate a
                # `rpc.<domain>` virtualhost on this host and proxy to
                # the upstream with permissive CORS. Set
                # `chains.<name>.rpcUri = "https://rpc.${domain}"`
                # above and add the proxy below.
                #
                # services.nginx.virtualHosts."rpc.${domain}" = {
                #   forceSSL = true;
                #   enableACME = true;
                #   locations."/".extraConfig = ''
                #     proxy_pass https://upstream-rpc.example.com;
                #     proxy_ssl_server_name on;
                #     proxy_set_header Host upstream-rpc.example.com;
                #     # CORS preflight + permissive responses
                #     if ($request_method = OPTIONS) {
                #       add_header Access-Control-Allow-Origin  "*" always;
                #       add_header Access-Control-Allow-Methods "POST, GET, OPTIONS" always;
                #       add_header Access-Control-Allow-Headers "Content-Type, Authorization" always;
                #       return 204;
                #     }
                #     add_header Access-Control-Allow-Origin "*" always;
                #   '';
                # };
              };
            }
          )
        ];
      };
    };
}
