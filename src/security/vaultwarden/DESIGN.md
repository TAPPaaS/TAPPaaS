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
  generated environment file, `DOMAIN` and `SSO_*` from `vaultwarden-configure-oidc` (below).

## Secrets

The oneshot `generate-vaultwarden-secrets` service runs before `vaultwarden.service` on first
boot only (`ConditionPathExists=!/var/lib/vaultwarden/vaultwarden.env`). It generates a random
64-hex `ADMIN_TOKEN` and writes `/var/lib/vaultwarden/vaultwarden.env` (mode 0600, owned by
`vaultwarden`) with empty `SMTP_*` values for the admin to fill in. Installs before #769 also
wrote a placeholder `DOMAIN` there; the SSO file below is loaded after it and overrides it.

## Site URL and SSO (#769)

`identity:identity` registers an OIDC application for the module and writes its client to
`/etc/secrets/vaultwarden.env`. `vaultwarden-configure-oidc.service` — the module's
`identity.configureService`, which identity:identity restarts after writing — turns that into
`/etc/secrets/vaultwarden-sso.env`:

- `DOMAIN` from the companion `/etc/nixos/vaultwarden.json` (the logging.nix idiom, #715):
  `https://<proxyDomain>` when the name is published, otherwise the internal
  `http://vaultwarden.<zone>.internal:8222`.
- `SSO_ENABLED`, `SSO_AUTHORITY` (the discovery document's `issuer`), `SSO_CLIENT_ID`,
  `SSO_CLIENT_SECRET`, `SSO_SCOPES` — only when the name is published, the client exists and
  the discovery document is readable. Otherwise `SSO_ENABLED=false`, and the unit still
  succeeds. `SSO_ONLY` stays off.

The redirect registered with Authentik is `/identity/connect/oidc-signin` (`vaultwarden.json`
`identity.oidcRedirectPaths`). The file is always written — Vaultwarden's `EnvironmentFile`
list fails on a missing file — and Vaultwarden is restarted (`--no-block`) only when its
content changes. Vaultwarden wants and follows the unit rather than requiring it, so a
restart of the unit does not also restart Vaultwarden through `Requires=`.

## Backup design

- SQLite backup: the upstream backup service (enabled via `services.vaultwarden.backupDir`)
  copies the database daily to `/var/backup/vaultwarden/`.
- Archive: `vaultwarden-backup-archive` timer daily at 03:00 tars vault data + the environment
  file (secrets included) to `/var/backup/vaultwarden-archives/` (mode 0600).
- Retention: `cleanup-backups` timer runs monthly and deletes files under `/var/backup` older
  than 30 days.
