# nix-catacomb

Nix flake that deploys a self-hosted [Safe](https://safe.global) multi-sig
wallet onto a single VM, branded and configured via Nix module options.

The default chain set is **Ethereum Classic** (61) and **Mordor testnet**
(63), branded as *Classix Catacomb Multi-Sig*; both are overrideable.

The stack is upstream `safeglobal/*` Docker images orchestrated by NixOS via
`virtualisation.oci-containers`, deployed onto a fresh VM by
[nixos-anywhere](https://github.com/nix-community/nixos-anywhere) with disk
layout driven by [disko](https://github.com/nix-community/disko).

> **Status — sketch.** The module structure is in place, but the host has
> not yet been booted end-to-end. Expect rough edges around port mappings,
> the chain-bootstrap JSON shape, and the UI branding overlay.

## Layout

```
flake.nix                       inputs, devShell, nixosConfigurations.catacomb
hosts/catacomb/
  configuration.nix             base NixOS (boot, ssh, podman, firewall)
  options.nix                   declares every catacomb.* option
  defaultConfig.nix             defaults for every option (one obvious place)
  config.nix.example            template for per-deploy overrides
  config.nix                    YOUR per-deploy overrides (gitignored)
  disko.nix                     single-disk BIOS layout
  safe-stack.nix                17 OCI containers, secrets, chain-bootstrap
  nginx.nix                     reverse proxy, ACME TLS, sub_filter branding
```

## Deploying guide

### 1. Fork and clone

Fork this repository on GitHub, then clone your fork locally:

```sh
git clone git@github.com:<you>/nix-catacomb.git
cd nix-catacomb
```

### 2. Set your per-deploy values

```sh
cp hosts/catacomb/config.nix.example hosts/catacomb/config.nix
$EDITOR hosts/catacomb/config.nix
```

Required: `domain`, `acmeEmail`, `sshAuthorizedKeys`. Everything else
inherits from `defaultConfig.nix`.

`config.nix` is gitignored so your overrides never get pushed back. Because
Nix flakes ignore untracked files, you need to force-stage it locally so
flake evaluation can see it:

```sh
git add -f hosts/catacomb/config.nix     # Nix can now read it; commit guard still in place
```

### 3. Provision a VM

Any provider works — minimum recommended specs are below. Provision a fresh
host with **Ubuntu / Debian** (or anything `nixos-anywhere` can kexec from)
and your SSH key installed for `root`. You'll need its IP address.

### 4. Point DNS at the VM

Two records on the apex domain you set in `config.nix`:

| Record                   | Type | Value          |
|--------------------------|------|----------------|
| `<your-domain>`          | A    | `<vm-ip>`      |
| `*.<your-domain>`        | A    | `<vm-ip>`      |

Wait for propagation before the next step — ACME will fail to issue
certificates if the DNS records don't yet resolve to the VM.

### 5. Install with `nixos-anywhere`

```sh
nix run github:nix-community/nixos-anywhere -- \
  --flake .#catacomb \
  --target-host root@<vm-ip>
```

This kexecs into the NixOS installer, runs `disko` to partition the disk,
installs the system, and reboots. First boot generates secrets to
`/var/lib/catacomb/secrets/` and pulls all `safeglobal/*` container images.

### 6. Subsequent deploys

After editing any module or `config.nix`:

```sh
nixos-rebuild switch --flake .#catacomb --target-host root@<vm-ip>
```

### 7. Updating

```sh
nix flake update                              # bump nixpkgs / disko / nixos-anywhere
$EDITOR hosts/catacomb/safe-stack.nix         # bump pinned safeglobal/* image versions
nixos-rebuild switch --flake .#catacomb --target-host root@<vm-ip>
```

## What gets deployed

Per [`safe-global/safe-infrastructure`](https://github.com/safe-global/safe-infrastructure),
mirrored into NixOS systemd units:

| Tier         | Containers                                                                 |
|--------------|----------------------------------------------------------------------------|
| Frontend     | `ui` ([safe-wallet-monorepo](https://github.com/safe-global/safe-wallet-monorepo)), `nginx` |
| Gateway      | `cgw-web` ([safe-client-gateway](https://github.com/safe-global/safe-client-gateway)), `cgw-redis`, `cgw-db` |
| Config       | `cfg-web` ([safe-config-service](https://github.com/safe-global/safe-config-service)), `cfg-db` |
| Transactions | `txs-web` ([safe-transaction-service](https://github.com/safe-global/safe-transaction-service)), 3× workers, scheduler, `txs-db`, `txs-redis`, `txs-rabbitmq` |
| Events       | `events-web`, `events-db`, `general-rabbitmq`                              |

Branding lands in two ways:
- **Theme colors** (`branding.theme.*`) → POSTed per chain to `cfg-service`
  by the `catacomb-chain-bootstrap` systemd oneshot. No image rebuild.
- **App name** (`branding.appName`) → swapped into HTML/JS responses by an
  nginx `sub_filter` rule on the UI vhost. Stop-gap; a proper UI rebuild
  from the monorepo is a follow-up.

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

- App-name override is HTML-substitution only; replace with a UI rebuild
  from `safe-wallet-monorepo` for a real fix.
- `chain-bootstrap` JSON payload shape needs verification against a live
  `safe-config-service` admin API.
- Mordor (chain 63) `txs` instance is declared in defaults but not yet
  wired to its own container in `safe-stack.nix`.
- Secrets are auto-generated on first boot to `/var/lib/catacomb/secrets/`.
  For multi-operator deploys, swap to
  [sops-nix](https://github.com/Mic92/sops-nix) or
  [agenix](https://github.com/ryantm/agenix).

## Links

- Safe core: https://github.com/safe-global
- Self-host orchestration (docker-compose reference): https://github.com/safe-global/safe-infrastructure
- Safe Wallet monorepo (UI source): https://github.com/safe-global/safe-wallet-monorepo
- Safe core API docs: https://docs.safe.global/core-api
