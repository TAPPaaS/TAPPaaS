# Nextcloud — Installation

Primary audience: TAPPaaS admin.

## Prerequisites

1. Authentik (`identity:identity`) is deployed if you want single sign-on.
2. All other dependencies are installed (`cluster:vm`, `templates:nixos`, `backup:vm`,
   `network:proxy`, `network:rules`).

> To deviate from the defaults in `./nextcloud.json` (target node, storage,
> zone/VLAN, sizing), copy the json to `/home/tappaas/config` and edit it
> before installing.

The public domain is derived as `<vmname>.<domain>` from the environment configuration — no
`proxyDomain` is hardcoded in the module json.

## Install

    install-module.sh nextcloud

A first install takes roughly 9 minutes, dominated by the first NixOS rebuild (Nextcloud plus the
eurooffice connector and `uppush` are built from source when uncached). The installer prints the
admin login at the end and saves the admin password to `/home/tappaas/secrets/nextcloud.env` on
tappaas-cicd.

## Post-install

**Single sign-on (Authentik / `user_oidc`):** register the Nextcloud client in Authentik with
redirect URI `https://nextcloud.<domain>/apps/user_oidc/code`. Populate
`/etc/secrets/nextcloud.env` on the VM with `OIDC_CLIENT_ID`, `OIDC_CLIENT_SECRET` and
`OIDC_DISCOVERY_URI`; the `nextcloud-configure-oidc` service activates on the next boot.
Emergency admin bypass: `https://nextcloud.<domain>/login?direct=1`.

> Do NOT enable server-side encryption when using OIDC — OIDC cannot supply the cleartext
> password Nextcloud needs, causing irrevocable data loss. Use LDAP instead if encryption is
> required.

**Mail:** populate `/etc/secrets/mail.env` on the VM (SMTP host/port/credentials) for outbound
notifications.

**Document editing:** none. When the `euro-office` module is installed it wires itself into
Nextcloud automatically via its dependency on `nextcloud:fileservice`.

## Verification

    test-module.sh nextcloud

| Check | Expected |
|-------|----------|
| Web response on port 80 | HTTP 200 or 3xx redirect |
| `installed` flag in `config.php` | `true`, maintenance mode off |
| `postgresql` and `redis-nextcloud` services | active |
| Backup timers (`nextcloud-data-backup`, `postgresqlBackup-nextcloud`) | active |
| `/var/lib/nextcloud/admin-pass` and `db-pass` | present, mode 0600 |
| Firewall ports | 22 and 80 open, 9980 closed |
| Manual backup run (`nextcloud-data-backup.service`) | new `.tar.gz` in `/var/backup/nextcloud/data/` |
| User acceptance | log in via web + iOS/Android client, upload and download a file |

The document-editing user test is owned by the euro-office connector
(`services/nextcloud/test-service.sh`).

## Troubleshooting

**`install-module.sh` exits with a dependency error**
A required service is not installed (`cluster:vm`, `templates:nixos`, `backup:vm`,
`network:proxy`, `network:rules`, `identity:identity`). Install the missing module first, then
retry.

**Nextcloud not reachable after first boot**
NixOS first-boot activation may still be running. Check from tappaas-cicd:

    ssh tappaas@nextcloud.srv.internal "sudo journalctl -u phpfpm-nextcloud -n 30"

Wait 2–3 minutes, then run `test-module.sh nextcloud` again.

**Admin password unknown**
It is saved to `/home/tappaas/secrets/nextcloud.env` on tappaas-cicd at install time; the source
of truth is `/var/lib/nextcloud/admin-pass` on the VM:

    ssh tappaas@nextcloud.srv.internal "sudo cat /var/lib/nextcloud/admin-pass"

For upgrades see [UPGRADE.md](./UPGRADE.md).
