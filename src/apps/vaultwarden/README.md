# VaultWarden Password Manager for TAPPaaS

Bitwarden-compatible password manager running in the DMZ zone.

## Architecture

- **VaultWarden** - Native NixOS service (lightweight, no container)
- **SQLite** - Default database backend
- **Port 8222** - HTTP API (behind Caddy reverse proxy)

## Installation Steps

1. Register `vaultwarden.<mydomain>` in your DNS provider
2. Configure Caddy to reverse proxy `vaultwarden.<mydomain>` to `vaultwarden.dmz.internal:8222`
3. Create firewall rule to allow internet pinhole to DMZ (already covered by DMZ zone rules)
4. Run `./install.sh` from the tappaas-cicd command line to create the vaultwarden VM
5. Access VaultWarden at `https://vaultwarden.<mydomain>`
6. Access admin panel at `https://vaultwarden.<mydomain>/admin` (use the ADMIN_TOKEN from first boot)

## Post-Install Configuration

Edit `/var/lib/vaultwarden/vaultwarden.env` on the VM to configure:
- `DOMAIN` - Set to your actual `https://vaultwarden.<mydomain>`
- `SMTP_*` - Configure email for account verification and notifications

## Secrets

On first boot, `ADMIN_TOKEN` is auto-generated and saved to `/var/lib/vaultwarden/vaultwarden.env`.
The token is displayed in the journal: `journalctl -u generate-vaultwarden-secrets`

## Backups

- SQLite backup: daily via built-in VaultWarden backup service -> `/var/backup/vaultwarden/`
- Archive (data + secrets): daily at 03:00 -> `/var/backup/vaultwarden-archives/`
- Retention: 30 days (monthly cleanup)
