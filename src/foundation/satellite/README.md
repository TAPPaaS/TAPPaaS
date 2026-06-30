# satellite — TAPPaaS VPS Satellite (reverse proxy, admin VPN, off-site backup)

> **Status:** scaffolding (ADR-010 implementation, package P1). Not yet functional.
> **Design:** [ADR-010](../../../docs/ADR/ADR-010-vps-satellite-reverse-proxy-backup.md) · **Plan/tracker:** [ADR-010-implementation.md](../../../docs/design/ADR-010-implementation.md) · **Install:** [INSTALL.md](INSTALL.md)

## What it is

A **satellite** is a small, operator-owned node with a **stable public IP** — typically a
low-cost VPS (Hetzner is the reference), but any VM or physical host with a public address
works. It gives a home/SMB cluster behind **CGNAT / dynamic IP / no inbound** the public
reachability the rest of TAPPaaS assumes but cannot guarantee.

Unlike every other foundation module, the satellite is **not a Proxmox VM the cluster hosts** —
it is an **external host the cluster reaches out to and manages**. It is therefore **optional**
and provisioned on demand (see [INSTALL.md](INSTALL.md)), never part of the mandatory install chain.

## Trust model — blind relay + blind vault

The satellite sits off-premises on someone else's hardware and is treated as **semi-trusted and
seizable**. Every role is structured so a compromise of the satellite yields only **ciphertext**
and the ability to *disrupt* — never to read, impersonate, or decrypt:

| Role | What it does | What it never sees |
| ---- | ------------ | ------------------ |
| `reverse-proxy` | L4 TCP passthrough of `:443`/`:80` to Caddy-on-OPNsense over the WireGuard tunnel (nginx `stream`, PROXY-protocol v2) | TLS plaintext or cert keys — Caddy at home terminates |
| `admin-vpn` | Blind UDP relay of an admin WireGuard session that terminates on OPNsense | admin keys/traffic — admin↔OPNsense is end-to-end |
| `backup` | An off-site PBS datastore the home PBS is **pulled** into (S3 Object-Lock by default) | backup plaintext or the decryption key — client-side encrypted at home |

And the trust does not flow the other way: the cluster holds **no standing root** over the
satellite (ephemeral provisioning credential, pull-based signed updates, one-directional
management), so a compromise of the *home cluster* cannot reach out and destroy the off-site
vault. See ADR-010 §7.

## Roles

Roles are independent and selected in `satellite.json` (`roles: [...]`). One node may carry any
combination; a site may run several satellites. A pure relay/admin node needs almost no disk; the
`backup` role adds storage cost (S3 usage by default, or a sized volume).

## Connectivity (summary)

- **Tunnel:** WireGuard, **home dials out, satellite listens** (PersistentKeepalive keeps the
  CGNAT pinhole open). Dedicated `edge` overlay zone, `/31` link (`10.255.0.0/31`).
- **Admin VPN:** terminates on OPNsense into a dedicated `admin` overlay zone → mgmt plane; the
  satellite only UDP-relays it.
- **Least privilege:** the `edge` zone may reach *only* the endpoints its active roles require
  (Caddy ingress / OPNsense admin-WG / home PBS `:8007`) — never broad `mgmt`.

## Files (module contract)

| File | Purpose |
| ---- | ------- |
| `satellite.json` | Declarative satellite config (provider, public IP, tunnel, roles, per-role settings). Satellite-specific schema (`schemas/satellite-fields.json`). |
| `satellite.nix` | NixOS configuration deployed onto the external host via `nixos-anywhere`. |
| `install.sh` / `update.sh` / `test.sh` | Module lifecycle verbs (delegate to `satellite-manager`). |
| `README.md` / `INSTALL.md` | This overview + the detailed install runbook. |

The operator front door is the **`satellite-manager`** CLI on `tappaas-cicd`
(`satellite-manager install|update|status|remove <name>`).

## Status / roadmap

See the [implementation tracker](../../../docs/design/ADR-010-implementation.md#stage-tracker)
(packages P1–P7). This directory is **P1 scaffolding**; the tunnel, provisioning, and per-role
behaviour land in P2–P6, hardening + docs in P7.
