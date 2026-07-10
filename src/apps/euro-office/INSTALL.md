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

Duration: ~10-20 minutes on first run (NixOS rebuild + container pull ~1.5 GB).

## Post-install

None for document editing. On first boot the VM auto-generates a JWT secret and the
`nextcloud` module wires the connector automatically (it writes
`/etc/secrets/onlyoffice.env` with `JWT_SECRET`, `EURO_OFFICE_URL`,
`EURO_OFFICE_INTERNAL_URL`, `NEXTCLOUD_PUBLIC_URL`; `nextcloud-configure-eurooffice`
applies them).

Optional — Admin Panel (`/admin`) bootstrap: the server's Admin Panel needs a one-time
bootstrap code to create the admin account. The code is logged inside the container and
is valid only until the top of the next hour — fetch a fresh one when you need it (it is
NOT auto-provisioned, by design):

    ssh tappaas@euro-office.<zone>.internal
    CID=$(sudo podman ps -q)
    # Restart the admin panel to emit a fresh code, then read it:
    sudo podman exec "$CID" supervisorctl restart adminpanel
    sudo podman exec "$CID" grep -i 'Bootstrap code' \
      /var/log/euro-office/documentserver/adminpanel/out.log | tail -1
    # -> "Bootstrap code: XXXXXXXX | Expires: ... | Open: http://host/admin"

Open `https://euro-office.<domain>/admin`, enter the code, and set an admin password.
The Admin Panel is for server monitoring/config only — document editing via Nextcloud
does not require it.

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
| `euro-office-backup.timer` | Active and scheduled |
| `/var/lib/euro-office/data` | Exists |
| Nextcloud -> Administration -> ONLYOFFICE | Points at this server; opening a `.docx` works |

## Troubleshooting

**`install-module.sh` exits with a dependency error**
`nextcloud` is not installed or not reachable. Install it first, then retry.

**Nextcloud shows a "public test server" banner**
The Nextcloud `onlyoffice` app defaults to the public ONLYOFFICE demo server — the
connector was not wired. Set it to euro-office. The 5 settings (also settable via
`nextcloud-occ config:app:set onlyoffice <key>`):

| Key | Value |
|-----|-------|
| `DocumentServerUrl` | `http://euro-office.<zone>.internal/` (or the public HTTPS domain) |
| `DocumentServerInternalUrl` | `http://euro-office.<zone>.internal/` |
| `StorageUrl` | `http://nextcloud.<zone>.internal/` |
| `jwt_secret` | the value of `JWT_SECRET` in euro-office's `/etc/secrets/euro-office.env` |
| `jwt_header` | `Authorization` |

Browser editing needs `DocumentServerUrl` reachable from the client without mixed
content: use the internal `http://` URL when accessing Nextcloud over internal `http`,
or a valid-cert `https://` domain when accessing Nextcloud over `https`.

**Container not running**

    ssh tappaas@euro-office.srv.internal \
      "sudo podman ps; sudo journalctl -u podman-euro-office -n 30"

**Logs** (inside the container)

    CID=$(ssh tappaas@euro-office.srv.internal "sudo podman ps -q")
    # DocService:  /var/log/onlyoffice/documentserver/docservice/out.log
    # Converter:   /var/log/onlyoffice/documentserver/converter/err.log
    # Nginx:       /var/log/onlyoffice/documentserver/nginx.error.log
    ssh tappaas@euro-office.srv.internal \
      "sudo podman exec $CID tail -100 /var/log/onlyoffice/documentserver/docservice/out.log"

**"Document cannot be accessed right now"**
A stale edit session blocks the file. Clear it (replace `KEY` with the document key):

    CID=$(ssh tappaas@euro-office.srv.internal "sudo podman ps -q")
    ssh tappaas@euro-office.srv.internal "sudo podman exec $CID su -s /bin/sh postgres \
      -c \"psql -d onlyoffice -c \\\"DELETE FROM task_result WHERE id LIKE 'KEY%'\\\"\""

**Rotate the JWT secret** (only if compromised)
Regenerate on the VM, restart, then sync to Nextcloud:

    ssh tappaas@euro-office.srv.internal \
      "echo JWT_SECRET=\$(openssl rand -hex 32) | sudo tee /etc/secrets/euro-office.env && \
       sudo systemctl restart podman-euro-office"
    ./update-jwt.sh        # pushes the new secret + connector URLs into Nextcloud

**`/hosting/discovery` returns 404**
Expected and harmless. It is a WOPI endpoint OnlyOffice does not serve; the connector
checks `/healthcheck` + `/coauthoring/CommandService.ashx`.

**PDF rendering**
Crashed on the old `nightly` build (`9.2.1`, `Aborted()` in `drawingfile.wasm`). The
module is pinned to stable `v9.3.1`; re-test PDF before relying on it.
`.docx`/`.xlsx`/`.pptx` are unaffected.
