# Forgejo — Installation

## Prerequisites

1. **NixOS template VM** — verify template VMID 8080 exists on the target node:
   ```bash
   ssh root@tappaas1.mgmt.internal "qm list | grep 8080"
   ```

2. **Storage pool** — verify `tanka1` is available:
   ```bash
   ssh root@tappaas1.mgmt.internal "pvesm status | grep tanka1"
   ```

3. **DNS** — `forgejo.srvWork.internal` resolves after install (handled by `network:rules`).
   Verify after install: `dig forgejo.srvWork.internal @<unbound-ip>`

## Install

```bash
cd "${TAPPAAS_REPO:-/home/tappaas/TAPPaaS}"/src/devops/forgejo
install-module.sh forgejo
```

`install-module.sh` handles:
- VM creation (clone from NixOS template 8080, VMID 350)
- NixOS configuration deployment via `templates:nixos` (`update-os.sh`, the release's pinned nixpkgs); `update.sh` only checks Forgejo answers
- Firewall rule registration (`network:rules`)
- Caddy reverse proxy entry (`network:proxy`) — HTTPS for `work` and `mgmt` zones

## Post-install

1. **Store the break-glass admin password** — `install.sh` creates the local admin
   `tappaas-admin` and prints its password **once**. It signs in on the local form at
   `https://forgejo.<domain>/user/login`; everyone else signs in with Authentik.

   **Make yourself a Forgejo admin**: add your Authentik user to the `forgejo-admins`
   group (`authentik-manager user-add-to-groups <user> forgejo-admins`), then sign in with
   Authentik. Lost the break-glass password: `sudo forgejo-admin admin user change-password
   --username tappaas-admin --password <new>` on the VM.

2. **Configure SMTP** (optional) — SSH into the VM and edit `/var/lib/forgejo/custom/conf/app.ini`:
   ```ini
   [mailer]
   ENABLED = true
   SMTP_ADDR = <your-smtp-host>
   SMTP_PORT = 587
   FROM = forgejo@<your-domain>
   USER = <smtp-user>
   PASSWD = <smtp-password>
   ```
   Restart: `sudo systemctl restart forgejo`

3. **SSH git access** — The VM listens on port 22. Users on the `work` VLAN can clone with:
   ```bash
   git clone git@forgejo.srvWork.internal:org/repo.git
   ```
   External SSH access requires an NAT port-forward rule — see §Customisation.

## Verification

```bash
bash test.sh forgejo
```

Passing output:
```
PASS: VM is running and SSH is reachable
PASS: Disk usage X% (< 85%)
PASS: Memory available: X MB
PASS: Forgejo systemd service is active
PASS: Web UI reachable on TCP 3000
PASS: Forgejo HTTP response: 200
PASS: Forgejo API /healthz: pass
PASS: SSH git port 22 reachable
PASS: Repository data directory exists
PASS: Backup timer (forgejo-backup.timer) is active
```

Manual check:

| Check | Expected |
|---|---|
| `nc -zv -w 5 forgejo.srvWork.internal 3000` | `Connection to … 3000 … succeeded` |
| Browser: `https://forgejo.<domain>` | Forgejo login page loads |
| `curl -s https://forgejo.<domain>/api/healthz` | `{"status":"pass"}` |

## Customisation (optional)

Override any JSON field at install time:

```bash
install-module.sh forgejo --node tappaas2 --zone0 srvWork --vmid 351
```

| Flag | Default | Controls |
|---|---|---|
| `--zone0` | `srvWork` | Network zone (VLAN 220) |
| `--vmid` | `350` | Proxmox VM ID |
| `--node` | `tappaas1` | Proxmox node |
| `--memory` | `2048` | RAM in MB |

### External SSH access (git over SSH from outside `work`)

Not shipped by default. The VM listens on port 22, but reaching it from outside the
`work` VLAN requires one of two decisions, and the module makes neither:

- declare an ingress pinhole from `dmz` to port 22, or
- add a host-level SSH-forwarding rule on an alternative external port (e.g. 2222).

Decide the external port first — both the rule and the clone URL depend on it.

## Troubleshooting

**"Forgejo service is inactive after install"**
The first NixOS rebuild downloads the Forgejo package from the internet (via `srvWork`
internet egress). This can take 3–5 minutes on first boot. Check progress:
```bash
ssh tappaas@forgejo.srvWork.internal "journalctl -u forgejo -f"
```

**"Web UI returns 502 from Caddy"**
Caddy can reach the VM but Forgejo is not yet listening on port 3000. Wait for the service
to start: `systemctl status forgejo`. If it fails, check: `journalctl -u forgejo --no-pager`.

**"SSH git: connection refused"**
The system OpenSSH listens on port 22. Verify it is running:
```bash
ssh tappaas@forgejo.srvWork.internal "systemctl status sshd"
```
If users are outside the `work` VLAN, add an NAT port-forward rule (see §Customisation).

**"No Sign in with Authentik button" / SSO login fails**
`journalctl -u forgejo-configure-oidc` on the VM says what it did. No button: there is no
OIDC client (`/etc/secrets/forgejo.env`) — the name is not published (no public DNS
record, #778), or identity:identity has not run; re-run `update-module.sh forgejo`. A
callback error: `ROOT_URL` in `/var/lib/forgejo/custom/conf/app.ini` must be
`https://forgejo.<domain>/` — it comes from `/etc/nixos/forgejo.json` at the rebuild.

For operational issues after a successful install, see [ADMIN.md](./ADMIN.md) if present.
