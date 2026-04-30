# Run upstream `safe-global/safe-infrastructure` (docker-compose) verbatim
# against a NixOS-managed Docker daemon. We pin the upstream source via the
# `safe-infrastructure` flake input — bump with `nix flake update`.
#
# Per-deploy values (RPC URL, branding, secrets) are injected via:
#   - /var/lib/catacomb/.env          (top-level docker-compose vars)
#   - /var/lib/catacomb/override.yml  (per-service env overrides)
#
# Both are regenerated on each rebuild by the catacomb-stack-prepare
# oneshot below.
{
  config,
  lib,
  pkgs,
  safe-infrastructure,
  ...
}:
let
  cfg = config.catacomb;
  stateDir = "/var/lib/catacomb";
  envFile = "${stateDir}/.env";
  overrideFile = "${stateDir}/override.yml";

  # Pinned image versions — bumped here, applied on next rebuild.
  versions = {
    UI_VERSION = "v1.88.0";
    CGW_VERSION = "v1.108.0";
    CFG_VERSION = "v2.94.0";
    TXS_VERSION = "v6.3.0";
    EVENTS_VERSION = "v1.3.0";
  };

  # Compose override — references env vars from /var/lib/catacomb/.env
  # (which the prepare oneshot generates).
  override = pkgs.writeText "catacomb-override.yml" ''
    services:
      cfg-db:        { environment: { POSTGRES_PASSWORD: "''${POSTGRES_PASSWORD}" } }
      cgw-db:        { environment: { POSTGRES_PASSWORD: "''${POSTGRES_PASSWORD}" } }
      txs-db:        { environment: { POSTGRES_PASSWORD: "''${POSTGRES_PASSWORD}" } }
      events-db:     { environment: { POSTGRES_PASSWORD: "''${POSTGRES_PASSWORD}" } }

      cfg-web:
        environment:
          SECRET_KEY: "''${DJANGO_SECRET}"
          DJANGO_SUPERUSER_PASSWORD: "''${DJANGO_SUPERUSER_PASSWORD}"
          DJANGO_SUPERUSER_EMAIL: "admin@${cfg.domain}"
          CGW_AUTH_TOKEN: "''${CGW_AUTH_TOKEN}"
          POSTGRES_PASSWORD: "''${POSTGRES_PASSWORD}"
          CSRF_TRUSTED_ORIGINS: "https://${cfg.domain}"

      txs-web:
        environment:
          DJANGO_SECRET_KEY: "''${DJANGO_SECRET}"
          DATABASE_URL: "psql://postgres:''${POSTGRES_PASSWORD}@txs-db:5432/postgres"
          CSRF_TRUSTED_ORIGINS: "https://${cfg.domain}"

      txs-worker-indexer: &txs-worker-overrides
        environment:
          DJANGO_SECRET_KEY: "''${DJANGO_SECRET}"
          DATABASE_URL: "psql://postgres:''${POSTGRES_PASSWORD}@txs-db:5432/postgres"

      txs-worker-contracts-tokens: *txs-worker-overrides
      txs-worker-notifications-webhooks: *txs-worker-overrides
      txs-scheduler: *txs-worker-overrides

      events-web:
        environment:
          DATABASE_URL: "psql://postgres:''${POSTGRES_PASSWORD}@events-db:5432/postgres"

      cgw-web:
        environment:
          AUTH_TOKEN: "''${CGW_AUTH_TOKEN}"

      ui:
        environment:
          NEXT_PUBLIC_GATEWAY_URL_PRODUCTION: "https://${cfg.domain}/cgw"
          NEXT_PUBLIC_DEFAULT_MAINNET_CHAIN_ID: "${toString cfg.chains.etc.chainId}"
          NEXT_PUBLIC_IS_PRODUCTION: "true"
  '';

  # docker compose invocation used by every catacomb-stack systemd unit.
  # `--project-directory ${stateDir}` so upstream's relative bind mounts
  # (`./data/<svc>-db`, `./docker/nginx/nginx.conf`) resolve under our
  # writable /var/lib/catacomb/, with symlinks pointing back to the
  # read-only nix store for the static bits.
  composeExe = "${pkgs.docker-compose}/bin/docker-compose";
  composeArgs = lib.concatStringsSep " " [
    "--project-directory ${stateDir}"
    "-f ${stateDir}/docker-compose.yml"
    "-f ${overrideFile}"
    "--env-file ${envFile}"
    "--project-name catacomb"
  ];

  versionEnvLines = lib.concatStringsSep "\n" (lib.mapAttrsToList (k: v: "${k}=${v}") versions);
in
{
  systemd.tmpfiles.rules = [
    "d ${stateDir} 0755 root root -"
    "d ${stateDir}/secrets 0700 root root -"
  ];

  # Use Docker (not podman) — upstream compose syntax assumes Docker, and
  # docker-compose talks to the Docker daemon directly.
  virtualisation.docker.enable = true;
  environment.systemPackages = [ pkgs.docker-compose ];

  # ── Stack lifecycle ─────────────────────────────────────────────────────
  systemd.services.catacomb-stack = {
    description = "Catacomb (Safe self-host) stack via docker compose";
    wantedBy = [ "multi-user.target" ];
    requires = [ "docker.service" ];
    after = [
      "docker.service"
      "network-online.target"
    ];
    wants = [ "network-online.target" ];

    path = [
      pkgs.docker
      pkgs.docker-compose
      pkgs.openssl
      pkgs.coreutils
    ];

    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = pkgs.writeShellScript "catacomb-stack-up" ''
        set -eu
        umask 077

        # Stage upstream's project tree under ${stateDir} so its relative
        # bind mounts (./data/<svc>-db, ./docker/nginx/nginx.conf,
        # container_env_files/<svc>.env) resolve to a writable directory
        # backed by the read-only nix store for static bits.
        mkdir -p ${stateDir}/data
        ln -sfn ${safe-infrastructure}/docker-compose.yml ${stateDir}/docker-compose.yml
        ln -sfn ${safe-infrastructure}/docker ${stateDir}/docker
        ln -sfn ${safe-infrastructure}/container_env_files ${stateDir}/container_env_files

        # Generate / reuse runtime secrets (idempotent).
        gen() {
          local f="${stateDir}/secrets/$1"
          [ -e "$f" ] || openssl rand -hex 32 > "$f"
          cat "$f"
        }
        DJANGO_SECRET=$(gen django_secret)
        CGW_AUTH_TOKEN=$(gen cgw_auth_token)
        POSTGRES_PASSWORD=$(gen postgres_password)
        DJANGO_SUPERUSER_PASSWORD=$(gen django_superuser_password)

        cat > ${envFile} <<EOF
        # Generated by NixOS — edits will be overwritten on next rebuild.
        ${versionEnvLines}
        REVERSE_PROXY_PORT=127.0.0.1:8000
        RPC_NODE_URL=${cfg.chains.etc.rpcUri}
        DJANGO_SECRET=$DJANGO_SECRET
        CGW_AUTH_TOKEN=$CGW_AUTH_TOKEN
        POSTGRES_PASSWORD=$POSTGRES_PASSWORD
        DJANGO_SUPERUSER_PASSWORD=$DJANGO_SUPERUSER_PASSWORD
        EOF
        chmod 600 ${envFile}

        ln -sfn ${override} ${overrideFile}

        ${composeExe} ${composeArgs} pull --quiet
        ${composeExe} ${composeArgs} up -d --remove-orphans
      '';
      ExecStop = pkgs.writeShellScript "catacomb-stack-down" ''
        ${composeExe} ${composeArgs} down --remove-orphans
      '';
    };
  };

  # ── Chain registration ───────────────────────────────────────────────────
  # Idempotent per chain in `catacomb.chains`. Posts to the internal nginx
  # the upstream stack stands up on 127.0.0.1:8000 → /cfg/api/v1/chains/.
  systemd.services.catacomb-chain-bootstrap =
    let
      inherit (cfg.branding) theme;
      payloads = lib.mapAttrsToList (
        _name: chain:
        builtins.toJSON {
          chainId = toString chain.chainId;
          inherit (chain) chainName shortName;
          rpcUri = {
            authentication = "NO_AUTHENTICATION";
            value = chain.rpcUri;
          };
          publicRpcUri = {
            authentication = "NO_AUTHENTICATION";
            value = chain.rpcUri;
          };
          safeAppsRpcUri = {
            authentication = "NO_AUTHENTICATION";
            value = chain.rpcUri;
          };
          inherit (chain) blockExplorerUriTemplate nativeCurrency transactionService;
          theme = { inherit (theme) textColor backgroundColor; };
        }
      ) cfg.chains;
    in
    {
      description = "Seed Catacomb chains into safe-config-service";
      wantedBy = [ "multi-user.target" ];
      after = [ "catacomb-stack.service" ];
      requires = [ "catacomb-stack.service" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };
      path = [ pkgs.curl ];
      script = ''
        set -eu
        token=$(cat ${stateDir}/secrets/cgw_auth_token)
        for i in $(seq 1 90); do
          curl --fail --silent http://127.0.0.1:8000/cfg/api/v1/about/ >/dev/null && break
          sleep 2
        done
      ''
      + lib.concatMapStringsSep "\n" (json: ''
        curl --fail --silent --show-error \
          -X POST -H 'Content-Type: application/json' \
          -H "Authorization: Bearer $token" \
          --data ${lib.escapeShellArg json} \
          http://127.0.0.1:8000/cfg/api/v1/chains/ || true
      '') payloads;
    };
}
