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
  app + config service; the server is wired in by euro-office's dependency on `nextcloud:fileservice`.
- **TURN relay** — the `coturn` module (Talk audio/video).
- **HPB signaling backend** — the `nextcloud-hpb` module (multi-party call scaling).
- **Mail server** — uses an external SMTP relay (configured via the `mail.env` secret).

## Provides

| Capability | Consumed by |
|---|---|
| `nextcloud` | `coturn`, `nextcloud-hpb`, `euro-office` (each `dependsOn nextcloud:fileservice`) |

## Requirements

- `srv` zone
- NixOS template (`pkgs.nextcloud33`)
- Authentik available for SSO (`identity:identity`)

## Dependencies

| Depends on | Purpose |
|---|---|
| `cluster:vm` | VM provisioning |
| `templates:nixos` | NixOS base image |
| `backup:vm` | Daily backups (PostgreSQL, data) |
| `network:proxy` | HTTPS reverse proxy (public domain derived from `vmname` + `tappaas.domain`) |
| `identity:identity` | SSO (Authentik) + secrets |

For installation steps see [INSTALL.md](./INSTALL.md).

## Deploy notes & known limitations (0.1.0)

- Validated on the cluster via a named test variant (`--variant test`). A base/production deploy is the canonical path; named-variant deploys depend on the foundation provider-variant resolution (see the `deploy-engine: pass resolved provider variant` upstream issue).
- Talk HPB/TURN connector wiring (signaling backend allow-list, egress to the reverse proxy) is config-derived at deploy. External multi-party calls additionally require a publicly reachable coturn (WAN endpoint).
