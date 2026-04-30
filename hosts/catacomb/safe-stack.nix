# Safe (gnosis-safe) self-hosting stack via OCI containers.
#
# Mirrors `safe-global/safe-infrastructure`'s docker-compose layout, driven
# from NixOS systemd units. Image versions track upstream `.env.sample` —
# bump deliberately.
#
# Status: SKETCH. Not booted. Chain-bootstrap (registering chains 61 + 63 in
# the config service) is a TODO.
{ config, lib, pkgs, ... }:
let
  # Pin every image. Bumping these is how we "update" the deploy.
  versions = {
    ui = "v1.70.0"; # safe-wallet-web (upstream — NOT etclabscore fork)
    cgw = "v2.130.0"; # safe-client-gateway-nest
    cfg = "v2.108.0"; # safe-config-service
    txs = "v4.46.0"; # safe-transaction-service
    events = "v1.32.0"; # safe-events-service
  };

  # Internal shared secrets. In production these come from a secret manager
  # (sops-nix / agenix). Left as plain strings here so the sketch boots locally
  # without secret tooling — DO NOT ship as-is.
  secrets = {
    djangoSecret = "REPLACE_ME_django_secret";
    cgwAuthToken = "REPLACE_ME_cgw_auth_token";
    pgPassword = "REPLACE_ME_postgres";
  };

  # Shared chain config. Catacomb supports ETC mainnet + Mordor.
  rpc = {
    etc = "https://rpc.mainnet.etccooperative.org";
    mordor = "https://rpc.mordor.etccooperative.org";
  };

  # Helpers
  pgImage = "postgres:14-alpine";
  redisImage = "redis:alpine";
  rabbitImage = "rabbitmq:alpine";

  mkPostgres = name: {
    image = pgImage;
    environment = {
      POSTGRES_USER = name;
      POSTGRES_PASSWORD = secrets.pgPassword;
      POSTGRES_DB = name;
    };
    volumes = [ "${name}-data:/var/lib/postgresql/data" ];
  };
in
{
  # All Safe containers share an internal bridge network. nginx (defined in
  # nginx.nix) is the only thing that talks to the outside world.
  virtualisation.oci-containers.containers = {

    # ── Databases / brokers ────────────────────────────────────────────────
    cgw-db = mkPostgres "cgw";
    cfg-db = mkPostgres "cfg";
    txs-db = mkPostgres "txs";
    events-db = mkPostgres "events";

    cgw-redis = {
      image = redisImage;
    };
    txs-redis = {
      image = redisImage;
    };

    txs-rabbitmq = {
      image = rabbitImage;
    };
    general-rabbitmq = {
      image = rabbitImage;
    };

    # ── Config service (Django) ────────────────────────────────────────────
    cfg-web = {
      image = "safeglobal/safe-config-service:${versions.cfg}";
      environment = {
        PYTHONDONTWRITEBYTECODE = "true";
        DJANGO_SECRET_KEY = secrets.djangoSecret;
        DJANGO_ALLOWED_HOSTS = "*";
        POSTGRES_NAME = "cfg";
        POSTGRES_USER = "cfg";
        POSTGRES_PASSWORD = secrets.pgPassword;
        POSTGRES_HOST = "cfg-db";
        POSTGRES_PORT = "5432";
        # Initial superuser, used to seed chains via the admin API.
        DJANGO_SUPERUSER_USERNAME = "admin";
        DJANGO_SUPERUSER_PASSWORD = secrets.pgPassword;
        DJANGO_SUPERUSER_EMAIL = "admin@example.invalid";
        CGW_FLUSH_TOKEN = secrets.cgwAuthToken;
      };
      dependsOn = [ "cfg-db" ];
    };

    # ── Transaction service (Django + Celery) ──────────────────────────────
    # One full set per chain. Sketch shows mainnet only; Mordor is a copy with
    # different env + DB + queue names. TODO before deploy: parameterize.
    txs-web = {
      image = "safeglobal/safe-transaction-service:${versions.txs}";
      environment = {
        PYTHONDONTWRITEBYTECODE = "true";
        DJANGO_SECRET_KEY = secrets.djangoSecret;
        DJANGO_ALLOWED_HOSTS = "*";
        ETHEREUM_NODE_URL = rpc.etc;
        ETHEREUM_TRACING_NODE_URL = rpc.etc;
        ETH_L2_NETWORK = "1"; # skip tracing-only paths if RPC lacks `trace_*`
        DATABASE_URL = "psql://txs:${secrets.pgPassword}@txs-db:5432/txs";
        REDIS_URL = "redis://txs-redis:6379/0";
        CELERY_BROKER_URL = "amqp://guest:guest@txs-rabbitmq:5672//";
        EVENTS_QUEUE_URL = "amqp://guest:guest@general-rabbitmq:5672//";
      };
      dependsOn = [
        "txs-db"
        "txs-redis"
        "txs-rabbitmq"
      ];
    };

    txs-worker-indexer = {
      image = "safeglobal/safe-transaction-service:${versions.txs}";
      environment = {
        WORKER_QUEUES = "default,indexing,processing";
        DATABASE_URL = "psql://txs:${secrets.pgPassword}@txs-db:5432/txs";
        REDIS_URL = "redis://txs-redis:6379/0";
        CELERY_BROKER_URL = "amqp://guest:guest@txs-rabbitmq:5672//";
        ETHEREUM_NODE_URL = rpc.etc;
      };
      cmd = [
        "docker/web/celery/worker/run.sh"
      ];
      dependsOn = [ "txs-web" ];
    };

    txs-worker-contracts-tokens = {
      image = "safeglobal/safe-transaction-service:${versions.txs}";
      environment = {
        WORKER_QUEUES = "contracts,tokens";
        DATABASE_URL = "psql://txs:${secrets.pgPassword}@txs-db:5432/txs";
        REDIS_URL = "redis://txs-redis:6379/0";
        CELERY_BROKER_URL = "amqp://guest:guest@txs-rabbitmq:5672//";
        ETHEREUM_NODE_URL = rpc.etc;
      };
      cmd = [ "docker/web/celery/worker/run.sh" ];
      dependsOn = [ "txs-worker-indexer" ];
    };

    txs-worker-notifications-webhooks = {
      image = "safeglobal/safe-transaction-service:${versions.txs}";
      environment = {
        WORKER_QUEUES = "notifications,webhooks";
        DATABASE_URL = "psql://txs:${secrets.pgPassword}@txs-db:5432/txs";
        REDIS_URL = "redis://txs-redis:6379/0";
        CELERY_BROKER_URL = "amqp://guest:guest@txs-rabbitmq:5672//";
        ETHEREUM_NODE_URL = rpc.etc;
      };
      cmd = [ "docker/web/celery/worker/run.sh" ];
      dependsOn = [ "txs-worker-indexer" ];
    };

    txs-scheduler = {
      image = "safeglobal/safe-transaction-service:${versions.txs}";
      environment = {
        DATABASE_URL = "psql://txs:${secrets.pgPassword}@txs-db:5432/txs";
        REDIS_URL = "redis://txs-redis:6379/0";
        CELERY_BROKER_URL = "amqp://guest:guest@txs-rabbitmq:5672//";
      };
      cmd = [ "docker/web/celery/scheduler/run.sh" ];
      dependsOn = [
        "txs-db"
        "txs-redis"
      ];
    };

    # ── Events service (Node) ──────────────────────────────────────────────
    events-web = {
      image = "safeglobal/safe-events-service:${versions.events}";
      environment = {
        DATABASE_URL = "postgresql://events:${secrets.pgPassword}@events-db:5432/events";
        AMQP_URL = "amqp://guest:guest@general-rabbitmq:5672//";
      };
      dependsOn = [
        "events-db"
        "general-rabbitmq"
      ];
    };

    # ── Client Gateway (NestJS, despite the older "rust" naming) ───────────
    cgw-web = {
      image = "safeglobal/safe-client-gateway-nest:${versions.cgw}";
      environment = {
        REDIS_HOST = "cgw-redis";
        REDIS_PORT = "6379";
        CONFIG_SERVICE_URI = "http://cfg-web:8001";
        AUTH_TOKEN = secrets.cgwAuthToken;
        # The CGW reads chain metadata (RPC, tx-service URL, theme, etc.) from
        # cfg-service at runtime, so no per-chain env is needed here.
      };
      dependsOn = [
        "cgw-redis"
        "cfg-web"
      ];
    };

    # ── Web UI ─────────────────────────────────────────────────────────────
    ui = {
      image = "safeglobal/safe-wallet-web:${versions.ui}";
      environment = {
        # Catacomb defaults — UI is otherwise chain-agnostic.
        NEXT_PUBLIC_GATEWAY_URL_PRODUCTION = "https://client.catacomb.example/cgw";
        NEXT_PUBLIC_DEFAULT_MAINNET_CHAIN_ID = "61";
        NEXT_PUBLIC_IS_PRODUCTION = "true";
        # NEXT_PUBLIC_WC_PROJECT_ID = ""; # WalletConnect — fill in if needed.
      };
      dependsOn = [ "cgw-web" ];
    };
  };

  # Idempotently register every chain in `catacomb.chains` with safe-config-
  # service. Theme colors come from `catacomb.branding.theme`. Untested —
  # exact JSON shape may need tweaking against the running cfg-service API.
  systemd.services.catacomb-chain-bootstrap =
    let
      theme = config.catacomb.branding.theme;
      payloads = lib.mapAttrsToList (
        _name: chain:
        builtins.toJSON {
          chainId = toString chain.chainId;
          chainName = chain.chainName;
          shortName = chain.shortName;
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
          blockExplorerUriTemplate = chain.blockExplorerUriTemplate;
          nativeCurrency = chain.nativeCurrency;
          transactionService = chain.transactionService;
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
      script = lib.concatMapStringsSep "\n" (json: ''
        curl --fail --silent --show-error \
          -X POST \
          -H 'Content-Type: application/json' \
          -H "Authorization: Bearer ${secrets.cgwAuthToken}" \
          --data ${lib.escapeShellArg json} \
          http://127.0.0.1:8001/api/v1/chains/ || true
      '') payloads;
    };
}
