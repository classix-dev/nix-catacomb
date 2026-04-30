# Default values for every customisable option declared in `options.nix`.
# Override per-deploy in `config.nix` (gitignored).
#
# All values use `lib.mkDefault` so plain assignments in `config.nix` win
# without needing `lib.mkForce`.
{ config, lib, ... }:
let
  d = config.catacomb.domain;
in
{
  catacomb = {
    # ── Per-deploy identity (placeholder defaults — set real values in config.nix) ──
    domain = lib.mkDefault "catacomb.example.com";
    hostName = lib.mkDefault "catacomb";
    timeZone = lib.mkDefault "UTC";
    acmeEmail = lib.mkDefault "admin@${d}";
    sshAuthorizedKeys = lib.mkDefault [ ];
    bootDevice = lib.mkDefault "/dev/vda";
    tlsEnabled = lib.mkDefault true;

    # ── Branding ───────────────────────────────────────────────────────
    # Defaults reflect the canonical Catacomb identity (Classix-flavored).
    # Override per-deploy in your consumer flake.
    branding = {
      appName = lib.mkDefault "Catacomb Multisig";
      tagline = lib.mkDefault "classix edition";
      githubRepoLink = lib.mkDefault "https://github.com/classix-dev/nix-catacomb";
      footerLinks = lib.mkDefault [
        {
          label = "classix.dev";
          url = "https://classix.dev";
        }
      ];
      theme = {
        textColor = lib.mkDefault "#ddffdc";
        backgroundColor = lib.mkDefault "#0a0a0a";
      };
    };

    # ── Service keys ───────────────────────────────────────────────────
    services = lib.mkDefault [ "WALLET_WEB" ];

    # ── Chains ─────────────────────────────────────────────────────────
    # Defaults to Ethereum Classic mainnet (61), using ETC Cooperative's
    # public RPC. Adding more chains requires standing up a parallel
    # `txs` stack per chain — the bundled compose project indexes one.
    # Override or extend in your consumer flake.
    # rpcUri points at the local CORS-injecting proxy (`rpc.${d}`)
    # configured in `nginx.nix`, which forwards to the upstream ETC
    # Cooperative RPC. The public RPC fails browser CORS preflight so
    # the wallet can't talk to it directly.
    chains = lib.mkDefault {
      etc = {
        chainId = 61;
        shortName = "etc";
        chainName = "Ethereum Classic";
        description = "Ethereum Classic mainnet";
        isTestnet = false;
        rpcUri = "https://rpc.${d}";
        transactionService = "https://${d}/txs";
        blockExplorerUriTemplate = {
          address = "https://blockscout.com/etc/mainnet/address/{{address}}";
          txHash = "https://blockscout.com/etc/mainnet/tx/{{txHash}}";
          api = "https://blockscout.com/etc/mainnet/api?module={{module}}&action={{action}}&address={{address}}&apiKey={{apiKey}}";
        };
        nativeCurrency = {
          name = "Ether Classic";
          symbol = "ETC";
          decimals = 18;
          logoUri = "https://${d}/assets/etc-logo.svg";
        };
        chainLogoUri = "https://${d}/assets/etc-logo.svg";
      };
    };
  };
}
