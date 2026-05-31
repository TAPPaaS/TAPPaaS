# OpenWebUI — Admin Guide

**Maintainer:** @ErikDaniel007 | **Updated:** 2026-05-29

## Quick reference

| Item | Value |
|---|---|
| VM | `openwebui` (VMID 311) on tappaas2 |
| Zone | srv_work (10.2.20.0/24, VLAN 220) |
| Internal host | `openwebui.srv_work.internal` |
| Port | 8080 |
| Proxy | see `openwebui.json proxyDomain` |

---

## Operations

### Health check
```bash
cd /home/tappaas/TAPPaaS/src/apps/openwebui && ./test.sh openwebui
```
Checks (in order): SSH, container running, HTTP :8080, PostgreSQL, Redis.

### Update
```bash
update-module.sh openwebui
```
Handles: nixos-rebuild, container image update, health check, image prune.

### Reinstall
```bash
install-module.sh openwebui --force
```

---

## Troubleshooting — Infrastructure

Work through in order. Stop at first failure.

### 1. VM not reachable
```bash
ssh tappaas@openwebui.srv_work.internal
```
If unreachable: verify VM is running in Proxmox (`qm status 311` on tappaas2).

### 2. Container not running
```bash
ssh tappaas@openwebui.srv_work.internal
sudo podman ps
sudo journalctl -u openwebui-wrapper -n 50
```
Common causes: DNS failure during first image pull; secrets not generated yet.

### 3. PostgreSQL not responding
```bash
ssh tappaas@openwebui.srv_work.internal
systemctl status postgresql
pg_isready -h 127.0.0.1 -p 5432 -U openwebui -d openwebui
```

### 4. Redis not responding
```bash
ssh tappaas@openwebui.srv_work.internal
systemctl status redis-openwebui
redis-cli -h 127.0.0.1 -p 6379 ping    # expect: PONG
```

### 5. HTTP not responding on port 8080
```bash
ssh tappaas@openwebui.srv_work.internal
curl -v http://localhost:8080/
sudo podman logs openwebui --tail 50
```

---

## Troubleshooting — Application

Issues with the OpenWebUI application itself after infrastructure is confirmed healthy.

### Models not available in chat
1. Verify LiteLLM is running: `nc -zv -w 5 litellm.srv_work.internal 4000`
2. In OpenWebUI: Settings → Connections → confirm OpenAI API base URL and key
3. In LiteLLM UI: verify at least one model is configured and provider key is set
4. Check the connection: Settings → Connections → click the refresh/test icon

### LiteLLM connection failing ("connection refused")
Firewall pinhole may be missing. Run from tappaas-cicd:
```bash
rules-manager verify-rules openwebui --no-ssl-verify
```
If rules missing: `install-module.sh openwebui --force` to re-apply.

### Chat history missing after reinstall
Restore from backup — see [RESTORE.md](./RESTORE.md).
Automated backups run daily; check `/var/backup/openwebui-data/` for available restore points.

### User cannot log in
Check if SSO (identity:identity) is configured and Authentik is reachable.
For local accounts: admin can reset password via Settings → Admin → Users.

### Response streaming not working
Verify Redis is running (step 4 above). Redis handles WebSocket session state.

---

## Maintenance

### View logs
```bash
ssh tappaas@openwebui.srv_work.internal
sudo podman logs -f openwebui
sudo journalctl -u postgresql
```

### Manual backup
```bash
ssh tappaas@openwebui.srv_work.internal
sudo -u postgres pg_dump openwebui > openwebui-$(date +%Y%m%d).sql
```
Automated backups: `/var/backup/openwebui-*/` — 30-day retention.
