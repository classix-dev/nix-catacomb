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

  secretsDir = "/var/lib/catacomb/secrets";
  envFile = name: "${secretsDir}/${name}.env";

  pgImage = "postgres:14-alpine";
  redisImage = "redis:alpine";
  rabbitImage = "rabbitmq:alpine";
  network = "catacomb";

  withNet = c: c // { extraOptions = (c.extraOptions or [ ]) ++ [ "--network=${network}" ]; };

  # Upstream defaults — POSTGRES_PASSWORD here is overridden per-service via
  # the secrets env file. POSTGRES_USER/DB stay 'postgres' to match every
  # service's hard-coded DATABASE_URL = psql://postgres:...@<svc>-db/postgres.
  pgEnv = {
    POSTGRES_USER = "postgres";
    POSTGRES_DB = "postgres";
  };

  mkPostgres =
    name:
    withNet {
      image = pgImage;
      environment = pgEnv;
      environmentFiles = [ (envFile "postgres") ];
      volumes = [ "${name}-data:/var/lib/postgresql/data" ];
    };

  # Shared volumes for gunicorn unix sockets (txs-web ↔ nginx, cfg-web ↔ nginx).
  # Names match upstream docker-compose for symmetry.
  sharedTxs = "nginx-shared-txs";
  sharedCfg = "nginx-shared-cfg";

  # Upstream txs.env, inlined. RPC + DATABASE password come from environmentFiles.
  txsBaseEnv = {
    PYTHONPATH = "/app/";
    DJANGO_SETTINGS_MODULE = "config.settings.production";
    DEBUG = "0";
    ETH_L2_NETWORK = "1";
    REDIS_URL = "redis://txs-redis:6379/0";
    CELERY_BROKER_URL = "amqp://guest:guest@txs-rabbitmq/";
    DJANGO_ALLOWED_HOSTS = "*";
    FORCE_SCRIPT_NAME = "/txs/";
    CSRF_TRUSTED_ORIGINS = "https://${config.catacomb.domain}";
    EVENTS_QUEUE_URL = "amqp://general-rabbitmq:5672";
    EVENTS_QUEUE_ASYNC_CONNECTION = "True";
    EVENTS_QUEUE_EXCHANGE_NAME = "safe-transaction-service-events";
    ETHEREUM_NODE_URL = config.catacomb.chains.etc.rpcUri;
  };

  # Upstream's nginx.conf (paths-based routing). Verbatim copy of
  # safe-global/safe-infrastructure docker/nginx/nginx.conf.
  internalNginxConf = pkgs.writeText "catacomb-internal-nginx.conf" ''
    worker_processes 1;
    events {
      worker_connections 2000;
      accept_mutex off;
      use epoll;
    }
    http {
      include mime.types;
      default_type application/octet-stream;
      sendfile on;

      upstream txs_app_server   { server unix:/nginx-txs/gunicorn.socket fail_timeout=0; keepalive 32; }
      upstream cfg_app_server   { ip_hash; server unix:/nginx-cfg/gunicorn.socket fail_timeout=0; keepalive 32; }
      upstream cgw_app_server   { ip_hash; server cgw-web:3000 fail_timeout=0; keepalive 32; }
      upstream events_app_server { ip_hash; server events-web:3000 fail_timeout=0; keepalive 32; }
      upstream ui_server        { ip_hash; server ui:8080 fail_timeout=0; keepalive 32; }

      server {
        access_log off;
        listen 8000 deferred;
        charset utf-8;
        keepalive_timeout 75s;

        gzip on;
        gzip_min_length 1000;
        gzip_comp_level 2;
        gzip_types text/plain text/css application/json application/javascript application/x-javascript text/javascript text/xml application/xml application/rss+xml application/atom+xml application/rdf+xml;
        gzip_disable "MSIE [1-6]\.";

        location /txs/static { alias /nginx-txs/staticfiles; expires 365d; }
        location /txs/ {
          proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
          proxy_set_header X-Forwarded-Proto $scheme;
          proxy_set_header Host $host;
          proxy_redirect off;
          proxy_pass http://txs_app_server/;
        }

        location /cfg/static { alias /nginx-cfg/staticfiles; expires 365d; }
        location /cfg/ {
          proxy_set_header Host $host;
          proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
          proxy_set_header X-Forwarded-Proto $http_x_forwarded_proto;
          proxy_redirect off;
          proxy_pass http://cfg_app_server/;
          proxy_connect_timeout 60s;
          proxy_read_timeout 60s;
        }

        location /cgw/ {
          proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
          proxy_set_header X-Forwarded-Proto $scheme;
          proxy_set_header Host $host;
          proxy_redirect off;
          proxy_pass http://cgw_app_server/;
        }

        location /events/ {
          proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
          proxy_set_header X-Forwarded-Proto $scheme;
          proxy_set_header Host $host;
          proxy_redirect off;
          proxy_pass http://events_app_server/events/;
        }

        location / {
          proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
          proxy_set_header X-Forwarded-Proto $scheme;
          proxy_set_header Host $host;
          proxy_redirect off;
          proxy_pass http://ui_server/;
        }
      }
    }
  '';
in
{
  systemd.tmpfiles.rules = [
    "d ${secretsDir} 0700 root root -"
    "d /var/lib/catacomb 0755 root root -"
  ];

  # Generate runtime secrets at first boot, write per-service env files
  # consumed via environmentFiles below.
  systemd.services.catacomb-secrets-init = {
    description = "Generate Catacomb runtime secrets on first boot";
    wantedBy = [ "multi-user.target" ];
    before = map (c: "podman-${c}.service") [
      "cgw-db"
      "cfg-db"
      "txs-db"
      "events-db"
      "cfg-web"
      "cgw-web"
      "txs-web"
      "events-web"
      "ui"
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
        [ -e "$f" ] || openssl rand -hex 32 > "$f"
      }
      gen django_secret
      gen cgw_auth_token
      gen postgres_password

      pg=$(cat ${secretsDir}/postgres_password)
      django=$(cat ${secretsDir}/django_secret)
      cgw=$(cat ${secretsDir}/cgw_auth_token)

      cat > ${envFile "postgres"} <<EOF
      POSTGRES_PASSWORD=$pg
      EOF

      cat > ${envFile "cfg"} <<EOF
      SECRET_KEY=$django
      POSTGRES_PASSWORD=$pg
      DJANGO_SUPERUSER_PASSWORD=$pg
      CGW_AUTH_TOKEN=$cgw
      EOF

      cat > ${envFile "txs"} <<EOF
      DJANGO_SECRET_KEY=$django
      DATABASE_URL=psql://postgres:$pg@txs-db:5432/postgres
      EOF

      cat > ${envFile "cgw"} <<EOF
      AUTH_TOKEN=$cgw
      EOF

      cat > ${envFile "events"} <<EOF
      DATABASE_URL=psql://postgres:$pg@events-db:5432/postgres
      EOF

      chmod 600 ${secretsDir}/*.env
    '';
  };

  virtualisation.oci-containers.containers = {

    # ── Databases / brokers ─────────────────────────────────────────────
    cgw-db = mkPostgres "cgw";
    cfg-db = mkPostgres "cfg";
    events-db = mkPostgres "events";
    txs-db = (mkPostgres "txs") // {
      cmd = [
        "-c"
        "max_connections=250"
      ];
    };

    cgw-redis = withNet { image = redisImage; };
    txs-redis = withNet { image = redisImage; };
    txs-rabbitmq = withNet { image = rabbitImage; };
    general-rabbitmq = withNet { image = rabbitImage; };

    # ── Config service (Django, gunicorn → unix socket) ─────────────────
    cfg-web = withNet {
      image = "safeglobal/safe-config-service:${versions.cfg}";
      environment = {
        PYTHONDONTWRITEBYTECODE = "true";
        DEBUG = "true";
        ROOT_LOG_LEVEL = "INFO";
        DJANGO_ALLOWED_HOSTS = "*";
        GUNICORN_BIND_PORT = "8001";
        DOCKER_NGINX_VOLUME_ROOT = "/nginx";
        GUNICORN_BIND_SOCKET = "unix:/nginx/gunicorn.socket";
        NGINX_ENVSUBST_OUTPUT_DIR = "/etc/nginx/";
        POSTGRES_USER = "postgres";
        POSTGRES_NAME = "postgres";
        POSTGRES_HOST = "cfg-db";
        POSTGRES_PORT = "5432";
        DJANGO_SUPERUSER_USERNAME = "admin";
        DJANGO_SUPERUSER_EMAIL = "admin@${config.catacomb.domain}";
        DJANGO_OTP_ADMIN = "false";
        DEFAULT_FILE_STORAGE = "django.core.files.storage.FileSystemStorage";
        FORCE_SCRIPT_NAME = "/cfg/";
        CGW_URL = "http://nginx:8000/cgw";
        CSRF_TRUSTED_ORIGINS = "https://${config.catacomb.domain}";
      };
      environmentFiles = [ (envFile "cfg") ];
      volumes = [ "${sharedCfg}:/nginx" ];
      dependsOn = [ "cfg-db" ];
    };

    # ── Transaction service (Django + Celery, gunicorn → unix socket) ───
    txs-web = withNet {
      image = "safeglobal/safe-transaction-service:${versions.txs}";
      environment = txsBaseEnv;
      environmentFiles = [ (envFile "txs") ];
      volumes = [ "${sharedTxs}:/nginx" ];
      cmd = [ "docker/web/run_web.sh" ];
      workdir = "/app";
      dependsOn = [ "txs-worker-indexer" ];
    };

    txs-worker-indexer = withNet {
      image = "safeglobal/safe-transaction-service:${versions.txs}";
      environment = txsBaseEnv // {
        WORKER_QUEUES = "default,indexing,processing";
        RUN_MIGRATIONS = "1";
      };
      environmentFiles = [ (envFile "txs") ];
      cmd = [ "docker/web/celery/worker/run.sh" ];
      dependsOn = [
        "txs-db"
        "txs-redis"
      ];
    };

    txs-worker-contracts-tokens = withNet {
      image = "safeglobal/safe-transaction-service:${versions.txs}";
      environment = txsBaseEnv // {
        WORKER_QUEUES = "contracts,tokens";
      };
      environmentFiles = [ (envFile "txs") ];
      cmd = [ "docker/web/celery/worker/run.sh" ];
      dependsOn = [ "txs-worker-indexer" ];
    };

    txs-worker-notifications-webhooks = withNet {
      image = "safeglobal/safe-transaction-service:${versions.txs}";
      environment = txsBaseEnv // {
        WORKER_QUEUES = "notifications,webhooks";
      };
      environmentFiles = [ (envFile "txs") ];
      cmd = [ "docker/web/celery/worker/run.sh" ];
      dependsOn = [ "txs-worker-indexer" ];
    };

    txs-scheduler = withNet {
      image = "safeglobal/safe-transaction-service:${versions.txs}";
      environment = txsBaseEnv;
      environmentFiles = [ (envFile "txs") ];
      cmd = [ "docker/web/celery/scheduler/run.sh" ];
      dependsOn = [
        "txs-db"
        "txs-redis"
      ];
    };

    # ── Events service (Node) ───────────────────────────────────────────
    events-web = withNet {
      image = "safeglobal/safe-events-service:${versions.events}";
      environment = {
        AMQP_URL = "amqp://general-rabbitmq:5672";
        AMQP_EXCHANGE = "safe-transaction-service-events";
        AMQP_QUEUE = "safe-events-service";
        ADMIN_EMAIL = "admin@${config.catacomb.domain}";
        ADMIN_PASSWORD = "admin"; # internal-only API; CGW talks to it via shared network
        WEBHOOKS_CACHE_TTL = "300000";
        NODE_ENV = "production";
        URL_BASE_PATH = "/events";
      };
      environmentFiles = [ (envFile "events") ];
      dependsOn = [
        "events-db"
        "general-rabbitmq"
      ];
    };

    # ── Client Gateway (NestJS) ─────────────────────────────────────────
    cgw-web = withNet {
      image = "safeglobal/safe-client-gateway-nest:${versions.cgw}";
      environment = {
        HTTP_CLIENT_REQUEST_TIMEOUT_MILLISECONDS = "60000";
        SAFE_CONFIG_BASE_URI = "http://nginx:8000/cfg";
        ALLOW_CORS = "true";
        REDIS_HOST = "cgw-redis";
        LOG_LEVEL = "info";
      };
      environmentFiles = [ (envFile "cgw") ];
      dependsOn = [ "cgw-redis" ];
    };

    # ── Web UI ──────────────────────────────────────────────────────────
    ui = withNet {
      image = "safeglobal/safe-wallet-web:${versions.ui}";
      environment = {
        NEXT_PUBLIC_GATEWAY_URL_PRODUCTION = "https://${config.catacomb.domain}/cgw";
        NEXT_PUBLIC_DEFAULT_MAINNET_CHAIN_ID = toString config.catacomb.chains.etc.chainId;
        NEXT_PUBLIC_IS_PRODUCTION = "true";
      };
    };

    # ── Internal nginx (sole ingress to the stack) ──────────────────────
    nginx = withNet {
      image = "nginx:alpine";
      ports = [ "127.0.0.1:8000:8000" ];
      volumes = [
        "${internalNginxConf}:/etc/nginx/nginx.conf:ro"
        "${sharedTxs}:/nginx-txs"
        "${sharedCfg}:/nginx-cfg"
      ];
      dependsOn = [
        "txs-web"
        "cfg-web"
        "cgw-web"
        "events-web"
        "ui"
      ];
    };
  };

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

  # Idempotent chain registration via internal nginx → /cfg/api/v1/chains/.
  systemd.services.catacomb-chain-bootstrap =
    let
      inherit (config.catacomb.branding) theme;
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
      ) config.catacomb.chains;
    in
    {
      description = "Seed Catacomb chains into safe-config-service";
      wantedBy = [ "multi-user.target" ];
      after = [ "podman-nginx.service" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };
      path = [ pkgs.curl ];
      script = ''
        set -eu
        token=$(cat ${secretsDir}/cgw_auth_token)
        for i in $(seq 1 60); do
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
