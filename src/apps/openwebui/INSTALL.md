# OpenWebUI — Installation

Only manual steps are listed here. Scripts handle everything else automatically.

## Prerequisites

Verify `openwebui.json` matches your environment (node, storage, zone).
LiteLLM must be deployed and accessible before installing OpenWebUI (`litellm:models` dependency).

## Install

```bash
cd /home/tappaas/TAPPaaS/src/apps/openwebui
install-module.sh openwebui
```

Duration: ~10–20 minutes on first run (NixOS rebuild + container pull ~1 GB).

## Customisation (optional)

Override any JSON field at install time:

```bash
install-module.sh openwebui --node tappaas1 --zone0 srv-dev --vmid 399
```

| Flag | Default | Controls |
|---|---|---|
| `--zone0` | `srv-work` | Network zone (VLAN) |
| `--vmid` | `311` | Proxmox VM ID |
| `--node` | `tappaas2` | Proxmox node |
| `--memory` | `4096` | RAM in MB |
| `--variant staging` | — | Named variant config |

## Post-install

**First login (one-time):**
1. Open `http://openwebui.srv-work.internal:8080`
2. Create admin account
3. Settings → Connections → OpenAI API:
   - Base URL: `http://litellm.srv-work.internal:4000/v1`
   - API Key: your LiteLLM virtual key
4. Test: start a conversation, select a model

## Verification

```bash
cd /home/tappaas/TAPPaaS/src/apps/openwebui
./test.sh openwebui
```

Passing output:
```
PASS: SSH connectivity
PASS: OpenWebUI container running
PASS: HTTP endpoint responding (200)
PASS: PostgreSQL accepting connections
PASS: Redis responding to PING
```

## Backup and restore

Daily automated backups run at:

| Component | Time | Location |
|---|---|---|
| PostgreSQL | 02:00 | `/var/backup/postgresql/` |
| Redis | 02:30 | `/var/backup/redis/` |
| Container data | 02:45 | `/var/backup/openwebui-data/` |
| Secrets | 02:50 | `/var/backup/openwebui-env/` |

Retention: 30 days. For restore procedures see [RESTORE.md](./RESTORE.md).

## Upgrading

See [UPGRADE.md](./UPGRADE.md).

## Troubleshooting — install-module failures

These checks cover deployment failures only.
For operational issues after a successful install see [ADMIN.md](./ADMIN.md).

**install-module.sh exits with dependency error**
A required service is not installed. Check which `dependsOn` entry is unmet:
```bash
rules-manager list-installed --no-ssl-verify
```
Install the missing module first, then retry.

**Container fails to start on first boot**
DNS or image pull failed during NixOS activation. Check from inside the VM:
```bash
ssh tappaas@openwebui.srv-work.internal "sudo journalctl -u openwebui-wrapper -n 30"
```
Common fix: wait 2–3 minutes for NixOS first-boot to complete, then run `./test.sh openwebui`.

**test.sh shows LiteLLM unreachable**
Firewall pinhole not applied. Re-run install:
```bash
install-module.sh openwebui --force
```
