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
- `SIGNUPS_ALLOWED = false` is fixed declaratively; `DOMAIN`, `ADMIN_TOKEN` and `SMTP_*` come
  from the environment file.

## Secrets

The oneshot `generate-vaultwarden-secrets` service runs before `vaultwarden.service` on first
boot only (`ConditionPathExists=!/var/lib/vaultwarden/vaultwarden.env`). It generates a random
64-hex `ADMIN_TOKEN` and writes `/var/lib/vaultwarden/vaultwarden.env` (mode 0600, owned by
`vaultwarden`) with placeholder `DOMAIN` and empty `SMTP_*` values for the admin to fill in.

## Backup design

- SQLite backup: the upstream backup service (enabled via `services.vaultwarden.backupDir`)
  copies the database daily to `/var/backup/vaultwarden/`.
- Archive: `vaultwarden-backup-archive` timer daily at 03:00 tars vault data + the environment
  file (secrets included) to `/var/backup/vaultwarden-archives/` (mode 0600).
- Retention: `cleanup-backups` timer runs monthly and deletes files under `/var/backup` older
  than 30 days.
