# Declares every option exposed by this host. No values set here — defaults
# live in `defaultConfig.nix`, per-deploy overrides in `config.nix`.
{ lib, ... }:
{
  options.catacomb = with lib; {

    # ── Per-deploy identity ──────────────────────────────────────────────
    domain = mkOption {
      type = types.str;
      example = "catacomb.example.com";
      description = ''
        Apex hostname. The UI is served here. Client gateway and per-chain
        transaction services live under `client.`, `transaction-classic.`,
        `transaction-mordor.` subdomains.
      '';
    };

    hostName = mkOption {
      type = types.str;
      example = "catacomb";
      description = "NixOS hostname.";
    };

    timeZone = mkOption {
      type = types.str;
      example = "Europe/Berlin";
      description = "Host timezone (IANA name).";
    };

    acmeEmail = mkOption {
      type = types.str;
      example = "ops@example.com";
      description = "Contact email registered with Let's Encrypt for ACME certs.";
    };

    sshAuthorizedKeys = mkOption {
      type = types.listOf types.str;
      example = [ "ssh-ed25519 AAAA... operator@laptop" ];
      description = "SSH public keys authorised for root login.";
    };

    bootDevice = mkOption {
      type = types.str;
      example = "/dev/vda";
      description = "Block device for GRUB BIOS install (most cloud VMs are /dev/vda).";
    };

    tlsEnabled = mkOption {
      type = types.bool;
      example = true;
      description = ''
        Issue Let's Encrypt certs via ACME. DNS for `domain` and its
        subdomains must point at this host before the first rebuild.
      '';
    };

    # ── Branding ─────────────────────────────────────────────────────────
    branding = {
      enable = mkOption {
        type = types.bool;
        default = true;
        description = ''
          Apply the Catacomb branding overlay (`pkgs/catacomb-branding`)
          on top of upstream `safe-wallet-monorepo`. When true: header
          wordmark + tagline, custom footer links, top-of-page
          notification banner, SVG-only favicon, Catacomb fonts. When
          false: vanilla Safe wallet with only `branding.appName` swapped
          via the upstream-supported `NEXT_PUBLIC_BRAND_NAME`. The
          consumer-supplied tagline/notification/footerLinks/githubRepoLink
          options become no-ops with `enable = false` (no patch reads them).
        '';
      };
      appName = mkOption {
        type = types.str;
        example = "Acme Multi-Sig";
        description = "Product name shown in page title, headers, and footer.";
      };
      tagline = mkOption {
        type = types.str;
        default = "";
        example = "classix edition";
        description = ''
          Subtitle rendered under the app name in the top-left wordmark.
          Empty string hides the line entirely. Wired into the bundle as
          `NEXT_PUBLIC_CATACOMB_TAGLINE`. Only meaningful with
          `branding.enable = true`.
        '';
      };
      notification = mkOption {
        type = types.str;
        default = "";
        example = "Demo deploy — do not use with production assets.";
        description = ''
          Top-of-page warning banner shown across every route. Empty
          string hides the banner entirely. Rendered as a MUI
          `<Alert severity="warning">` above the header. Wired in as
          `NEXT_PUBLIC_CATACOMB_NOTIFICATION`. Only meaningful with
          `branding.enable = true`.
        '';
      };
      githubRepoLink = mkOption {
        type = types.str;
        default = "";
        example = "https://github.com/classix-dev/nix-catacomb";
        description = ''
          Replaces the upstream `safe-global/safe-wallet-monorepo` URL
          that the footer's `vX.Y.Z` link points at. Empty string falls
          through to the upstream default (`APP_HOMEPAGE`). Wired in as
          `NEXT_PUBLIC_CATACOMB_GITHUB_REPO`. Only meaningful with
          `branding.enable = true`.
        '';
      };
      footerLinks = mkOption {
        type = types.listOf (
          types.submodule {
            options = {
              label = mkOption {
                type = types.str;
                description = "Visible link text.";
              };
              url = mkOption {
                type = types.str;
                description = "Target URL — opens in a new tab.";
              };
            };
          }
        );
        default = [ ];
        example = lib.literalExpression ''
          [
            { label = "classix.dev"; url = "https://classix.dev"; }
          ]
        '';
        description = ''
          Links rendered in the footer alongside the version string.
          Replaces the upstream "unofficial distribution of the app" line.
          Serialised to JSON and read at build time as
          `NEXT_PUBLIC_CATACOMB_FOOTER_LINKS`. Only meaningful with
          `branding.enable = true`.
        '';
      };
      faviconSvg = mkOption {
        type = types.path;
        default = ../../pkgs/catacomb-branding/assets/etc-logo.svg;
        description = ''
          SVG used as the wallet's favicon (and `safari-pinned-tab.svg`).
          Defaults to the library's ETC chain logo — appropriate for
          Catacomb deploys built around ETC, which is the canonical
          chain. Override for non-Classix Catacombs.
        '';
      };
      theme = {
        textColor = mkOption {
          type = types.str;
          example = "#ffffff";
        };
        backgroundColor = mkOption {
          type = types.str;
          example = "#000000";
        };
      };
    };

    # ── Client Gateway (CGW) tuning ─────────────────────────────────────
    # Expose the upstream `safe-client-gateway` env vars that govern
    # price-cache TTLs and external-provider auth. The prices module
    # uses Coingecko by default; without an API key it hits the
    # unauthenticated public API (single-digit-rps rate limit), which
    # on a small deploy with a short cache produces the classic
    # "balances show $0 then update later" symptom — the cache TTL
    # window is shorter than the time it takes for one request to
    # win the rate-limit lottery.
    #
    # Defaults below set price TTLs to 1h. Empirically, one upstream
    # request per hour fits comfortably under any provider's free tier,
    # while a stale-by-up-to-an-hour fiat conversion is fine for a
    # wallet UI. Tighten if you need fresher prices and you have a
    # paid tier; ttl is independent of the API-key choice.
    cgw = {
      pricesProvider = {
        apiKey = mkOption {
          type = types.nullOr types.str;
          default = null;
          example = "CG-xxxxxxxxxxxxxxxx";
          description = ''
            Coingecko API key (Demo or Pro). null = unauthenticated
            public API. The unauthenticated API rate-limits aggressively
            (~10 req/min) — fine when paired with a long
            `tokenPricesTtlSeconds` / `nativeCoinPricesTtlSeconds`,
            painful with the upstream defaults.

            Heads up: the value is interpolated into a systemd
            activation script and ends up in /nix/store, which is
            world-readable on the host. For a real key, prefer
            `builtins.readFile "/path/to/key-outside-flake-tree";`
            or wrap with agenix/sops.
          '';
        };
        apiBaseUri = mkOption {
          type = types.nullOr types.str;
          default = null;
          example = "https://pro-api.coingecko.com/api/v3";
          description = ''
            Override the prices-provider base URI. Required when
            `apiKey` is a Pro key — Coingecko's Pro API uses
            `pro-api.coingecko.com`, not the public `api.coingecko.com`.
            null = upstream default.
          '';
        };
        tokenPricesTtlSeconds = mkOption {
          type = types.ints.positive;
          default = 3600;
          description = ''
            CGW Redis cache TTL for ERC-20 token prices, in seconds.
            Sets `PRICES_TTL_SECONDS` on `cgw-web`. Upstream default
            is 300; we default to 3600 (1h).
          '';
        };
        nativeCoinPricesTtlSeconds = mkOption {
          type = types.ints.positive;
          default = 3600;
          description = ''
            CGW Redis cache TTL for the native-coin price (e.g. ETC,
            ETH), in seconds. Sets `NATIVE_COINS_PRICES_TTL_SECONDS`.
            Upstream default is 100; we default to 3600 (1h).
          '';
        };
      };
      zerion = {
        apiKey = mkOption {
          type = types.nullOr types.str;
          default = null;
          description = ''
            Zerion API key for the `/v1/.../positions/<fiat>`
            DeFi-positions endpoint. Without one, Zerion 401s and CGW
            propagates that to the browser; the wallet's Balances
            page surfaces `{"code":401,"message":"An error occurred"}`
            in the network tab. Note Zerion does not currently cover
            Ethereum Classic, so a key here doesn't actually populate
            positions on ETC-only deploys — it only stops the 401
            noise. Same /nix/store leakage caveat as
            `pricesProvider.apiKey`.
          '';
        };
      };
    };

    # ── cfg-service service keys (Service.key in chains_service) ────────
    # The frontend (safe-wallet-web) issues `/v2/chains?serviceKey=WALLET_WEB`.
    # cfg-service `get_object_or_404(Service, key=service_key)` returns 404
    # if no matching Service row exists — every chain query falls over.
    # Listed keys are seeded by `catacomb-chain-bootstrap` on each rebuild.
    services = mkOption {
      type = types.listOf types.str;
      example = [
        "WALLET_WEB"
        "MOBILE"
      ];
      description = ''
        Service keys to register in cfg-service so that the
        `/v2/chains/{service_key}/` endpoint resolves. Defaults to
        `[ "WALLET_WEB" ]` — the only key safe-wallet-web sends.
      '';
    };

    # ── Chains (registered in safe-config-service at first boot) ─────────
    chains = mkOption {
      type = types.attrsOf (
        types.submodule {
          options = {
            chainId = mkOption { type = types.int; };
            shortName = mkOption { type = types.str; };
            chainName = mkOption { type = types.str; };
            description = mkOption {
              type = types.str;
              default = "";
            };
            isTestnet = mkOption {
              type = types.bool;
              default = false;
            };
            l2 = mkOption {
              type = types.bool;
              default = false;
            };
            rpcUri = mkOption { type = types.str; };
            blockExplorerUriTemplate = mkOption {
              type = types.attrsOf types.str;
              description = "Map of { address, txHash, api } URL templates.";
            };
            transactionService = mkOption { type = types.str; };
            nativeCurrency = mkOption {
              type = types.submodule {
                options = {
                  name = mkOption { type = types.str; };
                  symbol = mkOption { type = types.str; };
                  decimals = mkOption {
                    type = types.int;
                    default = 18;
                  };
                  logoUri = mkOption {
                    type = types.str;
                    description = ''
                      URL to currency logo image. Safe Client Gateway
                      Zod-validates this as a non-null string at runtime
                      (`/v2/chains` 404s the whole list if any chain has
                      a null logo). Use a placeholder URL if the chain
                      doesn't have an official logo.
                    '';
                  };
                };
              };
            };
            chainLogoUri = mkOption {
              type = types.nullOr types.str;
              default = null;
            };
          };
        }
      );
    };
  };
}
