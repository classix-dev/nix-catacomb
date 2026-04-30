# External NixOS nginx — TLS termination + ACME wrapper. Per-location
# rules for the apex (static UI root, /assets/, backend path-fanout)
# live in `ui.nix` so that the UI module owns its own routing surface.
{ config, lib, ... }:
let
  d = config.catacomb.domain;
  tls = config.catacomb.tlsEnabled;

  # Public ETC Cooperative RPC. The CORS proxy below forwards browser
  # JSON-RPC traffic here with permissive CORS headers — the upstream
  # itself returns no `Access-Control-Allow-Origin`, so direct calls
  # from the wallet fail preflight.
  # TODO: support pointing at a self-hosted ETC node.
  etcUpstreamRpc = "https://rpc.mainnet.etccooperative.org";
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

    # rpc.<domain> — CORS-injecting proxy to the upstream ETC RPC.
    # `proxyPass` field omitted on purpose — when set, NixOS appends
    # `recommendedProxySettings` (which includes
    # `proxy_set_header Host $host`) AFTER our extraConfig, silently
    # overriding the upstream Host we need. Writing `proxy_pass`
    # directly in extraConfig keeps our headers last-wins.
    virtualHosts."rpc.${d}" = {
      forceSSL = tls;
      enableACME = tls;
      locations."/".extraConfig = ''
        proxy_pass ${etcUpstreamRpc};
        proxy_ssl_server_name on;
        proxy_http_version 1.1;
        proxy_set_header Host rpc.mainnet.etccooperative.org;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;

        # Preflight: short-circuit OPTIONS with CORS headers.
        if ($request_method = OPTIONS) {
          add_header Access-Control-Allow-Origin  "*"      always;
          add_header Access-Control-Allow-Methods "POST, GET, OPTIONS" always;
          add_header Access-Control-Allow-Headers "Content-Type, Authorization" always;
          add_header Access-Control-Max-Age       "86400"  always;
          add_header Content-Length 0;
          add_header Content-Type   "text/plain";
          return 204;
        }

        # Normal responses: append CORS so the browser accepts the
        # JSON-RPC reply.
        add_header Access-Control-Allow-Origin  "*"      always;
        add_header Access-Control-Allow-Methods "POST, GET, OPTIONS" always;
        add_header Access-Control-Allow-Headers "Content-Type, Authorization" always;
      '';
    };
  };
}
