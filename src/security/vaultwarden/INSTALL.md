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

   `DOMAIN` is not yours to edit: `vaultwarden-configure-oidc` writes it from the site's
   published name (`https://vaultwarden.<domain>`), or the internal address while that name
   has no public record (#769).

   Then restart the service: `sudo systemctl restart vaultwarden`.

3. Log in to `https://vaultwarden.<domain>/admin` with the `ADMIN_TOKEN` and create/invite
   users (public signups are disabled).

## Single sign-on

`identity:identity` registers Vaultwarden with the site's Authentik, and
`vaultwarden-configure-oidc` turns that into Vaultwarden's `SSO_*` settings (#769). The web
vault then offers *Use single sign-on*. SSO is on only when the name is published, the client
is registered and Authentik's discovery document is readable; otherwise it is off and
password login works as before. It never replaces the master password, which still decrypts
the vault, and with public signups disabled a new SSO user still needs an invitation.

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

**Links or vault URLs point at `example.com` or the internal address**
`DOMAIN` comes from `/etc/secrets/vaultwarden-sso.env`, written by
`vaultwarden-configure-oidc` (#769). An internal address means the public name has no DNS
record yet; once it has, the next update writes the https URL. Check with
`journalctl -u vaultwarden-configure-oidc`.

**No "Use single sign-on" button**
SSO is off: see `journalctl -u vaultwarden-configure-oidc` for why (no public name, no
registered client, or the discovery document was unreadable).

**No verification / invitation emails**
SMTP is not configured. Uncomment and fill in the `SMTP_*` lines in the environment file (see
the [upstream SMTP guide](https://github.com/dani-garcia/vaultwarden/wiki/SMTP-configuration)) and
restart the service. Keep `SMTP_HOST` commented while there is no mail server: an empty
`SMTP_HOST=` still turns mail on, and account creation then fails with "SMTP error: Connection
error: failed to lookup address information".

**Service not starting**
Check the journal on the VM: `sudo journalctl -u vaultwarden -n 50`.
