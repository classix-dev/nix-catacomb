# External NixOS nginx — TLS termination + ACME wrapper. Per-location
# rules (static UI root, backend path-fanout) live in `ui.nix` so that
# the UI module owns its own routing surface.
{ config, lib, ... }:
let
  d = config.catacomb.domain;
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
    };
  };
}
