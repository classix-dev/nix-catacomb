# External NixOS nginx — TLS termination + ACME wrapper. Per-location
# rules for the apex (static UI root, /assets/, backend path-fanout)
# live in `ui.nix` so that the UI module owns its own routing surface.
#
# Chain RPC plumbing (CORS proxies, self-hosted node connections, etc.)
# lives in the consumer flake — chain-specific nginx config has no place
# in this chain-agnostic library. Consumers can extend
# `services.nginx.virtualHosts` from their own modules; the NixOS module
# system merges the additions.
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
