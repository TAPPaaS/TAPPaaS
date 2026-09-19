# satellite

Primary audience: TAPPaaS admin.

A machine with a stable public IP — typically a small VPS — that gives a Site behind CGNAT /
dynamic IP / no inbound the public ingress, remote admin access and off-site backup the
rest of TAPPaaS assumes. It is a `kind: machine` module like any other (ADR-010 §8.4):
`module-manager module add satellite` creates it, the nightly sweep patches it.

> **Status:** implemented (Debian). `reverse-proxy` and `admin-vpn` are live-validated; the
> module form (ADR-010 §8.4, #670) is unit-tested and awaits its live test (#671).
> Design: [ADR-010](../../../docs/ADR/ADR-010-vps-satellite-reverse-proxy-backup.md) ·
> Tracker: [ADR-010-implementation.md](../../../docs/design/ADR-010-implementation.md)

## What you get

| Capability | Access from | How |
|------------|-------------|-----|
| Public HTTPS ingress (`reverse-proxy` role): L4 TCP passthrough of `:443`/`:80` to Caddy-on-OPNsense over the WireGuard tunnel | internet | published DNS names point at the satellite's public IP; TLS terminates at home |
| Remote admin access (`admin-vpn` role): blind UDP relay of an admin WireGuard session terminating on OPNsense | admin device, anywhere | `network-manager wgvpn add-peer` prints a config whose Endpoint is the satellite |
| Off-site backup vault (`backup` role, after `--lockdown`): a PBS the home PBS is pulled into | tappaas-cicd | pull-based sync, client-side encrypted at home; nothing at home can log in to it |
| The Site's PBS (a managed satellite, for a Site with none of its own) | the Site's nodes, through the tunnel | `module-manager module modify backup --set node=<instance>` — PBS on a ZFS pool on an attached volume (ADR-010 §8.4.3) |
| Lifecycle | tappaas-cicd | `module-manager module add\|update\|test\|delete satellite` — updates by the nightly sweep |

A satellite starts **managed**: the mothership's key is authorized and the sweep patches it
(`apt full-upgrade`, reboots only as `rebootOk` allows), like a `debianhost` machine. Locked
down (`module-manager module modify <instance> --lockdown`) it becomes the **unmanaged** pull
vault: it patches itself and admits no login from home (ADR-010 §7.3, §8.4.4).

Roles are chosen at add (`--roles`); one machine may carry both relay roles, and a Site may
run several satellites (`--instance`).

## What is not included

- **Not a Proxmox VM the cluster hosts** — it is its own machine (`kind: machine`,
  ADR-022f), outside the cluster. It is optional and never part of the mandatory install.
- **`module-manager module delete <instance>` does not take it down** — like any machine it
  is only unregistered (ADR-026). `--decommission` removes the Site's side (OPNsense peer,
  tunnel server, edge rules); the machine itself is never touched.
- No TLS termination or cert keys on the satellite — Caddy at home terminates; the
  satellite relays ciphertext only (blind relay trust model, ADR-010 §7).
- Not needed for a site with a real public IP — and the admin VPN works without it
  (`network-manager wgvpn`).

## Requirements

- A host with a **stable public IPv4** and root SSH by your operator key — the reference is a
  Hetzner Cloud VPS, but any VM or physical host with a public address works.
- A running TAPPaaS foundation: `network` (OPNsense) and `tappaas-cicd`.

## Dependencies

`dependsOn` is empty: nothing the satellite needs is a service another module provides
through the dependency graph. It needs OPNsense (`network`), which terminates its tunnel, and
`tappaas-cicd`, which runs its lifecycle — both present on every Site.

For installation steps see [INSTALL.md](./INSTALL.md).
