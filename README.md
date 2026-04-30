# nix-catacomb

Nix flake that deploys a self-hosted [Safe](https://safe.global) multi-sig
wallet for **Ethereum Classic** (chains 61 + 63), branded as
**Classix Catacomb Multi-Sig**.

The stack is upstream `safeglobal/*` Docker images orchestrated by NixOS via
`virtualisation.oci-containers`, deployed onto a fresh VM by
[nixos-anywhere](https://github.com/nix-community/nixos-anywhere) with disk
layout driven by [disko](https://github.com/nix-community/disko).

> **Status — sketch.** Module structure is in place, but the host has not yet
> been booted end-to-end. Image versions, port mappings, secrets, and the
> chain-bootstrap JSON shape need verification on a real deploy.

## Layout

```
flake.nix                       inputs, devShell, nixosConfigurations.catacomb
hosts/catacomb/
  configuration.nix             base NixOS (boot, ssh, podman, firewall)
  disko.nix                     single-disk BIOS layout for /dev/vda
  branding.nix                  catacomb.{branding,chains.*} options
  safe-stack.nix                17 OCI containers + chain-bootstrap oneshot
  nginx.nix                     reverse proxy, ACME TLS, sub_filter branding
```

## One-line install

Once a VM exists with SSH reachable as `root@<ip>`:

```sh
nix run github:nix-community/nixos-anywhere -- \
  --flake github:classix-dev/nix-catacomb#catacomb \
  --target-host root@<ip>
```

Re-running deploys (after editing the flake locally):

```sh
nixos-rebuild switch \
  --flake .#catacomb \
  --target-host root@<ip>
```

## What gets deployed

Per `safe-global/safe-infrastructure`, mirrored into NixOS systemd units:

| Tier         | Containers                                                                 |
|--------------|----------------------------------------------------------------------------|
| Frontend     | `ui` (safe-wallet-web), `nginx` (TLS + branding sub_filter)                |
| Gateway      | `cgw-web` (client-gateway-nest), `cgw-redis`, `cgw-db`                      |
| Config       | `cfg-web` (config-service), `cfg-db`                                        |
| Transactions | `txs-web`, `txs-worker-{indexer,contracts-tokens,notifications-webhooks}`, `txs-scheduler`, `txs-db`, `txs-redis`, `txs-rabbitmq` |
| Events       | `events-web`, `events-db`, `general-rabbitmq`                               |

## Branding

Defined in `hosts/catacomb/branding.nix`:

```nix
catacomb.branding.appName       = "Classix Catacomb Multi-Sig";
catacomb.branding.theme = {
  textColor       = "#ddffdc";   # classix.dev pale green
  backgroundColor = "#0a0a0a";   # near-black
};
```

How these land in the running app:

- **Theme colors** — POSTed into `safe-config-service` per chain by the
  `catacomb-chain-bootstrap` systemd oneshot. The Safe UI reads them at
  runtime from the gateway. No image rebuild needed.
- **App name** — replaced in HTML responses by an nginx `sub_filter` rule
  on the UI vhost. Stop-gap only; a proper UI rebuild from
  `safe-wallet-monorepo` is a follow-up.

## Chains

Both chains ship registered in `branding.nix`:

| Chain | ID | Short | RPC                                       |
|-------|----|-------|-------------------------------------------|
| Ethereum Classic | 61 | etc  | `rpc.mainnet.etccooperative.org` |
| Mordor (testnet) | 63 | etcm | `rpc.mordor.etccooperative.org`  |

RPCs and the existing on-chain Safe contract addresses are reused from the
public ETC Cooperative deployment for v1.

## Sizing

DigitalOcean droplet, single-VM:

- Target: **$45/mo tier** (DO Basic 8 GB / 4 vCPU AMD Premium, $48/mo).
- Storage: 200 GB block volume for Postgres data (~$20/mo).
- Initial chain index over a fast RPC: ~12–36 h.

## Update path

```sh
# bump pinned image versions in hosts/catacomb/safe-stack.nix
nix flake update           # bump nixpkgs / disko / nixos-anywhere
nixos-rebuild switch --flake .#catacomb --target-host root@<ip>
```

## Dev shell

```sh
nix develop          # nixos-anywhere, disko, nixfmt, statix, deadnix
nix fmt              # treefmt: nixfmt + statix --fix + deadnix --edit
nix flake check      # statix, deadnix, treefmt as flake checks
```

## Known gaps before this is deployable

- Container `ports` / explicit network are not declared in `safe-stack.nix`
  — nginx won't reach the upstream addresses until they are.
- Secrets in `safe-stack.nix` are hard-coded placeholders. Move to
  [sops-nix](https://github.com/Mic92/sops-nix) or
  [agenix](https://github.com/ryantm/agenix) before any real deploy.
- Domain name is hard-coded to `catacomb.example` — lift to a flake-level
  option.
- ACME requires DNS records pointing at the droplet IP before the first
  rebuild, otherwise certificate issuance fails.
- `chain-bootstrap` JSON payload shape needs verification against a live
  `safe-config-service` admin API.
- App-name override is HTML-substitution only; a real UI rebuild from
  `safe-wallet-monorepo` is the proper fix.
