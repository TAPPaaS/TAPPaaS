# Vaultwarden

Primary audience: home users and teams who need a self-hosted password manager.

Bitwarden-compatible password manager, published to the internet from the DMZ zone.

> **Status: Development** — not yet ready for production use (no automated `test.sh`;
> see [INSTALL.md](./INSTALL.md) for manual verification).

## What you get

| Capability | Access from | How |
|------------|-------------|-----|
| Web vault | Internet + internal | `https://vaultwarden.<domain>` |
| Bitwarden clients | Desktop, mobile, browser extensions | point the client at `https://vaultwarden.<domain>` |
| Admin panel | Admin only | `https://vaultwarden.<domain>/admin` with the `ADMIN_TOKEN` |
| Daily backups | — | SQLite backup + full archive, 30-day retention |

## What is not included

- **Open registration** — signups are disabled (`SIGNUPS_ALLOWED = false`); the admin creates or
  invites accounts via the admin panel.
- **Outbound email** — account verification and notification mail requires manually configuring
  SMTP in the environment file after install.
- **A database server** — Vaultwarden uses its built-in SQLite backend.

## Requirements

- `dmz` zone (the reverse proxy publishes it to the `internet` zone)
- VM sizing (defaults from `vaultwarden.json`): 1 vCPU, 1 GB RAM, 8 GB disk on `tanka1`
- A public DNS record `vaultwarden.<domain>` pointing at your WAN address

## Alternatives considered

- Official Bitwarden server — Vaultwarden is the audited Rust rewrite of the server part;
  Bitwarden/Vaultwarden is judged the only true open-source self-hostable password manager.

Source: [SecurityDesign.md](../../../docs/Architecture/SecurityDesign.md). Depth: see [DESIGN.md](./DESIGN.md).

## Dependencies

| Depends on | Purpose |
|------------|---------|
| `cluster:vm` | VM provisioning |
| `cluster:ha` | High-availability placement |
| `templates:nixos` | NixOS base image |
| `backup:vm` | VM registered with Proxmox Backup Server |
| `identity:identity` | Secrets and identity management |
| `network:proxy` | HTTPS reverse proxy, allowed from the `internet` zone |

For installation steps see [INSTALL.md](./INSTALL.md).
