# Nextcloud

File sharing and collaboration platform — files, document editing, calls and chat, with Authentik SSO.
Core of the collaboration hub: `provides: nextcloud`, consumed by `coturn`, `nextcloud-hpb`, and `euro-office`.

## What you get

| Capability | Access from | How |
|---|---|---|
| File sync & share | Home, work, mobile | `https://nextcloud.<domain>` + desktop/iOS/Android clients |
| Document editing | Nextcloud Files | OnlyOffice editor via the euro-office connector (the `onlyoffice` app) |
| Calls & chat (Talk) | Nextcloud UI | Real-time; relays via `coturn` (TURN), scales via `nextcloud-hpb` (signaling) |
| Single sign-on | Login page | Authentik OIDC (`identity:identity`, `user_oidc`) |
| Persistent data | All sessions | PostgreSQL + Redis; daily backups |

## What is not included

- **OnlyOffice document server** — the separate `euro-office` module. Nextcloud ships the connector
  app + config service; the server is wired in by euro-office's dependency on `nextcloud:nextcloud`.
- **TURN relay** — the `coturn` module (Talk audio/video).
- **HPB signaling backend** — the `nextcloud-hpb` module (multi-party call scaling).
- **Mail server** — uses an external SMTP relay (configured via the `mail.env` secret).

## Provides

| Capability | Consumed by |
|---|---|
| `nextcloud` | `coturn`, `nextcloud-hpb`, `euro-office` (each `dependsOn nextcloud:nextcloud`) |

## Requirements

- `srvWork` zone
- NixOS template (`pkgs.nextcloud33`)
- Authentik available for SSO (`identity:identity`)

## Dependencies

| Depends on | Purpose |
|---|---|
| `cluster:vm` | VM provisioning |
| `templates:nixos` | NixOS base image |
| `backup:vm` | Daily backups (PostgreSQL, data) |
| `firewall:proxy` | HTTPS reverse proxy (public domain derived from `vmname` + `tappaas.domain`) |
| `identity:identity` | SSO (Authentik) + secrets |

For installation steps see [INSTALL.md](./INSTALL.md).
