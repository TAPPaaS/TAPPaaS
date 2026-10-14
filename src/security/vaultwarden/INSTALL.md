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
   - `SMTP_*` — mail server settings for account verification and notifications.

   `DOMAIN` is not yours to edit: `vaultwarden-site-url` writes it from the site's
   published name (`https://vaultwarden.<domain>`), or the internal address while that name
   has no public record.

   Then restart the service: `sudo systemctl restart vaultwarden`.

3. Log in to `https://vaultwarden.<domain>/admin` with the `ADMIN_TOKEN` and create/invite
   users (public signups are disabled).

## No single sign-on

Vaultwarden is deliberately not behind the site's Authentik: the password vault must neither
open with the identity provider nor stop opening without it. Users sign in with their e-mail
and master password; there is no Authentik tile for it. `SSO_ENABLED=false` is pinned, and an
install that had SSO (#769, before 0.6.0) loses it on the next update — Authentik's
application and the OIDC client on the VM are removed. An account that was reached by SSO keeps
its master password and signs in with it.

## Verification

    test-module.sh vaultwarden

`test.sh` checks the service, `/alive`, the site URL, and that SSO is off. By hand:

| Check | Expected |
|-------|----------|
| `https://vaultwarden.<domain>` | Bitwarden web vault loads |
| `https://vaultwarden.<domain>/admin` | admin panel accepts the `ADMIN_TOKEN` |
| `systemctl is-active vaultwarden` on the VM | `active` |
| Port 8222 on `vaultwarden.dmz.internal` | reachable from the proxy (HTTP API) |
| No in-VM backup | no `/var/backup/vaultwarden*` on the VM (Proxmox Backup takes the VM) |

## Troubleshooting

**Admin token lost**
It persists in `/var/lib/vaultwarden/vaultwarden.env` on the VM:
`sudo cat /var/lib/vaultwarden/vaultwarden.env`.

**Links or vault URLs point at `example.com` or the internal address**
`DOMAIN` comes from `/etc/secrets/vaultwarden-site.env`, written by `vaultwarden-site-url`.
An internal address means the public name has no DNS record yet; once it has, the next update
writes the https URL. Check with `journalctl -u vaultwarden-site-url`.

**No verification / invitation emails**
SMTP is not configured. Uncomment and fill in the `SMTP_*` lines in the environment file (see
the [upstream SMTP guide](https://github.com/dani-garcia/vaultwarden/wiki/SMTP-configuration)) and
restart the service. Keep `SMTP_HOST` commented while there is no mail server: an empty
`SMTP_HOST=` still turns mail on, and account creation then fails with "SMTP error: Connection
error: failed to lookup address information".

**Service not starting**
Check the journal on the VM: `sudo journalctl -u vaultwarden -n 50`.
