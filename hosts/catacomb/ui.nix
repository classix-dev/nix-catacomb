# Pre-built static UI (safe-wallet-web `next export`) served directly from
# the host nginx. Replaces the upstream `ui:` docker container that ran
# `next build` at boot — see README.md "UI status (the saga)".
#
# Branding, gateway URL, and chain id are baked into the bundle at Nix
# eval time, so any change to `config.catacomb.branding` /
# `config.catacomb.domain` / `config.catacomb.chains.etc.chainId` will
# trigger a UI rebuild. Cachix substituters absorb the cost when nothing
# changed.
{
  config,
  pkgs,
  safe-wallet-web,
  ...
}:
let
  cfg = config.catacomb;
  d = cfg.domain;
  tls = cfg.tlsEnabled;
  scheme = if tls then "https" else "http";

  ui = pkgs.callPackage ../../pkgs/safe-wallet-web {
    src = safe-wallet-web;
    inherit (cfg.branding) appName;
    gatewayUrl = "${scheme}://${d}/cgw";
    defaultChainId = cfg.chains.etc.chainId;
    isProduction = true;
  };
in
{
  services.nginx.virtualHosts."${d}" = {
    # Static UI at the apex. `try_files` first looks for an exact match,
    # then a `.html` extension (next-export emits `/foo.html`, not
    # `/foo/index.html`), then falls back to the SPA shell.
    locations."/" = {
      root = "${ui}";
      tryFiles = "$uri $uri.html $uri/ /index.html";
    };

    # Path fanout to the still-containerised backends — the internal
    # nginx in the upstream compose stack already routes these on :8000.
    # We pass through a single proxy hop rather than re-implement the
    # rules here; that nginx has gzip, websocket forwarding, and
    # service-specific timeouts dialled in.
    locations."/cgw/" = {
      proxyPass = "http://127.0.0.1:8000";
      proxyWebsockets = true;
    };
    locations."/cfg/" = {
      proxyPass = "http://127.0.0.1:8000";
    };
    locations."/txs/" = {
      proxyPass = "http://127.0.0.1:8000";
    };
    locations."/events/" = {
      proxyPass = "http://127.0.0.1:8000";
      proxyWebsockets = true;
    };
  };

  # Expose the built UI path to systemd / debug tooling.
  environment.etc."catacomb/ui-path".text = "${ui}";
}
