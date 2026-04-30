# External NixOS nginx: TLS termination + product-name sub_filter, then a
# straight pass-through to the internal `nginx` container on :8000 which does
# the path-based fanout to backend services (matches upstream's docker-compose
# layout).
{ config, lib, ... }:
let
  d = config.catacomb.domain;
  inherit (config.catacomb.branding) appName;
  tls = config.catacomb.tlsEnabled;
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

    virtualHosts."${d}" = {
      forceSSL = tls;
      enableACME = tls;
      locations."/" = {
        proxyPass = "http://127.0.0.1:8000";
        proxyWebsockets = true;
        extraConfig = ''
          proxy_set_header Accept-Encoding "";
          sub_filter_once off;
          sub_filter_types text/html application/javascript;
          sub_filter 'Safe{Wallet}' '${appName}';
          sub_filter 'Safe Wallet'  '${appName}';
        '';
      };
    };
  };
}
