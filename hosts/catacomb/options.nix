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

    # ── Chains (registered in safe-config-service at first boot) ─────────
    chains = mkOption {
      type = types.attrsOf (
        types.submodule {
          options = {
            chainId = mkOption { type = types.int; };
            shortName = mkOption { type = types.str; };
            chainName = mkOption { type = types.str; };
            rpcUri = mkOption { type = types.str; };
            blockExplorerUriTemplate = mkOption {
              type = types.attrsOf types.str;
              description = "Map of { address, txHash, api } URL templates.";
            };
            transactionService = mkOption { type = types.str; };
            nativeCurrency = mkOption {
              type = types.attrsOf types.str;
              description = "Map of { name, symbol, decimals (as string) }.";
            };
          };
        }
      );
    };
  };
}
