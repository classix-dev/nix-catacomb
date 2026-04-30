# Reverse proxy + TLS for Catacomb.
#
# Subdomain layout:
#   multisig.<domain>            → ui (frontend)
#   client.multisig.<domain>     → cgw-web (client gateway)
#   transaction-classic.<domain> → txs-web (mainnet)
#   transaction-mordor.<domain>  → txs-web (mordor) — TODO when 2nd txs is wired
#
# The UI vhost runs `sub_filter` to swap upstream Safe branding strings
# (e.g. "Safe{Wallet}") for `catacomb.branding.appName` in HTML responses.
# This is a deliberate stop-gap — proper override is a UI rebuild from
# `safe-wallet-monorepo` (TODO).
{ config, lib, ... }:
let
  domain = "catacomb.example"; # TODO: lift to a top-level option
  acmeEmail = "ops@example.invalid";
  appName = config.catacomb.branding.appName;

  proxyTo = upstream: extras: lib.recursiveUpdate {
    forceSSL = true;
    enableACME = true;
    locations."/" = {
      proxyPass = "http://${upstream}";
      proxyWebsockets = true;
    };
  } extras;

  # sub_filter doesn't run on gzipped responses — strip Accept-Encoding
  # upstream and apply substitutions on the decoded body.
  uiBrandingExtras = {
    locations."/" = {
      extraConfig = ''
        proxy_set_header Accept-Encoding "";
        sub_filter_once off;
        sub_filter_types text/html application/javascript;
        sub_filter 'Safe{Wallet}' '${appName}';
        sub_filter 'Safe Wallet'  '${appName}';
      '';
    };
  };
in
{
  security.acme = {
    acceptTerms = true;
    defaults.email = acmeEmail;
  };

  services.nginx = {
    enable = true;
    recommendedProxySettings = true;
    recommendedTlsSettings = true;
    recommendedGzipSettings = true;

    virtualHosts = {
      "multisig.${domain}" = proxyTo "127.0.0.1:8080" uiBrandingExtras;
      "client.multisig.${domain}" = proxyTo "127.0.0.1:3000" { };
      "transaction-classic.${domain}" = proxyTo "127.0.0.1:8000" { };
      # "transaction-mordor.${domain}" = proxyTo "127.0.0.1:8001" { }; # TODO
    };
  };

  # Container port mappings must match these upstream addresses — TODO: add
  # explicit `ports = [ "127.0.0.1:8080:8080" ]` style entries to safe-stack.nix.
}
