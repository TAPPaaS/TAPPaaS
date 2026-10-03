# Nextcloud — Installation

Primary audience: TAPPaaS admin.

## Prerequisites

1. Authentik (`identity:identity`) is installed. It is a required dependency, not an optional
   one: Nextcloud has no way to sign users in besides Authentik and the local emergency account.

> To deviate from the defaults in `./nextcloud.json` (target node, storage, zone/VLAN,
> sizing), copy the json to `/home/tappaas/config` and edit it before installing.

The public domain is derived as `<vmname>.<domain>` from the environment configuration — no
`proxyDomain` is hardcoded in the module json.

## Install

    install-module.sh nextcloud

What happens automatically:

1. The platform dependencies provision the VM, ship and rebuild `nextcloud.nix` against the
   pinned nixpkgs revision, publish the reverse-proxy route, apply firewall rules, and add the
   VM to the platform's backup job.
2. On first boot, admin and database passwords are generated, PostgreSQL and Redis start, and
   Nextcloud installs itself non-interactively.
3. `install.sh` reads the generated admin password off the VM, saves it to
   `/home/tappaas/secrets/nextcloud.env` on tappaas-cicd, and prints the admin login.

## Post-install

**Single sign-on (Authentik / `user_oidc`):** nothing to do. The `identity:identity` service
creates Nextcloud's application in Authentik, writes `OIDC_CLIENT_ID`, `OIDC_CLIENT_SECRET` and
`OIDC_DISCOVERY_URI` to `/etc/secrets/nextcloud.env` on the VM, and restarts
`nextcloud-configure-oidc`. The login page then goes straight to Authentik.
Emergency bypass: a local account can still sign in at `https://nextcloud.<domain>/login?direct=1`.

**Mail (system email):** populate `/etc/secrets/mail.env` on the VM with `SMTP_USER` and
`SMTP_PASSWORD` so Nextcloud can send its own outbound notifications (password resets, share
emails).

**Mail app — optional Microsoft 365 sign-in:** create an Entra app registration with redirect
URI `https://<domain>/apps/mail/integration/microsoft-auth`, delegated permissions
`offline_access`, `IMAP.AccessAsUser.All`, `SMTP.Send`, and admin consent. Put
`MS_TENANT_ID`, `MS_CLIENT_ID` and `MS_CLIENT_SECRET` into
`/home/tappaas/secrets/<vmname>-mail-microsoft.env` on tappaas-cicd, then run
`update-module.sh nextcloud`. The mailboxes involved must allow IMAP and authenticated SMTP in
Exchange Online.

**Document editing, Talk relay and Talk call scaling:** none. Installing `euro-office`,
`coturn` or `nextcloud-hpb` wires each connector in automatically via `nextcloud:fileservice`.

**Public internet access (optional):** Nextcloud is reachable only from internal zones by
default. To publish it on the internet, set `config["network:proxy"].proxyAllowedZones` to
`["internet"]` in `nextcloud.json` and run `update-module.sh nextcloud`.

## Verification

    test-module.sh nextcloud

| Check | Expected |
|-------|----------|
| Web response | HTTP 200 or 3xx redirect |
| `installed` flag in `config.php` | `true`, maintenance mode off |
| PostgreSQL and Redis services | active |
| No in-guest backup | `/var/backup/nextcloud` and the old backup timers gone (PBS takes the VM) |
| Secret file permissions | mode 0600 |
| Firewall ports | 22 and 80 open, 9980 closed |
| OIDC app (`user_oidc`) | enabled |
| `onlyoffice` connector | `DocumentServerUrl` matches the `euro-office` module's URL |
| Public domain | present in `trusted_domains` |
| Installed apps | at the version this module ships |
| User acceptance | sign in via web and the iOS/Android client, upload and download a file |

## Troubleshooting

**`install-module.sh` exits with a dependency error**
A required dependency is not installed (`cluster:vm`, `templates:nixos`, `backup:vm`,
`network:proxy`, `network:rules`, `identity:identity`). Install the missing module first, then
retry.

**Nextcloud not reachable after first boot**
NixOS first-boot activation may still be running. Check from tappaas-cicd:

    ssh tappaas@nextcloud.srv.internal "sudo journalctl -u phpfpm-nextcloud -n 30"

Wait a few minutes, then run `test-module.sh nextcloud` again.

**Admin password unknown**
It is saved to `/home/tappaas/secrets/nextcloud.env` on tappaas-cicd at install time; the
source of truth is `/var/lib/nextcloud/admin-pass` on the VM:

    ssh tappaas@nextcloud.srv.internal "sudo cat /var/lib/nextcloud/admin-pass"

**A user's apps keep asking them to log in again**
This happens after that user's Nextcloud user ID changes (for example, an auth-backend
switch). Every Nextcloud app on every device must remove and re-add the account; the repeated
failed logins in between can trigger brute-force throttling. Clear it for the user's address:

    ssh tappaas@nextcloud.srv.internal "sudo nextcloud-occ security:bruteforce:reset <ip>"

For upgrades see [UPGRADE.md](./UPGRADE.md).
