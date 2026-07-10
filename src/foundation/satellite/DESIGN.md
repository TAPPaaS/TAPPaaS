# satellite — Design notes

Design and implementation detail displaced from README/INSTALL during the Diataxis
restructure (issue #247). Catalog info: [README.md](./README.md); runbook:
[INSTALL.md](./INSTALL.md). Full rationale:
[ADR-010](../../../docs/ADR/ADR-010-vps-satellite-reverse-proxy-backup.md); plan/tracker:
[ADR-010-implementation.md](../../../docs/design/ADR-010-implementation.md).

## Trust model — blind relay + blind vault

The satellite sits off-premises on someone else's hardware and is treated as
**semi-trusted and seizable**. Every role is structured so a compromise of the satellite
yields only **ciphertext** and the ability to *disrupt* — never to read, impersonate, or
decrypt:

| Role | What it does | What it never sees |
| ---- | ------------ | ------------------ |
| `reverse-proxy` | L4 TCP passthrough of `:443`/`:80` to Caddy-on-OPNsense over the WireGuard tunnel (nginx `stream`, PROXY-protocol v2) | TLS plaintext or cert keys — Caddy at home terminates |
| `admin-vpn` | Blind UDP relay of an admin WireGuard session that terminates on OPNsense | admin keys/traffic — admin↔OPNsense is end-to-end |
| `backup` | An off-site PBS datastore the home PBS is **pulled** into (S3 Object-Lock by default) | backup plaintext or the decryption key — client-side encrypted at home |

And the trust does not flow the other way: the cluster holds **no standing root** over
the satellite (ephemeral provisioning credential, pull-based signed updates,
one-directional management), so a compromise of the *home cluster* cannot reach out and
destroy the off-site vault. See ADR-010 §7.

## Connectivity

- **Tunnel:** WireGuard, **home dials out, satellite listens** (PersistentKeepalive keeps
  the CGNAT pinhole open). Dedicated `edge` overlay zone, `/31` link (`10.255.0.0/31`).
- **Admin VPN:** terminates on OPNsense into a dedicated `admin` overlay zone → mgmt
  plane; the satellite only UDP-relays it.
- **Least privilege:** the `edge` zone may reach *only* the endpoints its active roles
  require (Caddy ingress / OPNsense admin-WG / home PBS `:8007`) — never broad `mgmt`.

## Module contract (files)

| File | Purpose |
| ---- | ------- |
| `satellite.json` | Declarative satellite config (provider, public IP, roles, per-role settings). Operator-facing template only — all derived values (tunnel `/31` + ports, per-role tuning, backup mechanics, update mode) are computed by `satellite-manager` at install time. Satellite-specific schema (`schemas/satellite-fields.json`). |
| `satellite.nix` | NixOS configuration deployed onto the external host via `nixos-anywhere` (the NixOS OS option). |
| `debian/` | The stock-Debian alternative (default OS option) — `provision-debian.sh` / `provision-backup.sh`; see `debian/README.md`. |
| `install.sh` / `update.sh` / `test.sh` / `delete.sh` | Module lifecycle verbs (delegate to `satellite-manager`). |
| `test-vm-creation/` | Deep-test fixture: installs `sat-hello`, probes end-to-end via the satellite public IP, tears down. |
| `README.md` / `INSTALL.md` | Service-catalog overview + the install runbook. |

The operator front door is the **`satellite-manager`** CLI on `tappaas-cicd`
(`satellite-manager install|update|status|remove <name>`). The satellite has an empty
`dependsOn` by design: as an `external-host` it is not installed through
`install-module.sh` and does not participate in the module dependency graph;
`satellite-manager` checks its real prerequisites (`network`, `tappaas-cicd`, `backup`
for the backup role) at install time.

## Updates and decommissioning

- Updates are **pull-based**: the satellite `autoUpgrade`s from a pinned/signed ref;
  `tappaas-cicd` never SSHes in to push (ADR-010 §7.3). `update.sh` reconciles only the
  home-side wiring.
- `delete.sh <name>` / `satellite-manager remove <name>` decommissions: tears down the
  OPNsense WireGuard peer, removes the `edge`/`admin` zones and rules, reverts DNS, and
  forgets the secrets. Destroying the external VPS itself stays manual (operator's cloud
  account) unless the Tier-B hcloud API token is configured (§5.6).

## Status / roadmap

This directory is **P1 scaffolding**; the tunnel, provisioning, and per-role behaviour
land in P2–P6, hardening + docs in P7. See the
[implementation tracker](../../../docs/design/ADR-010-implementation.md#stage-tracker).
