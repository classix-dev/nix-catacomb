# nix-catacomb

Nix flake that deploys a self-hosted [Safe](https://safe.global) multi-sig
wallet onto a single VM, branded and configured via Nix module options.

The default chain is **Ethereum Classic** (61), branded as
*Catacomb Multisig Classix Edition*; both are overrideable.

The stack is upstream `safe-global/safe-infrastructure`'s docker-compose
project run verbatim against a NixOS-managed Docker daemon, plus a
Nix-built static UI served by the host nginx, plus an idempotent
chain-bootstrap oneshot that seeds `safe-config-service`. Deployed onto a
fresh VM by [nixos-anywhere](https://github.com/nix-community/nixos-anywhere)
with disk layout driven by [disko](https://github.com/nix-community/disko).

## Why Nix?

The upstream reference deployment is [`safe-global/safe-infrastructure`](https://github.com/safe-global/safe-infrastructure) — *"one `docker-compose.yml` to rule them all."* nix-catacomb runs that same compose stack verbatim, but lifts the frontend out of Docker and runs everything against NixOS. The most useful thing that buys is turning the wallet UI into a **hash**: instead of a `safeglobal/safe-wallet-web` container that runs `next build` at boot, the frontend is built reproducibly from `flake.lock` and served by host nginx straight from a **read-only, content-addressed `/nix/store/<hash>-...` path**.

### What it buys you

- **Frontend tamper-resistance.** The Nix store is mounted read-only at the kernel level. Modifying the served bundle requires a new build with a new hash; in-place edits aren't a path.
- **Hash-pinned supply chain.** Upstream's `.env.sample` pulls every Safe service at `:latest`; here we pin exact image tags (see `hosts/catacomb/safe-stack.nix`) and lock every nixpkgs commit, fetched tarball, and transitive dep in `flake.lock`. The "auto-pull a malicious 1.0.1" class (event-stream, ua-parser-js, colors.js) is structurally impossible without an explicit `nix flake update`.
- **Deterministic, composable patch overlays.** Catacomb branding (`pkgs/catacomb-branding/patches/0001-catacomb-branding.patch`) is layered at build time over a hash-pinned upstream `safe-wallet-monorepo`. Same patch + same upstream → same bundle hash, every time. The full divergence from stock Safe is one diff; no vendored fork to keep in sync.
- **Server has only what's declared.** NixOS ships no leftover distro utilities and no container-base shells or package managers — every binary, port, service, and user is in `hosts/catacomb/*.nix`, reviewable in a PR diff.
- **No JS build runs on the host.** Upstream's `safeglobal/safe-wallet-web` container runs `yarn build` (a Next.js compile that executes hundreds of npm packages' build hooks) every time it starts. Here, that compile happens in a Nix sandbox at deploy time elsewhere; the production VM only serves static files.
- **Atomic rollback.** `nixos-rebuild --rollback` reverts kernel + packages + configs together; a botched deploy is one command back to the prior generation.

### What it doesn't buy you

- **A trustworthy upstream.** Pinning prevents auto-pulling a poisoned commit; it doesn't review the next `nix flake update`. A malicious PR upstream is faithfully built into a poisoned bundle every rebuilder agrees on. Human review at bump time is the real defense.
- **The backend.** `cgw-web` / `cfg-web` / `txs-web` / `events-web` plus Postgres / Redis / RabbitMQ are still pulled as Docker images; a compromised gateway can misrepresent what the UI shows for signing. **Nixifying the backend is on the roadmap.**
- **Build-time `postinstall` scripts.** The Nix build sandbox blocks network and ambient state but still executes upstream build code; a malicious `postinstall` can plant code in the bundle.
- **Root on the host, TLS / DNS / CA, the user's browser / OS / hardware wallet.** Out of scope for deploy tooling.

## Layout

```
flake.nix                       inputs, devShell, nixosModules.catacomb, packages
hosts/catacomb/
  default.nix                   base NixOS (boot, ssh, docker, firewall)
  options.nix                   declares every catacomb.* option
  defaultConfig.nix             defaults for every option (one obvious place)
  disko.nix                     single-disk BIOS layout
  safe-stack.nix                upstream safe-infrastructure compose stack
  override.yml.tmpl             per-deploy compose override (env, image pins, ui-stub)
  nginx.nix                     TLS termination + ACME wrapper
  ui.nix                        host-served static UI + /assets/ + backend fanout
pkgs/
  safe-wallet-web/              static `next export` build (pure: src + env in, UI out)
  catacomb-branding/            branding overlay applied to safe-wallet-web src
    patches/                    React/CSS patch (header wordmark, footer, modal, favicon)
    fonts/                      Michroma + Space Grotesk webfonts
    assets/
      etc-logo.svg              served at /assets/etc-logo.svg; default favicon SVG
```

The branding overlay is toggled by `catacomb.branding.enable` (default
`true`). When false, the wallet builds vanilla Safe with only
`branding.appName` swapped via the upstream-supported
`NEXT_PUBLIC_BRAND_NAME`. When true, the patch + fonts + favicon land
in the bundle and `branding.{tagline,notification,githubRepoLink,footerLinks,faviconSvg}`
all become live.

## Deploying guide

> Just ask your LLM agent to get Nix set up and point her at this repo.

This repo is a *library* flake — it exposes `nixosModules.catacomb` and a
`packages.safe-wallet-web-static` derivation, but it doesn't deploy itself.
Wrap it in a small consumer flake that pins the library and supplies your
domain, ACME email, and SSH keys. A worked example lives at
[`consumer.example.nix`](./consumer.example.nix); it includes the
DigitalOcean bootstrap (cloud-init + disko collisions) and commented
override blocks for every `catacomb.*` option.
<!-- TODO: link to a public sample deployment flake once one is published. -->


### 1. Create your consumer flake

Outside of this repo:

```sh
mkdir my-catacomb && cd my-catacomb
cp /path/to/nix-catacomb/consumer.example.nix flake.nix
$EDITOR flake.nix      # set domain, acmeEmail, sshAuthorizedKeys
nix flake lock
```

Required: `domain`, `acmeEmail`, `sshAuthorizedKeys`. Everything else
inherits from `hosts/catacomb/defaultConfig.nix` in the library.

### 2. Provision a VM

Any provider works — minimum recommended specs are below. Provision a fresh
host with **Ubuntu / Debian** (or anything `nixos-anywhere` can kexec from)
and your SSH key installed for `root`. You'll need its IP address.

### 3. Point DNS at the VM

Two records on the apex domain you set in `config.nix`:

| Record                   | Type | Value          |
|--------------------------|------|----------------|
| `<your-domain>`          | A    | `<vm-ip>`      |
| `*.<your-domain>`        | A    | `<vm-ip>`      |

Wait for propagation before the next step — ACME will fail to issue
certificates if the DNS records don't yet resolve to the VM.

### 4. Install with `nixos-anywhere`

```sh
nix run github:nix-community/nixos-anywhere -- \
  --flake .#catacomb \
  --target-host root@<vm-ip>
```

This kexecs into the NixOS installer, runs `disko` to partition the disk,
installs the system, and reboots. First boot generates secrets to
`/var/lib/catacomb/secrets/` and pulls all `safeglobal/*` container images.

### 5. Subsequent deploys

After editing any module or your consumer flake:

```sh
nixos-rebuild switch --flake .#catacomb --target-host root@<vm-ip>
```

### 6. Updating

```sh
nix flake update                              # bump nix-catacomb (and transitively nixpkgs etc.)
nixos-rebuild switch --flake .#catacomb --target-host root@<vm-ip>
```

Image version pins live in the library's `hosts/catacomb/safe-stack.nix`
(`UI_VERSION`, `CGW_VERSION`, `CFG_VERSION`, `TXS_VERSION`,
`EVENTS_VERSION`); bump them there and submit a PR if you want them
upstreamed.

## What gets deployed

Per [`safe-global/safe-infrastructure`](https://github.com/safe-global/safe-infrastructure),
mirrored into NixOS systemd units:

| Tier         | Components                                                                 |
|--------------|----------------------------------------------------------------------------|
| Frontend     | static [safe-wallet-monorepo](https://github.com/safe-global/safe-wallet-monorepo) build (Nix-built `next export`), served by host nginx |
| Gateway      | `cgw-web` ([safe-client-gateway](https://github.com/safe-global/safe-client-gateway)), `cgw-redis`, `cgw-db` |
| Config       | `cfg-web` ([safe-config-service](https://github.com/safe-global/safe-config-service)), `cfg-db` |
| Transactions | `txs-web` ([safe-transaction-service](https://github.com/safe-global/safe-transaction-service)), 3× workers, scheduler, `txs-db`, `txs-redis`, `txs-rabbitmq` |
| Events       | `events-web`, `events-db`, `general-rabbitmq`                              |

### Frontend

`safe-wallet-monorepo` is pinned via the `safe-wallet-web` flake input
(release tag `web-v1.88.0` at the time of writing) and built statically
by `pkgs/safe-wallet-web`. The output is a directory of HTML/JS/CSS that
the host nginx serves directly from the Nix store — no UI container, no
runtime build on the droplet.

Per-deploy values are baked at build time via `NEXT_PUBLIC_*` env vars,
which Next.js inlines into the compiled bundle:

| Env var                                | Source                                  |
|----------------------------------------|-----------------------------------------|
| `NEXT_PUBLIC_BRAND_NAME`               | `catacomb.branding.appName`             |
| `NEXT_PUBLIC_GATEWAY_URL_PRODUCTION`   | `https://<domain>/cgw`                  |
| `NEXT_PUBLIC_DEFAULT_MAINNET_CHAIN_ID` | `catacomb.chains.etc.chainId`           |
| `NEXT_PUBLIC_IS_PRODUCTION`            | `"true"`                                |
| `NEXT_PUBLIC_CATACOMB_TAGLINE`         | `catacomb.branding.tagline`             |
| `NEXT_PUBLIC_CATACOMB_FOOTER_LINKS`    | `catacomb.branding.footerLinks` (JSON)  |
| `NEXT_PUBLIC_CATACOMB_GITHUB_REPO`     | `catacomb.branding.githubRepoLink`      |
| `NEXT_PUBLIC_CATACOMB_NOTIFICATION`    | `catacomb.branding.notification`        |

The `NEXT_PUBLIC_CATACOMB_*` family is only meaningful with
`branding.enable = true` (the patch reads them); with `enable = false`
they're set to `""` and ignored.

Any change to those values triggers a UI rebuild. ~5–10 min on a 4 vCPU
box; downstream consumers are expected to wire up their own binary cache
(substituter + push) so `nixos-rebuild switch` doesn't rebuild the
bundle on every host.

**Theme colors** (`branding.theme.*`) live in chain metadata in
`cfg-service`, not the bundle — see Chain registration below.

### Chain registration

`catacomb-chain-bootstrap` is a systemd oneshot that runs after the
compose stack comes up. It pipes a generated Python script into
`docker exec catacomb-cfg-web-1 python manage.py shell`, creating
two kinds of rows idempotently (`update_or_create`):

- A `chains.Service` row per entry in `catacomb.services` (default
  `[ "WALLET_WEB" ]`) — without one, cfg-service's
  `/v2/chains/{service_key}/` returns 404 because of `get_object_or_404`,
  and that cascades into a 404 on every CGW chain query.
- A `chains.Chain` row per entry in `catacomb.chains` with all the
  fields the Client Gateway's Zod schema expects, including the
  `nativeCurrency.logoUri` string (CGW will refuse to serialize the
  whole list if any chain has a null currency logo).

The unauthenticated `POST /cfg/api/v1/chains/` endpoint is read-only —
all earlier attempts to seed via curl 405'd silently. Going through the
Django shell is the only path that doesn't require admin login.

### Client Gateway tuning (`catacomb.cgw`)

| Option                                          | Default | Maps to CGW env                   |
|-------------------------------------------------|---------|-----------------------------------|
| `cgw.pricesProvider.apiKey`                     | `null`  | `PRICES_PROVIDER_API_KEY`         |
| `cgw.pricesProvider.apiBaseUri`                 | `null`  | `PRICES_PROVIDER_API_BASE_URI`    |
| `cgw.pricesProvider.tokenPricesTtlSeconds`      | `3600`  | `PRICES_TTL_SECONDS`              |
| `cgw.pricesProvider.nativeCoinPricesTtlSeconds` | `3600`  | `NATIVE_COINS_PRICES_TTL_SECONDS` |
| `cgw.zerion.apiKey`                             | `null`  | `ZERION_API_KEY`                  |

`apiKey` values are interpolated into a systemd activation script and
end up in `/nix/store` (world-readable). Use `builtins.readFile` or
agenix/sops for real keys.

## Recommended host requirements

Single-VM deploy, indexing one or two small EVM chains:

| Resource | Minimum            | Recommended         |
|----------|--------------------|---------------------|
| vCPU     | 4                  | 4–8                 |
| RAM      | 8 GB               | 16 GB               |
| Disk     | 80 GB SSD          | 160 GB+ SSD         |

Initial chain index is dominated by RPC throughput. With a fast/local RPC,
expect a small chain to fully index in ~12–36h. Postgres footprint is
governed by Safe density on the chain, not raw chain size — typically
under 10 GB for a small chain like ETC.

Authoritative sizing notes: see [`safe-infrastructure`'s production
docs](https://github.com/safe-global/safe-infrastructure/blob/main/docs/running_production.md)
and the [Safe self-hosting deployment guide](https://docs.safe.global/core-api/safe-infrastructure-deployment).

## Dev shell

```sh
nix develop          # nixos-anywhere, disko, nixfmt, statix, deadnix
nix fmt              # treefmt: nixfmt + statix --fix + deadnix --edit
nix flake check      # statix, deadnix, treefmt as flake checks
```

## Known gaps

- TODO: multi chain
- TODO: observability. Today there's no auto-recovery on container
  exit (upstream's `docker-compose.yml` ships no `restart:` policies,
  and our `catacomb-stack` systemd unit is `Type=oneshot` — it brings
  the stack up at boot and forgets), no health-derived alerting, no
  log aggregation, no metrics export. A live deploy that loses a
  container stays degraded until a human runs `systemctl restart
  catacomb-stack`. Minimum viable: per-service `restart: unless-stopped`
  in the override + a watchdog systemd timer that reconciles desired
  vs running state. Stretch: Loki/Vector for logs, Prometheus +
  Postgres/Redis/RabbitMQ exporters, alerts on container restart-count
  growth + indexer lag.
- The UI build skips `yarn fetch-chains` (network-dependent); the app
  falls back to a runtime CGW request, costing one extra round-trip
  before first paint.
- `TOKENS_LOGO_BASE_URI` is left at upstream's `https://tokens-logo.localhost`
  placeholder, so every ERC-20 logo URL in CGW responses 404s in the
  browser. The wallet's `<img onError>` fallback handles it visually,
  but the bytes-on-the-wire have a confusing hostname.
- Secrets are auto-generated on first boot to `/var/lib/catacomb/secrets/`.
  For multi-operator deploys, swap to
  [sops-nix](https://github.com/Mic92/sops-nix) or
  [agenix](https://github.com/ryantm/agenix).

## Links

- Safe core: https://github.com/safe-global
- Self-host orchestration (docker-compose reference): https://github.com/safe-global/safe-infrastructure
- Safe Wallet monorepo (UI source): https://github.com/safe-global/safe-wallet-monorepo
- Safe core API docs: https://docs.safe.global/core-api
