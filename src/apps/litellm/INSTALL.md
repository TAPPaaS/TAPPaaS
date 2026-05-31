# LiteLLM — Installation

Only manual steps are listed here. Scripts handle everything else automatically.

## Prerequisites

Verify `litellm.json` matches your environment (node, storage, zone).
To use non-default values, override at install time — see §Customisation below.

## Install

```bash
cd /home/tappaas/TAPPaaS/src/apps/litellm
install-module.sh litellm
```

Duration: ~5–10 minutes on first run.

## Customisation (optional)

Override any JSON field at install time without editing files:

```bash
install-module.sh litellm --node tappaas1 --zone0 srv_dev --vmid 399
```

| Flag | Default | Controls |
|---|---|---|
| `--zone0` | `srv_work` | Network zone (VLAN) |
| `--vmid` | `310` | Proxmox VM ID |
| `--node` | `tappaas2` | Proxmox node |
| `--memory` | `4096` | RAM in MB |
| `--variant staging` | — | Named variant config (`litellm-staging.json`) |

## Post-install

**1. Get the master key**

```bash
ssh tappaas@litellm.srv_work.internal "sudo cat /etc/secrets/litellm.env"
```

Save this key in your password manager — it is the admin password for the UI and API.

**2. Open the UI and configure**

`http://litellm.srv_work.internal:4000/ui` — log in with the master key.

1. Settings → Credentials — add API keys (OpenRouter, Anthropic, Perplexity, …)
2. AI Hub — add models
3. Virtual Keys — create per-user or per-application keys

Reference: [LiteLLM proxy docs](https://docs.litellm.ai/docs/proxy/ui_credentials)

## Verification

```bash
cd /home/tappaas/TAPPaaS/src/apps/litellm
./test.sh
```

All 10 tests should pass. Passing output:
```
[PASS] postgresql is active
[PASS] redis-litellm is active
[PASS] podman-litellm is active
[PASS] API health check passed
[PASS] PostgreSQL is responding
[PASS] LiteLLM database has N tables
[PASS] Redis is responding (PONG)
[PASS] API authentication successful
[PASS] All backup directories exist
[PASS] N backup timer(s) scheduled
```

## Troubleshooting

**Container not starting**
```bash
ssh tappaas@litellm.srv_work.internal "journalctl -u podman-litellm -n 50"
```
Common cause: API key not yet configured — add at least one provider credential via UI first.

**Cannot connect to UI after install**
Verify firewall proxy is active: `rules-manager verify-rules litellm --no-ssl-verify`
Check VM is reachable: `nc -zv -w 5 litellm.srv_work.internal 4000`

**Master key lost**
```bash
ssh tappaas@litellm.srv_work.internal
sudo rm /etc/secrets/litellm.env
sudo systemctl restart generate-litellm-secrets podman-litellm
# New key generated — retrieve again with sudo cat
```
Warning: existing virtual keys remain valid; only the master key changes.

**Database not responding**
```bash
ssh tappaas@litellm.srv_work.internal "systemctl status postgresql"
ssh tappaas@litellm.srv_work.internal "sudo -u postgres psql -c '\l'"
```

## Backup and restore

Daily automated backups run at:

| Component | Time | Location |
|---|---|---|
| PostgreSQL dump | 02:00 | `/var/backup/postgresql/` |
| Redis snapshot | 02:30 | `/var/backup/redis/` |
| Secrets | 02:45 | `/var/backup/litellm-env/` |

Retention: 30 days.

**Manual restore:**
```bash
# PostgreSQL
sudo systemctl stop podman-litellm
gunzip -c /var/backup/postgresql/litellm-YYYY-MM-DD.sql.gz | sudo -u postgres psql litellm
sudo systemctl start podman-litellm
```
