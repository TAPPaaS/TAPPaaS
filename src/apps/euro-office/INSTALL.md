# euro-office — Installation

Only manual steps are listed here. Scripts handle everything else automatically (VM creation, NixOS rebuild, container pull, JWT generation, and wiring into Nextcloud).

## Prerequisites

- `nextcloud` is installed and reachable (`nextcloud:fileservice` dependency) — install it **before** euro-office.
- Verify `euro-office.json` matches your environment (node, storage, zone). To override, copy it to `/home/tappaas/config/` and edit, or use the flags below.

## Install

```bash
install-module.sh euro-office
```

Duration: ~10–20 minutes on first run (NixOS rebuild + container pull ~1.5 GB).

## Customisation (optional)

Override any JSON field at install time:

```bash
install-module.sh euro-office --node tappaas2 --zone0 srvDev --vmid 399
```

| Flag | Default | Controls |
|---|---|---|
| `--node` | `tappaas1` | Proxmox node |
| `--zone0` | `srv` | Network zone (VLAN) |
| `--vmid` | `343` | Proxmox VM ID |
| `--memory` | `8192` | RAM in MB |

## Post-install

No manual steps for document editing. On first boot the VM auto-generates a JWT secret and the `nextcloud` module wires the connector automatically (it writes `/etc/secrets/onlyoffice.env` with `JWT_SECRET`, `EURO_OFFICE_URL`, `EURO_OFFICE_INTERNAL_URL`, `NEXTCLOUD_PUBLIC_URL`; `nextcloud-configure-eurooffice` applies them).

Confirm in Nextcloud → Administration → ONLYOFFICE that the document server points at **this** server, then open any `.docx` to test.

> **Gotcha:** the Nextcloud `onlyoffice` app defaults to the **public ONLYOFFICE demo server** ("public test server" banner). If you see that banner the connector was not wired — set it to euro-office. The 5 settings (also settable via `nextcloud-occ config:app:set onlyoffice <key>`):
> | key | value |
> |---|---|
> | `DocumentServerUrl` | `http://euro-office.<zone>.internal/` (or the public HTTPS domain once its cert is issued) |
> | `DocumentServerInternalUrl` | `http://euro-office.<zone>.internal/` |
> | `StorageUrl` | `http://nextcloud.<zone>.internal/` |
> | `jwt_secret` | the value of `JWT_SECRET` in euro-office's `/etc/secrets/euro-office.env` |
> | `jwt_header` | `Authorization` |
>
> Browser editing needs the `DocumentServerUrl` reachable from the client without mixed content: use the internal `http://` URL when accessing Nextcloud over internal `http`, or a valid-cert `https://` domain when accessing Nextcloud over `https`.

### Admin Panel (optional, on-demand)

The server's Admin Panel (`/admin`) needs a one-time **bootstrap code** to create the admin account. The code is logged inside the container and is valid only until the **top of the next hour** — fetch a fresh one when you need it (it is NOT auto-provisioned, by design):

```bash
ssh tappaas@euro-office.<zone>.internal
CID=$(sudo podman ps -q)
# Restart the admin panel to emit a fresh code, then read it:
sudo podman exec "$CID" supervisorctl restart adminpanel
sudo podman exec "$CID" grep -i 'Bootstrap code' \
  /var/log/euro-office/documentserver/adminpanel/out.log | tail -1
# → "Bootstrap code: XXXXXXXX | Expires: ... | Open: http://host/admin"
```

Open `https://euro-office.<domain>/admin`, enter the code, and set an admin password. The Admin Panel is for server monitoring/config only — document editing via Nextcloud does not require it.

## Verification

```bash
./test.sh euro-office
```

Passing output:
```
PASS: SSH connectivity
PASS: euro-office container running
PASS: HTTP health (200)
PASS: /healthcheck (200)            # connector availability check
PASS: editor API api.js (200)
PASS: JWT secret present
```

## Backup and restore

Documents are backed up automatically — daily at 02:00 (stop → tar → restart), stored at `/var/backup/euro-office/` on the VM, 30-day retention. To restore, stop the container, extract the archive over `/var/lib/euro-office/data`, and restart:

```bash
ssh tappaas@euro-office.srv.internal "sudo systemctl stop podman-euro-office && \
  sudo tar xzf /var/backup/euro-office/<archive>.tar.gz -C /var/lib/euro-office && \
  sudo systemctl start podman-euro-office"
```

## Upgrading

The container image is pinned in `euro-office.nix`. To move to a newer DocumentServer release, bump the semver tag (check the [releases](https://github.com/Euro-Office/DocumentServer/releases)) and run:

```bash
update-module.sh euro-office
```

Verify document editing still works afterwards — re-test PDF rendering specifically (see Known limitations).

## Troubleshooting

**`install-module.sh` exits with a dependency error**
`nextcloud` is not installed or not reachable. Install it first, then retry.

**Container not running**
```bash
ssh tappaas@euro-office.srv.internal "sudo podman ps; sudo journalctl -u podman-euro-office -n 30"
```

**Logs** (inside the container)
```bash
CID=$(ssh tappaas@euro-office.srv.internal "sudo podman ps -q")
# DocService:  /var/log/onlyoffice/documentserver/docservice/out.log
# Converter:   /var/log/onlyoffice/documentserver/converter/err.log
# Nginx:       /var/log/onlyoffice/documentserver/nginx.error.log
ssh tappaas@euro-office.srv.internal "sudo podman exec $CID tail -100 /var/log/onlyoffice/documentserver/docservice/out.log"
```

**"Document cannot be accessed right now"** — a stale edit session blocks the file. Clear it (replace `KEY` with the document key):
```bash
CID=$(ssh tappaas@euro-office.srv.internal "sudo podman ps -q")
ssh tappaas@euro-office.srv.internal "sudo podman exec $CID su -s /bin/sh postgres -c \"psql -d onlyoffice -c \\\"DELETE FROM task_result WHERE id LIKE 'KEY%'\\\"\""
```

**Rotate the JWT secret** (only if compromised) — regenerate on the VM, restart, then sync to Nextcloud:
```bash
ssh tappaas@euro-office.srv.internal \
  "echo JWT_SECRET=\$(openssl rand -hex 32) | sudo tee /etc/secrets/euro-office.env && \
   sudo systemctl restart podman-euro-office"
./update-jwt.sh        # pushes the new secret + connector URLs into Nextcloud
```

## Known limitations

- **PDF rendering** crashed on the old `nightly` build (`9.2.1`, `Aborted()` in `drawingfile.wasm`). The module is now pinned to stable `v9.3.1`; re-test PDF before relying on it. `.docx`/`.xlsx`/`.pptx` are unaffected.
- **`/hosting/discovery` returns 404** — expected and harmless. It is a WOPI endpoint OnlyOffice does not serve; the connector checks `/healthcheck` + `/coauthoring/CommandService.ashx`.
