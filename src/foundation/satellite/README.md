# satellite

Primary audience: TAPPaaS admin.

An operator-owned VPS with a stable public IP that gives a cluster behind CGNAT / dynamic
IP / no inbound the public ingress, remote admin access, and off-site backup vault the
rest of TAPPaaS assumes.

> **Status:** implemented (Debian variant). `reverse-proxy` and `admin-vpn` are live-validated;
> the `backup` role is implemented (official PBS on Debian, pull model) with the full pull
> round-trip pending a live home-PBS test.
> Design: [ADR-010](../../../docs/ADR/ADR-010-vps-satellite-reverse-proxy-backup.md) ·
> Tracker: [ADR-010-implementation.md](../../../docs/design/ADR-010-implementation.md)

## What you get

| Capability | Access from | How |
|------------|-------------|-----|
| Public HTTPS ingress (`reverse-proxy` role): L4 TCP passthrough of `:443`/`:80` to Caddy-on-OPNsense over the WireGuard tunnel | internet | published DNS names point at the satellite's public IP; TLS terminates at home |
| Remote admin access (`admin-vpn` role): blind UDP relay of an admin WireGuard session terminating on OPNsense | admin device, anywhere | WireGuard peer to the satellite's public IP → mgmt plane |
| Off-site backup vault (`backup` role): a PBS datastore the home PBS is pulled into, S3 Object-Lock by default | tappaas-cicd | `satellite-manager` (pull-based sync; client-side encrypted at home) |
| Lifecycle management | tappaas-cicd | `satellite-manager install\|update\|status\|remove <name>` |

Roles are independent and selected in `satellite.json` (`roles: [...]`). One node may
carry any combination; a site may run several satellites. A pure relay/admin node needs
almost no disk; the `backup` role adds storage cost (S3 usage by default, or a sized
volume).

## What is not included

- **Not a Proxmox VM the cluster hosts** — the satellite is an external host
  (`kind: external-host`) the cluster reaches out to and manages. It is optional and
  never part of the mandatory install chain.
- No TLS termination or cert keys on the satellite — Caddy at home terminates; the
  satellite relays ciphertext only (blind relay + blind vault trust model, ADR-010 §7).
- No standing root from `tappaas-cicd` over the satellite — only an ephemeral
  provisioning credential, revoked after install.
- Not needed for a site with a real public IP.

## Requirements

- A host with a **stable public IPv4** and root SSH — the reference is a Hetzner Cloud
  VPS, but any VM or physical host with a public address works.
- A running TAPPaaS foundation: `network` (OPNsense) and `tappaas-cicd`.
- For the `backup` role: the home `backup` module (PBS) plus an S3 bucket with
  **Object Lock enabled at creation** (or a sized block volume, advanced).
- Your operator SSH key (workstation) — it becomes the satellite's standing root.

## Dependencies

`dependsOn` is empty **by design**: the satellite is an external host, operator-driven
via `satellite-manager`, not installed through `install-module.sh`, so it does not
participate in the module dependency graph. Its real prerequisites are checked by
`satellite-manager` at install time:

| Depends on | Purpose |
|------------|---------|
| `network` (module, up) | OPNsense terminates the WireGuard tunnel and the admin VPN |
| `tappaas-cicd` (up) | Hosts `satellite-manager`, drives provisioning and management |
| `backup` (module, for the backup role) | The home PBS that is pulled into the off-site vault |

For installation steps see [INSTALL.md](./INSTALL.md).
