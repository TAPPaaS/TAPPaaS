# Nextcloud — Installation

Only manual steps are listed here. Scripts handle everything else automatically.

## Prerequisites

Verify `nextcloud.json` matches your environment (node, storage, zone).
Authentik (`identity:identity`) must be deployed for SSO. The public domain is derived from
`vmname` + `tappaas.domain` — no `proxyDomain` is hardcoded.

## Install

```bash
cd /home/tappaas/TAPPaaS/src/apps/nextcloud
install-module.sh nextcloud
```

Duration: **~9 minutes** measured on a fresh VM (clean exit-0 deploy 2026-06-11, test variant on
srvWork). Dominated by the first-time NixOS rebuild building Nextcloud + the eurooffice connector and
`uppush` from source (uncached). Subsequent deploys that hit the nix store cache are faster; a stalled
`uppush`/codeberg `/archive` fetch can inflate this substantially (build-time SPOF — see backlog).

## Customisation (optional)

Override any JSON field at install time:

```bash
install-module.sh nextcloud --node tappaas1 --zone0 srvWork --vmid 340
```

| Flag | Default | Controls |
|---|---|---|
| `--zone0` | `srvWork` | Network zone (VLAN) |
| `--vmid` | `340` | Proxmox VM ID |
| `--node` | `tappaas1` | Proxmox node |
| `--memory` | `8192` | RAM in MB |

## Post-install

**SSO (Authentik / `user_oidc`):** the `nextcloud-configure-oidc` service activates on next boot once
`OIDC_DISCOVERY_URI` is present. Register the Nextcloud client in Authentik (redirect URI
`https://nextcloud.<domain>/apps/user_oidc/code`).

**Document editing (euro-office connector):** no action here. When the `euro-office` module is installed
(`dependsOn nextcloud:fileservice`), nextcloud's `services/nextcloud/install-service.sh` writes
`/etc/secrets/onlyoffice.env` and the declarative `nextcloud-configure-eurooffice` service applies it
(ADR-COM-0002). The `onlyoffice` app ships as a Nix `extraApp`.

**Mail:** populate `/etc/secrets/mail.env` (SMTP host/port/credentials) for outbound notifications.

## Verification

```bash
cd /home/tappaas/TAPPaaS/src/apps/nextcloud
./test.sh nextcloud
```

User test (acceptance): log in via web + iOS/Android client, upload and download a file. The
document-editing user test is owned by the euro-office connector
(`services/nextcloud/test-service.sh`).

## Backup and restore

Daily automated backups: PostgreSQL dump + data-dir at 02:00–02:30, 30-day retention in
`/var/backup/nextcloud/` (via `backup:vm`).

## Troubleshooting — install-module failures

**install-module.sh exits with dependency error**
A required service is not installed (`cluster:vm`, `templates:nixos`, `backup:vm`, `firewall:proxy`,
`identity:identity`). Install the missing module first, then retry.

**Nextcloud not reachable after first boot**
NixOS first-boot may still be running. Check from inside the VM:
```bash
ssh tappaas@nextcloud.srvWork.internal "sudo journalctl -u phpfpm-nextcloud -n 30"
```
Wait 2–3 minutes, then run `./test.sh nextcloud`.
