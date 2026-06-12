# euro-office

Collaborative document editing for Nextcloud — real-time co-authoring of Word, Excel, and PowerPoint files in the browser, powered by [Euro-Office DocumentServer](https://github.com/Euro-Office/DocumentServer) (an OnlyOffice-compatible server).

## What you get

| Capability | Access from | How |
|---|---|---|
| Edit `.docx` / `.xlsx` / `.pptx` | Nextcloud (`srv` zone) | Open a document in Nextcloud Files |
| Real-time co-authoring | Nextcloud | Multiple users in one document |
| OnlyOffice-compatible API | `srv` zone | `http://euro-office.srv.internal` (port 80) |
| Public editor endpoint | via reverse proxy | `https://euro-office.<domain>` |

## What is not included

- Standalone access — the editor is reached through Nextcloud, not directly. The built-in `/example/` test app is disabled (`EXAMPLE_ENABLED=false`).
- Authentication of its own — trust is established with Nextcloud via a shared JWT secret (auto-generated, never leaves the VM).
- The Nextcloud connector app — shipped by the `nextcloud` module (`eurooffice-nextcloud`, app id `onlyoffice`).

## Architecture

A single Podman container bundles every service internally; only port 80 is exposed to the host.

| Component | Role |
|---|---|
| Nginx | Serves the editor UI and routes all paths (port 80) |
| DocService (Node.js) | Document co-authoring engine |
| FileConverter (C++) | Format conversion |
| PostgreSQL / Redis / RabbitMQ | Session storage, cache, internal bus |

Image: `ghcr.io/euro-office/documentserver:v9.3.1` — pinned (immutable semver) in `euro-office.nix`. Do not use the mutable `:latest`/`:nightly` tags.

## Requirements

- `srv` zone (VLAN 210)
- `nextcloud` deployed and reachable (`nextcloud:fileservice` dependency) — install it first
- NixOS template (`templates:nixos`)

## Dependencies

| Depends on | Purpose |
|---|---|
| `cluster:vm` | VM provisioning |
| `templates:nixos` | NixOS base image |
| `backup:vm` | Daily document backups |
| `firewall:proxy` | HTTPS reverse proxy |
| `nextcloud:fileservice` | The Nextcloud instance this server edits documents for |

For installation, customisation, and troubleshooting see [INSTALL.md](./INSTALL.md).

## Deploy notes & known limitations (0.1.0)

- Validated via test variant; the OnlyOffice <-> Nextcloud connector is proven end-to-end (N4 wiring, ADR-COM-0002).
- The consumer egress (srv -> reverse proxy:443) is declared in this module; named-variant deploys depend on the foundation egress-flattening + provider-variant resolution fixes (upstream issue).
