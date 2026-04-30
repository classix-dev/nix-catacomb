# Declares every option exposed by this host. No values set here — defaults
# live in `defaultConfig.nix`, per-deploy overrides in `config.nix`.
{ lib, ... }:
{
  options.catacomb = with lib; {

    # ── Per-deploy identity ──────────────────────────────────────────────
    domain = mkOption {
      type = types.str;
      example = "catacomb.example.com";
      description = ''
        Apex hostname. The UI is served here. Client gateway and per-chain
        transaction services live under `client.`, `transaction-classic.`,
        `transaction-mordor.` subdomains.
      '';
    };

    hostName = mkOption {
      type = types.str;
      example = "catacomb";
      description = "NixOS hostname.";
    };

    timeZone = mkOption {
      type = types.str;
      example = "Europe/Berlin";
      description = "Host timezone (IANA name).";
    };

    acmeEmail = mkOption {
      type = types.str;
      example = "ops@example.com";
      description = "Contact email registered with Let's Encrypt for ACME certs.";
    };

    sshAuthorizedKeys = mkOption {
      type = types.listOf types.str;
      example = [ "ssh-ed25519 AAAA... operator@laptop" ];
      description = "SSH public keys authorised for root login.";
    };

    bootDevice = mkOption {
      type = types.str;
      example = "/dev/vda";
      description = "Block device for GRUB BIOS install (most cloud VMs are /dev/vda).";
    };

    tlsEnabled = mkOption {
      type = types.bool;
      example = true;
      description = ''
        Issue Let's Encrypt certs via ACME. DNS for `domain` and its
        subdomains must point at this host before the first rebuild.
      '';
    };

    # ── Branding ─────────────────────────────────────────────────────────
    branding = {
      appName = mkOption {
        type = types.str;
        example = "Acme Multi-Sig";
        description = "Product name shown in page title, headers, and footer.";
      };
      theme = {
        textColor = mkOption {
          type = types.str;
          example = "#ffffff";
        };
        backgroundColor = mkOption {
          type = types.str;
          example = "#000000";
        };
      };
    };

    # ── cfg-service service keys (Service.key in chains_service) ────────
    # The frontend (safe-wallet-web) issues `/v2/chains?serviceKey=WALLET_WEB`.
    # cfg-service `get_object_or_404(Service, key=service_key)` returns 404
    # if no matching Service row exists — every chain query falls over.
    # Listed keys are seeded by `catacomb-chain-bootstrap` on each rebuild.
    services = mkOption {
      type = types.listOf types.str;
      example = [
        "WALLET_WEB"
        "MOBILE"
      ];
      description = ''
        Service keys to register in cfg-service so that the
        `/v2/chains/{service_key}/` endpoint resolves. Defaults to
        `[ "WALLET_WEB" ]` — the only key safe-wallet-web sends.
      '';
    };

    # ── Chains (registered in safe-config-service at first boot) ─────────
    chains = mkOption {
      type = types.attrsOf (
        types.submodule {
          options = {
            chainId = mkOption { type = types.int; };
            shortName = mkOption { type = types.str; };
            chainName = mkOption { type = types.str; };
            description = mkOption {
              type = types.str;
              default = "";
            };
            isTestnet = mkOption {
              type = types.bool;
              default = false;
            };
            l2 = mkOption {
              type = types.bool;
              default = false;
            };
            rpcUri = mkOption { type = types.str; };
            blockExplorerUriTemplate = mkOption {
              type = types.attrsOf types.str;
              description = "Map of { address, txHash, api } URL templates.";
            };
            transactionService = mkOption { type = types.str; };
            nativeCurrency = mkOption {
              type = types.submodule {
                options = {
                  name = mkOption { type = types.str; };
                  symbol = mkOption { type = types.str; };
                  decimals = mkOption {
                    type = types.int;
                    default = 18;
                  };
                  logoUri = mkOption {
                    type = types.str;
                    description = ''
                      URL to currency logo image. Safe Client Gateway
                      Zod-validates this as a non-null string at runtime
                      (`/v2/chains` 404s the whole list if any chain has
                      a null logo). Use a placeholder URL if the chain
                      doesn't have an official logo.
                    '';
                  };
                };
              };
            };
            chainLogoUri = mkOption {
              type = types.nullOr types.str;
              default = null;
            };
          };
        }
      );
    };
  };
}
