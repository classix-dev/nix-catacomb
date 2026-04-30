# Safe (gnosis-safe) self-hosting stack via OCI containers.
#
# Mirrors `safe-global/safe-infrastructure`'s docker-compose layout, driven
# from NixOS systemd units. Image versions track upstream `.env.sample` —
# bump deliberately.
#
# Status: SKETCH. Not yet booted end-to-end.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  versions = {
    ui = "v1.88.0";
    cgw = "v1.108.0";
    cfg = "v2.94.0";
    txs = "v6.3.0";
    events = "v1.3.0";
  };

  # Secrets live in /var/lib/catacomb/secrets/, generated on first boot by
  # the systemd oneshot below. Containers consume them via environmentFiles.
  secretsDir = "/var/lib/catacomb/secrets";
  envFile = name: "${secretsDir}/${name}.env";

  pgImage = "postgres:14-alpine";
  redisImage = "redis:alpine";
  rabbitImage = "rabbitmq:alpine";
  network = "catacomb";

  # All Safe containers join one user-defined podman network so they can
  # resolve each other by container name.
  withNet = c: c // { extraOptions = (c.extraOptions or [ ]) ++ [ "--network=${network}" ]; };

  # Bind container ports to loopback only — nginx is the sole ingress.
  bindLocal =
    host: container: c:
    c // { ports = [ "127.0.0.1:${toString host}:${toString container}" ]; };

  rpc = {
    etc = config.catacomb.chains.etc.rpcUri;
    mordor = config.catacomb.chains.mordor.rpcUri;
  };

  mkPostgres =
    name:
    withNet {
      image = pgImage;
      environment = {
        POSTGRES_USER = name;
        POSTGRES_DB = name;
      };
      environmentFiles = [ (envFile "postgres") ];
      volumes = [ "${name}-data:/var/lib/postgresql/data" ];
    };
in
{
  # ── Secrets bootstrap ────────────────────────────────────────────────────
  # Generates random secrets the first time the host boots, and idempotently
  # reuses them on subsequent boots. Replace with sops-nix / agenix when the
  # team is ready to manage secrets out-of-band.
  systemd.tmpfiles.rules = [
    "d ${secretsDir} 0700 root root -"
    "d /var/lib/catacomb 0755 root root -"
  ];

  systemd.services.catacomb-secrets-init = {
    description = "Generate Catacomb runtime secrets on first boot";
    wantedBy = [ "multi-user.target" ];
    before = [
      "podman.service"
    ]
    ++ map (c: "${c}.service") [
      "podman-cgw-db"
      "podman-cfg-db"
      "podman-txs-db"
      "podman-events-db"
      "podman-cfg-web"
      "podman-cgw-web"
      "podman-txs-web"
    ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    path = [
      pkgs.openssl
      pkgs.coreutils
    ];
    script = ''
      set -eu
      umask 077
      gen() {
        local f="${secretsDir}/$1"
        if [ ! -e "$f" ]; then
          openssl rand -hex 32 > "$f"
        fi
      }
      gen django_secret
      gen cgw_auth_token
      gen postgres_password

      # Compose env files consumed by environmentFiles below.
      pg=$(cat ${secretsDir}/postgres_password)
      django=$(cat ${secretsDir}/django_secret)
      cgw=$(cat ${secretsDir}/cgw_auth_token)

      cat > ${envFile "postgres"} <<EOF
      POSTGRES_PASSWORD=$pg
      EOF

      cat > ${envFile "django"} <<EOF
      DJANGO_SECRET_KEY=$django
      POSTGRES_PASSWORD=$pg
      DJANGO_SUPERUSER_PASSWORD=$pg
      CGW_FLUSH_TOKEN=$cgw
      EOF

      cat > ${envFile "cgw"} <<EOF
      AUTH_TOKEN=$cgw
      EOF

      chmod 600 ${secretsDir}/*.env
    '';
  };

  # ── OCI containers ───────────────────────────────────────────────────────
  virtualisation.oci-containers.containers = {

    # Databases / brokers
    cgw-db = mkPostgres "cgw";
    cfg-db = mkPostgres "cfg";
    txs-db = mkPostgres "txs";
    events-db = mkPostgres "events";

    cgw-redis = withNet { image = redisImage; };
    txs-redis = withNet { image = redisImage; };
    txs-rabbitmq = withNet { image = rabbitImage; };
    general-rabbitmq = withNet { image = rabbitImage; };

    # Config service (Django)
    cfg-web = bindLocal 8001 8001 (withNet {
      image = "safeglobal/safe-config-service:${versions.cfg}";
      environment = {
        PYTHONDONTWRITEBYTECODE = "true";
        DJANGO_ALLOWED_HOSTS = "*";
        POSTGRES_NAME = "cfg";
        POSTGRES_USER = "cfg";
        POSTGRES_HOST = "cfg-db";
        POSTGRES_PORT = "5432";
        DJANGO_SUPERUSER_USERNAME = "admin";
        DJANGO_SUPERUSER_EMAIL = "admin@${config.catacomb.domain}";
      };
      environmentFiles = [ (envFile "django") ];
      dependsOn = [ "cfg-db" ];
    });

    # Transaction service (Django + Celery) — mainnet only in this sketch.
    # Mordor instance is a TODO copy with its own DB / queues / RPC.
    txs-web = bindLocal 8000 8000 (withNet {
      image = "safeglobal/safe-transaction-service:${versions.txs}";
      environment = {
        PYTHONDONTWRITEBYTECODE = "true";
        DJANGO_ALLOWED_HOSTS = "*";
        ETHEREUM_NODE_URL = rpc.etc;
        ETHEREUM_TRACING_NODE_URL = rpc.etc;
        ETH_L2_NETWORK = "1";
        DATABASE_URL = "psql://txs:@txs-db:5432/txs"; # password injected via env file
        REDIS_URL = "redis://txs-redis:6379/0";
        CELERY_BROKER_URL = "amqp://guest:guest@txs-rabbitmq:5672//";
        EVENTS_QUEUE_URL = "amqp://guest:guest@general-rabbitmq:5672//";
      };
      environmentFiles = [ (envFile "django") ];
      dependsOn = [
        "txs-db"
        "txs-redis"
        "txs-rabbitmq"
      ];
    });

    txs-worker-indexer = withNet {
      image = "safeglobal/safe-transaction-service:${versions.txs}";
      environment = {
        WORKER_QUEUES = "default,indexing,processing";
        DATABASE_URL = "psql://txs:@txs-db:5432/txs";
        REDIS_URL = "redis://txs-redis:6379/0";
        CELERY_BROKER_URL = "amqp://guest:guest@txs-rabbitmq:5672//";
        ETHEREUM_NODE_URL = rpc.etc;
      };
      environmentFiles = [ (envFile "django") ];
      cmd = [ "docker/web/celery/worker/run.sh" ];
      dependsOn = [ "txs-web" ];
    };

    txs-worker-contracts-tokens = withNet {
      image = "safeglobal/safe-transaction-service:${versions.txs}";
      environment = {
        WORKER_QUEUES = "contracts,tokens";
        DATABASE_URL = "psql://txs:@txs-db:5432/txs";
        REDIS_URL = "redis://txs-redis:6379/0";
        CELERY_BROKER_URL = "amqp://guest:guest@txs-rabbitmq:5672//";
        ETHEREUM_NODE_URL = rpc.etc;
      };
      environmentFiles = [ (envFile "django") ];
      cmd = [ "docker/web/celery/worker/run.sh" ];
      dependsOn = [ "txs-worker-indexer" ];
    };

    txs-worker-notifications-webhooks = withNet {
      image = "safeglobal/safe-transaction-service:${versions.txs}";
      environment = {
        WORKER_QUEUES = "notifications,webhooks";
        DATABASE_URL = "psql://txs:@txs-db:5432/txs";
        REDIS_URL = "redis://txs-redis:6379/0";
        CELERY_BROKER_URL = "amqp://guest:guest@txs-rabbitmq:5672//";
        ETHEREUM_NODE_URL = rpc.etc;
      };
      environmentFiles = [ (envFile "django") ];
      cmd = [ "docker/web/celery/worker/run.sh" ];
      dependsOn = [ "txs-worker-indexer" ];
    };

    txs-scheduler = withNet {
      image = "safeglobal/safe-transaction-service:${versions.txs}";
      environment = {
        DATABASE_URL = "psql://txs:@txs-db:5432/txs";
        REDIS_URL = "redis://txs-redis:6379/0";
        CELERY_BROKER_URL = "amqp://guest:guest@txs-rabbitmq:5672//";
      };
      environmentFiles = [ (envFile "django") ];
      cmd = [ "docker/web/celery/scheduler/run.sh" ];
      dependsOn = [
        "txs-db"
        "txs-redis"
      ];
    };

    # Events service (Node)
    events-web = withNet {
      image = "safeglobal/safe-events-service:${versions.events}";
      environment = {
        DATABASE_URL = "postgresql://events:@events-db:5432/events";
        AMQP_URL = "amqp://guest:guest@general-rabbitmq:5672//";
      };
      environmentFiles = [ (envFile "django") ];
      dependsOn = [
        "events-db"
        "general-rabbitmq"
      ];
    };

    # Client Gateway (NestJS)
    cgw-web = bindLocal 3000 3000 (withNet {
      image = "safeglobal/safe-client-gateway-nest:${versions.cgw}";
      environment = {
        REDIS_HOST = "cgw-redis";
        REDIS_PORT = "6379";
        CONFIG_SERVICE_URI = "http://cfg-web:8001";
      };
      environmentFiles = [ (envFile "cgw") ];
      dependsOn = [
        "cgw-redis"
        "cfg-web"
      ];
    });

    # Web UI
    ui = bindLocal 8080 8080 (withNet {
      image = "safeglobal/safe-wallet-web:${versions.ui}";
      environment = {
        NEXT_PUBLIC_GATEWAY_URL_PRODUCTION = "https://client.${config.catacomb.domain}";
        NEXT_PUBLIC_DEFAULT_MAINNET_CHAIN_ID = toString config.catacomb.chains.etc.chainId;
        NEXT_PUBLIC_IS_PRODUCTION = "true";
      };
      dependsOn = [ "cgw-web" ];
    });
  };

  # Create the user-defined podman network before any container starts.
  systemd.services."podman-network-${network}" = {
    description = "Podman network for the Catacomb stack";
    wantedBy = [ "multi-user.target" ];
    after = [ "podman.service" ];
    before = map (c: "podman-${c}.service") (
      lib.attrNames config.virtualisation.oci-containers.containers
    );
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = "${pkgs.podman}/bin/podman network create --ignore ${network}";
    };
  };

  # ── Chain bootstrap ──────────────────────────────────────────────────────
  # Idempotently registers every chain in `catacomb.chains` with cfg-service.
  # JSON shape is best-effort — verify against the live admin API on first
  # successful deploy.
  systemd.services.catacomb-chain-bootstrap =
    let
      inherit (config.catacomb.branding) theme;
      payloads = lib.mapAttrsToList (
        _name: chain:
        builtins.toJSON {
          chainId = toString chain.chainId;
          inherit (chain) chainName;
          inherit (chain) shortName;
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
          inherit (chain) blockExplorerUriTemplate;
          inherit (chain) nativeCurrency;
          inherit (chain) transactionService;
          theme = {
            inherit (theme) textColor backgroundColor;
          };
        }
      ) config.catacomb.chains;
    in
    {
      description = "Seed Catacomb chains into safe-config-service";
      wantedBy = [ "multi-user.target" ];
      after = [ "podman-cfg-web.service" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };
      path = [ pkgs.curl ];
      script = ''
        set -eu
        token=$(cat ${secretsDir}/cgw_auth_token)
        # Wait for cfg-service to come up (max ~2 min).
        for i in $(seq 1 60); do
          if curl --fail --silent http://127.0.0.1:8001/api/v1/about/ > /dev/null; then
            break
          fi
          sleep 2
        done
      ''
      + lib.concatMapStringsSep "\n" (json: ''
        curl --fail --silent --show-error \
          -X POST \
          -H 'Content-Type: application/json' \
          -H "Authorization: Bearer $token" \
          --data ${lib.escapeShellArg json} \
          http://127.0.0.1:8001/api/v1/chains/ || true
      '') payloads;
    };
}
