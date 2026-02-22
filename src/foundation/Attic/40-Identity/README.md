# Identity VM for TAPPaaS (Authentik SSO)

The Identity module provides Single Sign-On (SSO) via Authentik.
VaultWarden has been moved to a separate module at `src/apps/vaultwarden/`.

## Architecture

- **Authentik Server** - Web UI + API (port 9000 HTTP, 9443 HTTPS)
- **Authentik Worker** - Background tasks (LDAP sync, email)
- **PostgreSQL 16** - User/group/policy storage
- **Redis 7** - Caching, sessions, task queue

## Installation Steps

1. Register `authentik.<mydomain>` in your DNS provider
2. Configure Caddy to reverse proxy `authentik.<mydomain>` to `identity.srv.internal:9000`
3. Create firewall rule to allow Caddy (DMZ) to `identity.srv.internal` TCP port 9000
4. Run `./install.sh` from the tappaas-cicd command line to create the identity VM
5. Access Authentik at `https://authentik.<mydomain>/if/flow/initial-setup/` to create the admin account

## Secrets

On first boot, `AUTHENTIK_SECRET_KEY` is auto-generated and saved to `/etc/secrets/authentik.env`.
A template with all available settings (including SMTP) is at `/etc/secrets/authentik-template.env`.

## Backups

- PostgreSQL dump: daily at 02:00 -> `/var/backup/postgresql/`
- Redis snapshot: daily at 02:30 -> `/var/backup/redis/`
- Config + secrets + media: daily at 02:45 -> `/var/backup/authentik-env/`
- Retention: 30 days (monthly cleanup)
