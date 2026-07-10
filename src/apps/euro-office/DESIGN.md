# euro-office — Design notes

## Architecture

A single Podman container bundles every service internally; only port 80 is exposed to
the host.

| Component | Role |
|-----------|------|
| Nginx | Serves the editor UI and routes all paths (port 80) |
| DocService (Node.js) | Document co-authoring engine |
| FileConverter (C++) | Format conversion |
| PostgreSQL / Redis / RabbitMQ | Session storage, cache, internal bus |

Image: `ghcr.io/euro-office/documentserver:v9.3.1` — pinned (immutable semver) in
`euro-office.nix`. Do not use the mutable `:latest`/`:nightly` tags. `update.sh` mirrors
the same tag for its manual pull/restart; keep the two in sync when bumping
(see [UPGRADE.md](./UPGRADE.md) "Maintainer: bumping the pinned image").

## Connector ownership (ADR-COM-0002)

euro-office does only its own layer (the document server + its auto-generated JWT in
`euro-office.nix`). The euro-office <-> Nextcloud connector is wired by Nextcloud: its
`services/nextcloud/install-service.sh` (N4) fires because this module declares
`dependsOn nextcloud:fileservice` + `config["nextcloud:fileservice"].connector =
"onlyoffice"`; it reads euro-office's JWT, writes `/etc/secrets/onlyoffice.env` on the
Nextcloud VM, and restarts `nextcloud-configure-eurooffice`. No cross-VM SSH from this
module. The document-server -> Nextcloud return path is declared here as `egress`
(`network:rules`).

`update-jwt.sh` in this module is the manual resync tool: it reads `JWT_SECRET` from the
euro-office VM and pushes it plus the connector URLs into the Nextcloud app config
(variant-aware). Use after a manual JWT rotation.

## Clients

Editing is not browser-only. Because the server is OnlyOffice-compatible, the official
OnlyOffice clients open the same documents through Nextcloud (they connect to Nextcloud,
not to this server directly):

| Client | Platform | How |
|--------|----------|-----|
| Browser (default) | any | Open a document in Nextcloud Files |
| OnlyOffice Desktop Editors | macOS (Intel/ARM), Windows, Linux | "Connect to cloud" -> add Nextcloud |
| OnlyOffice Documents | iOS, Android | Same Nextcloud connection |

Desktop download (free): <https://www.onlyoffice.com/download-desktop.aspx>

## Backup and restore

Documents are backed up automatically — daily at 02:00 (stop -> tar -> restart), stored
at `/var/backup/euro-office/` on the VM, 30-day retention. To restore, stop the
container, extract the archive over `/var/lib/euro-office/data`, and restart:

    ssh tappaas@euro-office.srv.internal "sudo systemctl stop podman-euro-office && \
      sudo tar xzf /var/backup/euro-office/<archive>.tar.gz -C /var/lib/euro-office && \
      sudo systemctl start podman-euro-office"

The VM itself is additionally covered by `backup:vm` (full-VM PBS backup).

## Deploy notes and known limitations (0.1.0)

- Validated via test variant; the OnlyOffice <-> Nextcloud connector is proven end-to-end
  (N4 wiring, ADR-COM-0002).
- The consumer egress (srv -> reverse proxy:443) is declared in this module;
  named-variant deploys depend on the foundation egress-flattening + provider-variant
  resolution fixes (upstream issue).

## Superseded install-time customisation

Earlier docs suggested per-flag overrides (`install-module.sh euro-office --node tappaas2
--zone0 srvDev --vmid 399`, flags `--node`, `--zone0`, `--vmid`, `--memory`). The current
convention is to copy `euro-office.json` to `/home/tappaas/config` and edit it before
installing.
