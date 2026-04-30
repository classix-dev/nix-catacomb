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
    branding = {
      appName = lib.mkDefault "Catacomb Multi-Sig";
      theme = {
        textColor = lib.mkDefault "#ffffff";
        backgroundColor = lib.mkDefault "#000000";
      };
    };

    # ── Service keys ───────────────────────────────────────────────────
    services = lib.mkDefault [ "WALLET_WEB" ];

    # ── Chains ─────────────────────────────────────────────────────────
    # Defaults to Ethereum Classic mainnet (61), using ETC Cooperative's
    # public RPC. Adding more chains requires standing up a parallel
    # `txs` stack per chain — the bundled compose project indexes one.
    # Override or extend in your consumer flake.
    chains = lib.mkDefault {
      etc = {
        chainId = 61;
        shortName = "etc";
        chainName = "Ethereum Classic";
        description = "Ethereum Classic mainnet";
        isTestnet = false;
        rpcUri = "https://rpc.mainnet.etccooperative.org";
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
          logoUri = "https://blockscout.com/etc/mainnet/images/logo.png";
        };
        chainLogoUri = "https://blockscout.com/etc/mainnet/images/logo.png";
      };
    };
  };
}
