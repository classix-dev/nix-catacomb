# nix-catacomb

Nix flake that deploys a self-hosted [Safe](https://safe.global) multi-sig
wallet onto a single VM, branded and configured via Nix module options.

The default chain is **Ethereum Classic** (61), branded as
*Classix Catacomb Multi-Sig*; both are overrideable.

The stack is upstream `safe-global/safe-infrastructure`'s docker-compose
project run verbatim against a NixOS-managed Docker daemon, plus a
Nix-built static UI served by the host nginx, plus an idempotent
chain-bootstrap oneshot that seeds `safe-config-service`. Deployed onto a
fresh VM by [nixos-anywhere](https://github.com/nix-community/nixos-anywhere)
with disk layout driven by [disko](https://github.com/nix-community/disko).

## Layout

```
flake.nix                       inputs, devShell, nixosConfigurations.catacomb
hosts/catacomb/
  default.nix                   base NixOS (boot, ssh, docker, firewall)
  options.nix                   declares every catacomb.* option
  defaultConfig.nix             defaults for every option (one obvious place)
  disko.nix                     single-disk BIOS layout
  safe-stack.nix                upstream safe-infrastructure compose stack
  override.yml.tmpl             per-deploy compose override (env, image pins, ui-stub)
  nginx.nix                     TLS termination + ACME wrapper
  ui.nix                        host-served static UI + backend path-fanout locations
pkgs/safe-wallet-web/           Nix derivation that builds apps/web statically
```

## Deploying guide

This repo is a *library* flake — it exposes `nixosModules.catacomb` and a
`packages.safe-wallet-web-static` derivation, but it doesn't deploy itself.
Wrap it in a small consumer flake that pins the library and supplies your
domain / SSH keys / branding. A worked example lives at
[`local/flake.nix.example`](./local/flake.nix.example).
<!-- TODO: link to a public sample deployment flake once one is published. -->


### 1. Create your consumer flake

Outside of this repo:

```sh
mkdir my-catacomb && cd my-catacomb
cp /path/to/nix-catacomb/local/flake.nix.example flake.nix
$EDITOR flake.nix      # set domain, acmeEmail, sshAuthorizedKeys, branding
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

| Env var                                | Source                          |
|----------------------------------------|---------------------------------|
| `NEXT_PUBLIC_BRAND_NAME`               | `catacomb.branding.appName`     |
| `NEXT_PUBLIC_GATEWAY_URL_PRODUCTION`   | `https://<domain>/cgw`          |
| `NEXT_PUBLIC_DEFAULT_MAINNET_CHAIN_ID` | `catacomb.chains.etc.chainId`   |
| `NEXT_PUBLIC_IS_PRODUCTION`            | `"true"`                        |

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

- The bundled `txs` compose project indexes a single chain. Adding more
  chains to `catacomb.chains` only registers them in cfg-service; Safe
  interactions on the extra chains will fail until you stand up a
  per-chain `txs-*` stack and point each `transactionService` at it.
- The UI build skips `yarn fetch-chains` (network-dependent); the app
  falls back to a runtime CGW request, costing one extra round-trip
  before first paint.
- Secrets are auto-generated on first boot to `/var/lib/catacomb/secrets/`.
  For multi-operator deploys, swap to
  [sops-nix](https://github.com/Mic92/sops-nix) or
  [agenix](https://github.com/ryantm/agenix).

## Links

- Safe core: https://github.com/safe-global
- Self-host orchestration (docker-compose reference): https://github.com/safe-global/safe-infrastructure
- Safe Wallet monorepo (UI source): https://github.com/safe-global/safe-wallet-monorepo
- Safe core API docs: https://docs.safe.global/core-api
