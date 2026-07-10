# Nextcloud

Primary audience: end users and teams who need self-hosted file sync, sharing and collaboration.

Your own private cloud — files, document editing, calls and chat, with single sign-on.

## What you get

| Capability | Access from | How |
|------------|-------------|-----|
| File sync & share | Home, work, mobile | `https://nextcloud.<domain>` + desktop/iOS/Android clients |
| Document editing | Nextcloud Files | OnlyOffice editor via the euro-office connector app |
| Calls & chat (Talk) | Nextcloud UI | Relays via `coturn` (TURN), scales via `nextcloud-hpb` |
| Single sign-on | Login page | Authentik OIDC (`user_oidc` app) |
| Daily backups | — | PostgreSQL dump + data archive, 30-day retention |

## What is not included

- **OnlyOffice document server** — provided by the separate `euro-office` module. Nextcloud ships
  only the connector app; the server is wired in when euro-office is installed.
- **TURN media relay** — provided by the `coturn` module (Talk audio/video).
- **HPB signaling backend** — provided by the `nextcloud-hpb` module (multi-party call scaling).
- **Mail server** — outbound mail uses an external SMTP relay (configured via the `mail.env`
  secret).

## Requirements

- `srv` zone
- VM sizing (defaults from `nextcloud.json`): 4 vCPU, 8 GB RAM, 80 GB disk on `tanka1`
- Authentik (`identity:identity`) deployed if you want single sign-on

## Dependencies

| Depends on | Purpose |
|------------|---------|
| `cluster:vm` | VM provisioning |
| `templates:nixos` | NixOS base image |
| `backup:vm` | Daily backups (PostgreSQL + data) |
| `network:proxy` | HTTPS reverse proxy (public domain `nextcloud.<domain>`) |
| `network:rules` | Firewall pass rules (incl. egress to the proxy for Talk HPB callbacks) |
| `identity:identity` | Single sign-on (Authentik) + secrets |

For installation steps see [INSTALL.md](./INSTALL.md).
