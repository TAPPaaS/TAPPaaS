# Nextcloud — Design notes

Implementation and deployment detail moved out of README/INSTALL (Diataxis: explanation).

## Why this exists

Nextcloud is the platform's collaboration hub: files, document editing, calls/chat and
productivity apps behind single sign-on. Document editing, the TURN relay and the call backend are separate
modules — `euro-office`, `coturn`, `nextcloud-hpb` — that plug into Nextcloud through the
`fileservice` service it provides.

## Architecture

- NixOS native `services.nextcloud` (PHP-FPM + internal nginx); the VM listens on port 80,
  Caddy (`network:proxy`) terminates TLS.
- PostgreSQL 15 (`postgresql_15`, NixOS-native), a dedicated `nextcloud` database and user,
  `dbhost = 127.0.0.1`, `database.createLocally = false`.
- Redis (named server `nextcloud`) for file locking and APCu caching, via unix socket
  `/run/redis-nextcloud/redis.sock`.
- Max upload size 16G.
- Whiteboard: a co-located Node service (`nextcloud-whiteboard-server`, port 3002); nginx
  proxies `/socket.io/` to it. Its JWT secret is auto-generated on first boot if absent, and
  pushed into the app by `nextcloud-configure-whiteboard`.
- Preview generation: `nextcloud-preview-backfill` renders thumbnails for existing files once;
  `nextcloud-preview-generate` renders them incrementally on a daily timer.
- Office editing is handled externally by the `euro-office` module (port 9980 is deliberately
  closed on this VM).
- Version pinning: the single `ncMajor` value at the top of `nextcloud.nix` drives both the
  Nextcloud package and its app-set selection (`pkgs."nextcloud${ncMajor}"` and
  `pkgs."nextcloud${ncMajor}Packages".apps`). Majors must be bumped sequentially — see
  [UPGRADE.md](./UPGRADE.md).

## Connectors

Nextcloud offers three connector slots through `nextcloud:fileservice`, selected by the
consuming module's own `connector` field (`onlyoffice`, `talk` or `hpb`). The wiring logic runs
on this (the Nextcloud) side, not the consumer's:

| Connector | Consumer module | Written on this VM | Applied by |
|-----------|------------------|---------------------|------------|
| `onlyoffice` | `euro-office` | `/etc/secrets/onlyoffice.env` (`JWT_SECRET`, `EURO_OFFICE_URL`, `EURO_OFFICE_INTERNAL_URL`, `NEXTCLOUD_PUBLIC_URL`) | `nextcloud-configure-eurooffice` (`occ config:app:set` on app id `eurooffice`) |
| `talk` | `coturn` | `/etc/secrets/talk.env` (`TURN_SERVER`, `TURN_SERVER_INTERNAL`, `TURN_SECRET`) | `nextcloud-configure-talk-turn` (`occ talk:stun:add` / `talk:turn:add`) |
| `hpb` | `nextcloud-hpb` | `/etc/secrets/hpb.env` (`HPB_SECRET`, `HPB_URL`) | `nextcloud-configure-hpb` (`occ talk:signaling:add`) |

All three files are written by this module's own `services/fileservice/update-service.sh`, run
over SSH against this VM, when the consumer module installs or updates. Each
`nextcloud-configure-*` unit is gated on its secrets file existing (`ConditionPathExists`) and
re-applies the connector on every boot.

The connector's Nextcloud app ID is `eurooffice`, not `onlyoffice` — the app was renamed in
connector v11. The TAPPaaS connector label and the `onlyoffice.env` filename keep the old name
on purpose, for backward compatibility.

`services/fileservice/install-service.sh` is fatal if `/status.php` does not report
`"installed":true` before wiring a connector in; `update-service.sh` only warns if Nextcloud is
unreachable, and still re-applies the wiring.

## Provided service

| Service (`provider:service`) | What a dependent gets | Hook(s) |
|-------------------------------|------------------------|---------|
| `nextcloud:fileservice` | The core collaboration platform plus one of the three connectors above | `services/fileservice/{install,update}-service.sh` |

Consumed by `coturn`, `nextcloud-hpb` and `euro-office` (each declares
`dependsOn: nextcloud:fileservice`).

## Dependencies rationale

- `cluster:vm`, `templates:nixos` — VM and NixOS base image.
- `backup:vm` — adds the VM to the platform's shared Proxmox Backup Server job, the module's
  only backup (see Backup & restore).
- `network:proxy` — HTTPS reverse proxy; `proxyPort = 80`.
- `network:rules` — firewall pass rules.
- `identity:identity` — **required**, not optional. Authentik is the sole login backend:
  `allow_multiple_user_backends` is set to `0`, so the login page goes straight to Authentik; a
  local account remains reachable at `/login?direct=1`. `providesAdminRole` /
  `adminGroupClaim: "admin"` maps Authentik's `admin` group onto Nextcloud's admin role, and
  `--unique-uid=0` makes the Authentik username the Nextcloud user ID — decide this before
  first use, since changing it later orphans every existing user's files, shares and client
  accounts.

## Configuration & install-time overrides

- `ncMajor` (in `nextcloud.nix`) pins the Nextcloud major; see [UPGRADE.md](./UPGRADE.md).
- `zone0` defaults to `srv`; `proxyPort` is `80`.
- `trusted_domains` (internal FQDN + public domain) is declared in `nextcloud.nix` from the
  companion JSON, so every rebuild writes it. `update.sh`'s `converge_nextcloud_domains` then
  checks the public domain the way a client does — an HTTP request with that `Host` header —
  and sets `trusted_domains` / `overwrite.cli.url` / `overwriteprotocol=https` with `occ` only
  if it is missing. The request is the proof: Nextcloud keeps declared settings in a store JSON
  that `override.config.php` merges at runtime, so `config.php` alone does not show them, and
  `nextcloud-occ` over a non-TTY ssh session returns no output. `test-module.sh` checks the
  public domain is trusted.
- `proxyAllowedZones` defaults to the internal zones only —
  never the internet. Add `"internet"` to publish Nextcloud publicly.
- Any field can also be overridden on the command line, e.g.
  `install-module.sh nextcloud --node <node> --zone0 srv --memory 8192`.

## Secrets

| File | Where | Holds | Populated by |
|------|-------|-------|---------------|
| `/var/lib/nextcloud/admin-pass`, `/var/lib/nextcloud/db-pass` | VM | Admin & DB passwords | auto-generated on first boot (`nextcloud-init-secrets`) if absent |
| `/etc/secrets/nextcloud.env` | VM | `OIDC_CLIENT_ID`, `OIDC_CLIENT_SECRET`, `OIDC_DISCOVERY_URI` | the `identity:identity` service (creates the Authentik application and writes the file) |
| `/etc/secrets/onlyoffice.env` | VM | euro-office connector JWT + URLs | `services/fileservice/update-service.sh` (see Connectors) |
| `/etc/secrets/talk.env` | VM | coturn TURN relay credentials | `services/fileservice/update-service.sh` |
| `/etc/secrets/hpb.env` | VM | HPB signaling secret + URL | `services/fileservice/update-service.sh` |
| `/etc/secrets/mail.env` | VM | `SMTP_USER`, `SMTP_PASSWORD` (system outbound notification email) | operator |
| `/etc/secrets/mail-microsoft.env` | VM | `MS_TENANT_ID`, `MS_CLIENT_ID`, `MS_CLIENT_SECRET` (Microsoft 365 sign-in for the Mail app) | copied by `update.sh`'s `converge_mail_microsoft` from `/home/tappaas/secrets/<vmname>-mail-microsoft.env` on the management host |
| `/etc/secrets/whiteboard.env` | VM | Whiteboard JWT secret | auto-generated on first boot if absent |
| `/home/tappaas/secrets/nextcloud.env` | management host | mirror of the admin password | `install.sh`, read from the VM over SSH |

`/etc/secrets` (0700 root:root) and `/var/lib/nextcloud` (0700 nextcloud:nextcloud) are created
by `systemd.tmpfiles.rules`; individual files are mode 0600.

## Sizing

Default: 4 cores / 8192 MB memory / 80G disk.

## Backup & restore

The platform's PBS job, via the `backup:vm` dependency, backs up the whole VM — database, data
and config together — with the site's schedule and retention (ADR-012). Restore is the backup
module's: [RESTORE.md](../../foundation/backup/RESTORE.md).

The module no longer keeps copies of its own inside the VM. Its old pg_dump and data-tar
timers wrote to the VM's own disk, so they did not survive what PBS is there for, and the
dump had failed every night on a directory it could not write. A tmpfiles `R` rule removes
`/var/backup/nextcloud` from VMs that still have it.

## Deploy notes & known limitations (0.2.0)

- uppush 2.6.0 fails its first database migration on Nextcloud 35; a local patch works around
  it until upstream fixes it (uppush issue #124, open).
- notify_push's app and daemon must match; nixpkgs ships 1.3.3 (Nextcloud ≤34 only), so both
  are pinned here to 1.4.1.
- `news` (29.0.0-beta.1, a pre-release), `previewgenerator` and `uppush` are pinned from the
  Nextcloud app store because nixpkgs' `nextcloud35Packages.apps` was last regenerated before
  these apps shipped 35 support. Drop each pin once nixpkgs carries it.
- `quota_warning` is not included: it has no release for Nextcloud 35 yet.
- Talk's admin page may warn that the signaling server lacks the feature `changed-users`. It is
  optional; calls still work. It goes away once a signaling-server release includes it.
- After a user's Nextcloud user ID changes, every Nextcloud app on every device must remove and
  re-add the account, or the resulting repeated failed logins trigger brute-force throttling
  (`occ security:bruteforce:reset <ip>` clears it).
- On Nextcloud 35, `occ config:app:set` for a setting an app declares as typed must pass the
  type (e.g. `--type=string`), or Nextcloud silently ignores it — relevant when writing a new
  `nextcloud-configure-*` unit.
- Multi-party Talk calls from outside the site additionally require a publicly reachable
  `coturn` (and `nextcloud-hpb` for larger calls): group video goes through the Janus SFU on
  the HPB, and clients that cannot reach the HPB directly are relayed by coturn.

## Related documents

- [README.md](./README.md) — end-user overview (what you get)
- [INSTALL.md](./INSTALL.md) — admin install / operate
- [UPGRADE.md](./UPGRADE.md) — upgrade guide, including the Nextcloud-major pin
