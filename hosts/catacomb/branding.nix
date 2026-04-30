# Catacomb branding + chain registry (Nix-side source of truth).
#
# Theme + chain metadata is consumed by `chain-bootstrap` in safe-stack.nix
# (POSTed into safe-config-service at boot). App-name strings are consumed
# by `nginx.nix` via `sub_filter` to rewrite the upstream UI's HTML.
{ lib, ... }:
{
  options.catacomb = with lib; {
    branding = {
      appName = mkOption {
        type = types.str;
        default = "Classix Catacomb Multi-Sig";
        description = "Product name shown in page title, headers, and footer.";
      };
      theme = {
        textColor = mkOption {
          type = types.str;
          default = "#ddffdc"; # classix.dev pale-green
        };
        backgroundColor = mkOption {
          type = types.str;
          default = "#0a0a0a"; # classix.dev near-black
        };
      };
    };

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

  config.catacomb.chains = {
    etc = {
      chainId = 61;
      shortName = "etc";
      chainName = "Ethereum Classic";
      rpcUri = "https://rpc.mainnet.etccooperative.org";
      transactionService = "https://transaction-classic.catacomb.example";
      blockExplorerUriTemplate = {
        address = "https://blockscout.com/etc/mainnet/address/{{address}}";
        txHash = "https://blockscout.com/etc/mainnet/tx/{{txHash}}";
        api = "https://blockscout.com/etc/mainnet/api?module={{module}}&action={{action}}&address={{address}}&apiKey={{apiKey}}";
      };
      nativeCurrency = {
        name = "Ether Classic";
        symbol = "ETC";
        decimals = "18";
      };
    };

    mordor = {
      chainId = 63;
      shortName = "etcm";
      chainName = "Mordor";
      rpcUri = "https://rpc.mordor.etccooperative.org";
      transactionService = "https://transaction-mordor.catacomb.example";
      blockExplorerUriTemplate = {
        address = "https://blockscout.com/etc/mordor/address/{{address}}";
        txHash = "https://blockscout.com/etc/mordor/tx/{{txHash}}";
        api = "https://blockscout.com/etc/mordor/api?module={{module}}&action={{action}}&address={{address}}&apiKey={{apiKey}}";
      };
      nativeCurrency = {
        name = "Mordor Ether Classic";
        symbol = "METC";
        decimals = "18";
      };
    };
  };
}
