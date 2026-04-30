# Pre-built static UI (safe-wallet-web `next export`) served directly from
# the host nginx. Replaces the upstream `ui:` docker container that ran
# `next build` at boot — see README.md "Why Nix?" and the package
# derivation at `pkgs/safe-wallet-web`.
#
# When `catacomb.branding.enable = true` (default), the upstream source
# is layered with the Catacomb branding overlay (`pkgs/catacomb-branding`)
# before being passed to the build: header wordmark + tagline, custom
# footer links, top-of-page notification banner, SVG-only favicon,
# Catacomb fonts. With `enable = false` the wallet builds vanilla, with
# only `branding.appName` swapped via the upstream-supported
# `NEXT_PUBLIC_BRAND_NAME`.
#
# Branding, gateway URL, and chain id are baked into the bundle at Nix
# eval time, so any change to `config.catacomb.branding` /
# `config.catacomb.domain` / `config.catacomb.chains.etc.chainId` will
# trigger a UI rebuild. Cachix substituters absorb the cost when nothing
# changed.
{
  config,
  lib,
  pkgs,
  safe-wallet-web,
  ...
}:
let
  cfg = config.catacomb;
  d = cfg.domain;
  tls = cfg.tlsEnabled;
  scheme = if tls then "https" else "http";

  brandedSrc =
    if cfg.branding.enable then
      pkgs.callPackage ../../pkgs/catacomb-branding {
        src = safe-wallet-web;
        inherit (cfg.branding) faviconSvg;
      }
    else
      safe-wallet-web;

  ui = pkgs.callPackage ../../pkgs/safe-wallet-web {
    src = brandedSrc;
    inherit (cfg.branding) appName;
    gatewayUrl = "${scheme}://${d}/cgw";
    defaultChainId = cfg.chains.etc.chainId;
    isProduction = true;

    # Catacomb-specific env vars are only meaningful when the branding
    # patch is in the source. With `enable = false` the patch is absent
    # and these would land as unread env vars in the bundle.
    extraEnv = lib.optionalAttrs cfg.branding.enable {
      NEXT_PUBLIC_CATACOMB_TAGLINE = cfg.branding.tagline;
      NEXT_PUBLIC_CATACOMB_FOOTER_LINKS = builtins.toJSON cfg.branding.footerLinks;
      NEXT_PUBLIC_CATACOMB_GITHUB_REPO = cfg.branding.githubRepoLink;
      NEXT_PUBLIC_CATACOMB_NOTIFICATION = cfg.branding.notification;
    };
  };

  # Static assets served at https://${domain}/assets/. Currently just
  # the ETC chain logo, used both as the chain logo (referenced by
  # `chains.etc.{nativeCurrency.logoUri, chainLogoUri}`) and as the
  # default favicon SVG inside the wallet bundle. Lives under
  # `pkgs/catacomb-branding/assets/` so the branding module owns its
  # own visual identity.
  staticAssets = ../../pkgs/catacomb-branding/assets;
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

    # Library-shipped assets (chain logos, etc.). Serves
    # `assets/etc-logo.svg` at `/assets/etc-logo.svg`. Consumers can
    # extend this by adding their own `services.nginx.virtualHosts.${d}.locations."/assets/<name>".alias = "${./path-to-extra-assets}/";`
    # if they need additional chain logos.
    locations."/assets/" = {
      alias = "${staticAssets}/";
      extraConfig = ''
        add_header Cache-Control "public, max-age=86400";
      '';
    };

    # Path fanout to the still-containerised backends — the internal
    # nginx in the upstream compose stack already routes these on :8000.
    # We pass through a single proxy hop rather than re-implement the
    # rules here; that nginx has gzip, websocket forwarding, and
    # service-specific timeouts dialled in.
    #
    # The `/cgw/` extraConfig also rewrites cfg-service's broken
    # MEDIA_URL prefix on chain-logo URLs. CGW serializes them with
    # `http://localhost:8000/cfg/media/<the-url>` baked in (Mixed
    # Content + broken on the public host); whatever absolute URL is
    # configured for the chain logo, cfg-service mangles it into
    # `http://localhost:8000/cfg/media/https%3A/<rest>` (Django
    # collapses `//` to `/` and URL-encodes the colon). Rewrite both
    # the single- and double-encoded forms back to `https://<rest>`
    # before the JSON reaches the browser. Targets JSON responses only;
    # `sub_filter` works because the rewrite is a literal substring
    # (no JSON escaping involved for slashes/colons in this URL).
    locations."/cgw/" = {
      proxyPass = "http://127.0.0.1:8000";
      proxyWebsockets = true;
      extraConfig = ''
        proxy_set_header Accept-Encoding "";
        sub_filter_once off;
        sub_filter_types application/json;
        sub_filter 'http://localhost:8000/cfg/media/https%3A/'   'https://';
        sub_filter 'http://localhost:8000/cfg/media/https%253A/' 'https://';
      '';
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
