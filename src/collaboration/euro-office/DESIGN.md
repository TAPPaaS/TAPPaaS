# euro-office — Design notes

Primary audience: **module developers** (Diataxis: *explanation*).

This document explains *how this module works and why it is built the way it is* — the
internal rationale a maintainer or contributor needs. Per ADR-013 it is **not** published
to tappaas.org: keep the end-user *what/why* in [README.md](./README.md) and the admin
*how* in [INSTALL.md](./INSTALL.md); implementation reasoning lives here.

## Why this exists

Nextcloud does not ship a document-editing backend of its own. euro-office provides that
backend as a self-contained container on its own VM, connected to Nextcloud only through
a thin, replaceable connector (`nextcloud:fileservice`) — so the document server can be
upgraded, backed up and (in principle) swapped without touching Nextcloud itself.

## Architecture

A single Podman container (NixOS `virtualisation.oci-containers`, podman backend)
bundles every internal service; only port 80 is exposed to the host, and the guest
firewall opens only ports 22 and 80.

| Component | Role |
|-----------|------|
| Nginx | Serves the editor UI and routes all paths (port 80) |
| DocService (Node.js) | Document co-authoring engine |
| FileConverter (C++) | Format conversion |
| PostgreSQL / Redis / RabbitMQ | Session storage, cache, internal message bus |
| Admin Panel | Server monitoring/config UI (`ADMINPANEL_ENABLED=true`); not required for document editing |

Image: `ghcr.io/euro-office/documentserver:v9.3.3` — pinned as an immutable semver tag in
`euro-office.nix`. Do not use the mutable `:latest`/`:nightly` tags. `update.sh` mirrors
the same tag for its manual pull/restart path; keep the two in sync when bumping
(see [UPGRADE.md](./UPGRADE.md) "Maintainer: bumping the pinned image").

Persistent storage:

| Host path | Container path | Purpose |
|-----------|-----------------|---------|
| `/var/lib/euro-office/data` | `/var/www/euro-office/Data` | Document-server data: its `secure_link_secret` (and custom fonts, if added). Owned `105:107` (the image's `ds`), mode 2775. Documents live in Nextcloud, not here. Until 2026-10-04 this was mounted at the OnlyOffice path and stayed empty |
| `/etc/euro-office/ds-example.conf` | `/etc/nginx/includes/ds-example.conf` (ro) | Welcome-page bind mount |

The built-in `/example/` test app is disabled (`EXAMPLE_ENABLED=false`).

Health: no in-container `HEALTHCHECK` is declared in `euro-office.nix`; `test.sh` and
`ready.sh` probe externally, at `http://localhost/healthcheck` and
`http://localhost/web-apps/apps/api/documents/api.js`. After a (re)start, allow roughly
20-40 seconds before these answer.

## Dependencies rationale

| `dependsOn` | Why |
|-------------|-----|
| `cluster:vm` | Provisions the VM |
| `templates:nixos` | NixOS base image the container runs on |
| `backup:vm` | Whole-VM coverage in the shared Proxmox Backup Server job, the module's only backup (see Backup & restore) |
| `network:proxy` | Public HTTPS endpoint for the editor, plus internal `srv`-zone access on port 80 |
| `network:rules` | Firewall pass rules |
| `nextcloud:fileservice` | Triggers the connector wiring: `config["nextcloud:fileservice"].connector = "onlyoffice"` tells the `nextcloud` module which connector type to configure |

Connector ownership: euro-office does only its own layer — the document server and its
auto-generated JWT secret. The Nextcloud <-> euro-office connector itself is wired from
the Nextcloud side: because this module depends on `nextcloud:fileservice` with
`connector = "onlyoffice"`, the `nextcloud` module's own
`services/fileservice/update-service.sh` writes `/etc/secrets/onlyoffice.env` on the
Nextcloud VM (`JWT_SECRET`, `EURO_OFFICE_URL`, `EURO_OFFICE_INTERNAL_URL`,
`NEXTCLOUD_PUBLIC_URL`) and restarts `nextcloud-configure-eurooffice`, which applies them
via `nextcloud-occ config:app:set eurooffice ...`. No cross-VM SSH originates from this
module for that step; `install.sh` here explicitly notes the connector wiring happens in
the Nextcloud module, not this one.

`update-jwt.sh` in this module is the manual resync tool: it reads `JWT_SECRET` from
`/etc/secrets/euro-office.env` on this VM over SSH, then over SSH runs 5
`nextcloud-occ config:app:set eurooffice <key>` commands on the Nextcloud VM
(`DocumentServerUrl`, `DocumentServerInternalUrl`, `StorageUrl`, `jwt_secret`,
`jwt_header`). The normal path after a JWT rotation is `update-module.sh euro-office`, which
re-reads the secret through the connector; `update-jwt.sh` remains as a manual tool.

## Configuration & install-time overrides

An installer overrides defaults by copying `euro-office.json` to
`/home/tappaas/config` and editing it before installing. Fields most likely to change:

| Field | Default | Meaning |
|-------|---------|---------|
| `config["cluster:vm"].cores` / `.memory` / `.diskSize` | 4 / 8192 / 32G | VM sizing |
| `config["network:proxy"].proxyPort` | 80 | Port the reverse proxy forwards to |
| `config["nextcloud:fileservice"].connector` | `onlyoffice` | Fixed connector-type label read by the `nextcloud` module — not the Nextcloud app ID (that is `eurooffice`); do not repurpose it |
| `zone0` (resolved at install/update time, not a json key) | `srv` | Deployment zone (`get_config_value 'zone0' 'srv'`) |

## Secrets

A JWT secret authenticates requests between Nextcloud and the document server.

- Generated once, automatically: `euro-office-init-secrets.service` runs
  `openssl rand -hex 32` and writes it to `/etc/secrets/euro-office.env` (mode 600) —
  only if that file does not already exist.
- Consumed by the container via `environmentFiles`.
- Mirrored to the Nextcloud VM as `/etc/secrets/onlyoffice.env` by the `nextcloud`
  module's `services/fileservice/update-service.sh` (see Dependencies rationale).
- To rotate, see INSTALL.md's "Rotate the JWT secret".

Developer note: on Nextcloud 35, `nextcloud-occ config:app:set` for a setting an app
declares as typed (in its config lexicon) must pass the type (e.g. `--type=string`), or
Nextcloud silently ignores it. The `eurooffice` connector v11 declares no typed settings, so
its plain `config:app:set` calls work; re-check if a later connector adds a lexicon.

## Sizing

Default sizing (`euro-office.json`): 4 vCPU, 8 GB RAM, 32 GB disk. No load-based scaling
guidance is documented for this module.

## Backup & restore

`backup:vm` puts the whole VM in the site's Proxmox Backup job; the module keeps no backup of
its own. There is little to keep: documents are stored in Nextcloud, the JWT secret shared with
Nextcloud is in `/etc/secrets`, and `/var/lib/euro-office/data` holds only the server's
`secure_link_secret` (and custom fonts, if any) — a secret the server regenerates when it is
missing, at the cost of download links in flight. Restore is a VM restore:
[RESTORE.md](../../foundation/backup/RESTORE.md).

## Deploy notes and known limitations (0.2.2)

- Module status: `Testing`.
- The document server needs roughly 20-40 seconds after a (re)start before it answers
  its healthcheck; this is expected, not a fault.

## Related documents

- [README.md](./README.md) — end-user overview (what you get)
- [INSTALL.md](./INSTALL.md) — admin install / operate
- [UPGRADE.md](./UPGRADE.md) — upgrade guide
