# Reverse proxy + TLS for Catacomb.
#
# Layout (with `catacomb.domain` = catacomb.classix.dev):
#   catacomb.classix.dev                     → ui (frontend)
#   client.catacomb.classix.dev              → cgw-web (client gateway)
#   transaction-classic.catacomb.classix.dev → txs-web (mainnet)
#   transaction-mordor.catacomb.classix.dev  → txs-web (mordor) — TODO
#
# The UI vhost runs `sub_filter` to swap upstream Safe branding strings
# (e.g. "Safe{Wallet}") for `catacomb.branding.appName` in HTML / JS
# responses. Stop-gap until a proper UI rebuild lands.
{ config, lib, ... }:
let
  d = config.catacomb.domain;
  inherit (config.catacomb.branding) appName;
  tls = config.catacomb.tlsEnabled;

  proxyTo =
    upstream: extras:
    lib.recursiveUpdate {
      forceSSL = tls;
      enableACME = tls;
      locations."/" = {
        proxyPass = "http://${upstream}";
        proxyWebsockets = true;
      };
    } extras;

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
  security.acme = lib.mkIf tls {
    acceptTerms = true;
    defaults.email = config.catacomb.acmeEmail;
  };

  services.nginx = {
    enable = true;
    recommendedProxySettings = true;
    recommendedTlsSettings = true;
    recommendedGzipSettings = true;

    virtualHosts = {
      "${d}" = proxyTo "127.0.0.1:8080" uiBrandingExtras;
      "client.${d}" = proxyTo "127.0.0.1:3000" { };
      "transaction-classic.${d}" = proxyTo "127.0.0.1:8000" { };
      # "transaction-mordor.${d}" = proxyTo "127.0.0.1:8001" { }; # TODO
    };
  };
}
