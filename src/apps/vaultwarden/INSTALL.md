# Vaultwarden — Installation

Primary audience: TAPPaaS admin.

## Prerequisites

1. Register `vaultwarden.<domain>` with your public DNS provider (points at your WAN address) so
   the reverse proxy can obtain a certificate and internet clients can reach the vault.

> To deviate from the defaults in `./vaultwarden.json` (target node, storage,
> zone/VLAN, sizing), copy the json to `/home/tappaas/config` and edit it
> before installing.

## Install

    install-module.sh vaultwarden

On first boot the VM auto-generates an `ADMIN_TOKEN` into
`/var/lib/vaultwarden/vaultwarden.env` (mode 0600).

## Post-install

1. Retrieve the admin token on the VM:

       ssh tappaas@vaultwarden.dmz.internal \
         "sudo cat /var/lib/vaultwarden/vaultwarden.env"

   It is also shown in the journal: `journalctl -u generate-vaultwarden-secrets`.

2. Edit `/var/lib/vaultwarden/vaultwarden.env` on the VM:
   - `DOMAIN` — set to your real `https://vaultwarden.<domain>` (ships with an
     `example.com` placeholder).
   - `SMTP_*` — mail server settings for account verification and notifications.

   Then restart the service: `sudo systemctl restart vaultwarden`.

3. Log in to `https://vaultwarden.<domain>/admin` with the `ADMIN_TOKEN` and create/invite
   users (public signups are disabled).

## Verification

    test-module.sh vaultwarden

Note: this module does not yet ship an automated `test.sh`; verify manually:

| Check | Expected |
|-------|----------|
| `https://vaultwarden.<domain>` | Bitwarden web vault loads |
| `https://vaultwarden.<domain>/admin` | admin panel accepts the `ADMIN_TOKEN` |
| `systemctl is-active vaultwarden` on the VM | `active` |
| Port 8222 on `vaultwarden.dmz.internal` | reachable from the proxy (HTTP API) |
| `/var/backup/vaultwarden/` on the VM | daily SQLite backups appear |

## Troubleshooting

**Admin token lost**
It persists in `/var/lib/vaultwarden/vaultwarden.env` on the VM:
`sudo cat /var/lib/vaultwarden/vaultwarden.env`.

**Links or vault URLs point at `example.com`**
`DOMAIN` in `/var/lib/vaultwarden/vaultwarden.env` was not updated after install. Set it to
your real public URL and restart `vaultwarden.service`.

**No verification / invitation emails**
SMTP is not configured. Fill in the `SMTP_*` values in the environment file (see the
[upstream SMTP guide](https://github.com/dani-garcia/vaultwarden/wiki/SMTP-configuration)) and
restart the service.

**Service not starting**
Check the journal on the VM: `sudo journalctl -u vaultwarden -n 50`.
