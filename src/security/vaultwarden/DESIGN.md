# Vaultwarden — Design notes

Implementation detail moved out of README/INSTALL (Diataxis: explanation).

## Architecture

- Native NixOS `services.vaultwarden` (lightweight, no container); package pinned via the
  `versions` block in `vaultwarden.nix` (`pkgs.vaultwarden`).
- SQLite backend (default, sufficient for SMB/home use).
- Rocket HTTP API on `0.0.0.0:8222`, behind the Caddy reverse proxy; VM firewall opens TCP 22
  (SSH) and 8222 only.
- DMZ zone placement (nix header notes VLAN 610, 10.6.0.0/24); the reverse proxy is allowed
  from the `internet` zone (`network:proxy` → `proxyAllowedZones: ["internet"]`).
- `SIGNUPS_ALLOWED = false` is fixed declaratively; `ADMIN_TOKEN` and `SMTP_*` come from the
  generated environment file, `DOMAIN` from `vaultwarden-site-url` (below).

## Secrets

The oneshot `generate-vaultwarden-secrets` service runs before `vaultwarden.service` on first
boot only (`ConditionPathExists=!/var/lib/vaultwarden/vaultwarden.env`). It generates a random
64-hex `ADMIN_TOKEN` and writes `/var/lib/vaultwarden/vaultwarden.env` (mode 0600, owned by
`vaultwarden`) with the `SMTP_*` lines commented out for the admin to fill in. Installs before
#769 also wrote a placeholder `DOMAIN` there; the site file below is loaded after it and
overrides it. Older installs also wrote an empty `SMTP_HOST=`, which Vaultwarden reads as a host (mail on,
every send fails); `vaultwarden-smtp-unset-empty.service` comments that block out before each
start while `SMTP_HOST` is empty.

## Site URL, and why there is no SSO

`vaultwarden-site-url.service` writes `/etc/secrets/vaultwarden-site.env`:

- `DOMAIN` from the companion `/etc/nixos/vaultwarden.json` (the logging.nix idiom, #715):
  `https://<proxyDomain>` when the name is published, otherwise the internal
  `http://vaultwarden.<zone>.internal:8222`.
- `SSO_ENABLED=false`, pinned.

The file is always written — Vaultwarden's `EnvironmentFile` list fails on a missing file — and
Vaultwarden is restarted (`--no-block`) only when its content changes. Vaultwarden wants and
follows the unit rather than requiring it.

No SSO, by decision (2026-10-06): a password vault must not open with the identity provider —
one compromised Authentik session would reach every stored secret — nor stop opening when
Authentik is down, which is when its credentials are needed most. #769 had wired
`identity:identity`'s OIDC client into Vaultwarden's `SSO_*`; 0.6.0 withdraws it. Removing the
dependency makes `update-module.sh` run identity's `delete-service.sh`, which deletes the
Authentik application, and the unit deletes the client it left on the VM
(`/etc/secrets/vaultwarden.env`) and the old `/etc/secrets/vaultwarden-sso.env`. A
`sso_users` row in the database for an account once reached by SSO is left alone: unused while
SSO is off, and the account keeps its master password.

## Backup design

- SQLite backup: the upstream backup service (enabled via `services.vaultwarden.backupDir`)
  copies the database daily to `/var/backup/vaultwarden/`.
- Archive: `vaultwarden-backup-archive` timer daily at 03:00 tars vault data + the environment
  file (secrets included) to `/var/backup/vaultwarden-archives/` (mode 0600).
- Retention: `cleanup-backups` timer runs monthly and deletes files under `/var/backup` older
  than 30 days.
