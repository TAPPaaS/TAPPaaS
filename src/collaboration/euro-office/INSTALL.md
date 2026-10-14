# euro-office — Installation

Primary audience: TAPPaaS admin.

## Prerequisites

1. `nextcloud` is installed and reachable (`nextcloud:fileservice` dependency) — install
   it before euro-office.

> To deviate from the defaults in `./euro-office.json` (target node, storage,
> zone/VLAN, sizing), copy the json to `/home/tappaas/config` and edit it
> before installing.

## Install

    install-module.sh euro-office

## Post-install

None for document editing. On first boot the VM generates a JWT secret automatically,
and the `nextcloud` module applies the connector settings on its own: it writes
`/etc/secrets/onlyoffice.env` on the Nextcloud VM (`JWT_SECRET`, `EURO_OFFICE_URL`,
`EURO_OFFICE_INTERNAL_URL`, `NEXTCLOUD_PUBLIC_URL`) and restarts
`nextcloud-configure-eurooffice` to apply them.

An Admin Panel is also enabled on the document server (`/admin/`, server
monitoring/configuration only) — document editing via Nextcloud does not require it.

## Verification

    test-module.sh euro-office

| Check | Expected |
|-------|----------|
| SSH to the VM | Connection succeeds |
| `podman-euro-office.service` | Active; euro-office container `Up` |
| `http://localhost/` on the VM | HTTP 200 |
| `/healthcheck` | HTTP 200 (connector availability check) |
| `/web-apps/apps/api/documents/api.js` | HTTP 200 (editor API) |
| `/etc/secrets/euro-office.env` | Exists, mode 0600, `JWT_SECRET` non-empty |
| No in-VM backup | no `euro-office-backup` timer, no `/var/backup/euro-office` (Proxmox Backup takes the VM) |
| `/var/lib/euro-office/data` | Exists |
| Nextcloud -> Administration -> "Nextcloud Office" | Points at this server; opening a `.docx` works |
| Connector check, from the Nextcloud VM (needs a TTY) | `ssh -t tappaas@nextcloud.<zone>.internal "sudo nextcloud-occ --no-ansi eurooffice:documentserver --check"` prints "is successfully connected" |

## Troubleshooting

**`install-module.sh` exits with a dependency error**
`nextcloud` is not installed or not reachable. Install it first, then retry.

**Document server was just (re)started and checks fail**
Give it roughly 20-40 seconds — it does not answer `/healthcheck` immediately after
`podman-euro-office` (re)starts.

**Nextcloud shows a "public test server" banner**
The "Nextcloud Office" settings page (app `eurooffice`) defaults to the public demo
server — the connector was not wired. Set it to euro-office. The 5 settings (also
settable via `nextcloud-occ config:app:set eurooffice <key>`):

| Key | Value |
|-----|-------|
| `DocumentServerUrl` | `https://<euro-office public domain>/` |
| `DocumentServerInternalUrl` | `http://euro-office.<zone>.internal/` |
| `StorageUrl` | `https://<nextcloud public domain>/` |
| `jwt_secret` | the value of `JWT_SECRET` in euro-office's `/etc/secrets/euro-office.env` |
| `jwt_header` | `Authorization` |

**Check whether Nextcloud sees the document server**
Run on the Nextcloud VM (needs a TTY):

    ssh -t tappaas@nextcloud.<zone>.internal "sudo nextcloud-occ --no-ansi eurooffice:documentserver --check"

- "is successfully connected" — working.
- "Error connection: ..." — broken; the error is shown.
- "Document server is not configured" — connector not wired; see the settings above.

**Container not running**

    ssh tappaas@euro-office.srv.internal \
      "sudo podman ps; sudo journalctl -u podman-euro-office -n 30"

**Logs** (inside the container)

    CID=$(ssh tappaas@euro-office.srv.internal "sudo podman ps -q")
    # DocService:  /var/log/euro-office/documentserver/docservice/out.log
    # Converter:   /var/log/euro-office/documentserver/converter/out.log
    # Nginx:       /var/log/euro-office/documentserver/nginx.error.log
    ssh tappaas@euro-office.srv.internal \
      "sudo podman exec $CID tail -100 /var/log/euro-office/documentserver/docservice/out.log"

**"Document cannot be accessed right now"**
A stale edit session blocks the file. Clear it (replace `KEY` with the document key):

    CID=$(ssh tappaas@euro-office.srv.internal "sudo podman ps -q")
    ssh tappaas@euro-office.srv.internal "sudo podman exec $CID su -s /bin/sh postgres \
      -c \"psql -d eurooffice -c \\\"DELETE FROM task_result WHERE id LIKE 'KEY%'\\\"\""

**Rotate the JWT secret** (only if compromised)
Regenerate it on the VM and restart the document server, then re-wire Nextcloud:

    ssh tappaas@euro-office.srv.internal \
      "echo JWT_SECRET=\$(openssl rand -hex 32) | sudo tee /etc/secrets/euro-office.env && \
       sudo systemctl restart podman-euro-office"
    update-module.sh euro-office   # Nextcloud re-reads the secret and re-applies the connector
