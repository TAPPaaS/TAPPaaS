```
# Copyright (c) 2025 TAPPaaS org
#
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.
#
# This file incorporates work covered by the following copyright and permission notice:
# Copyright (c) 2021-2025 community-scripts ORG
# License: MIT | https://github.com/community-scripts/ProxmoxVE/raw/main/LICENSE
```

```markdown
# LiteLLM on TAPPaaS - Installation Guide

**Version:** 0.9.0  
**Author:** Erik Daniel
**Release Date:** 2026-02-10 
**Status:** Development

Step-by-step deployment instructions for TAPPaaS LiteLLM

## Prerequisites

- NixOS 25.05 installed
- Root/sudo access
- Network connectivity
- Proxmox VM or bare metal (recommended: 4 vCPU / 8GB RAM / 40GB SSD)

## Installation Steps

### 1. Confirm LiteLLM Configuration

read the ./readme.md for sizing guidelines
look at ./litellm.json. 
If this file is not correctly reflecting how you want this module to be installed in your environments. For instance if:
- you want to have the module to run on a different node than the default "tappaass1" 
- you want the VM to e on a different storage node than "tanka1"
- you want to make it a member of a different LAN zone (VLAN)
Then copy the json to /home/tappaas/config and edit the file to reflect your choices

### 2. Deploy LiteLLM Configuration


As tappaas use on the tappaas-cicd: run the command:
```
cd TAPPaaS/src/apps/litellm
./install.sh litellm
```

```
# Expected output:
# building the system configuration...
# activating the configuration...
# setting up /etc...
# reloading the following units: dbus.service
# starting the following units: generate-litellm-secrets.service, ...
```

**Duration:** ~5-10 minutes (first run downloads PostgreSQL, Redis, Podman images)

### 4. Retrieve Master Key

```bash
# View in journal
sudo journalctl -u generate-litellm-secrets.service | grep "sk-"

# OR read from file
sudo cat /etc/secrets/litellm.env | grep LITELLM_MASTER_KEY

# Example output:
# LITELLM_MASTER_KEY=sk-a3f8b2c1d4e...c7d8e9f0a1
```

**⚠️ CRITICAL:** Save this key in your password manager. You'll need it for API access.


Go to - [http://http://litellm.srv.internal:4000/ui] (http://litellm.srv.internal:4000/ui)
username = admin
Password = sk-a3f8b2c1d4e...c7d8e9f0a1


Follow the quick start: 
1) setup (admin) users - https://docs.litellm.ai/docs/proxy/ui
2) add a model provider API key - https://docs.litellm.ai/docs/proxy/ui_credentials 
3) select models from provider to make public to internal users https://docs.litellm.ai/docs/proxy/ai_hub 
4) test is models work - https://docs.litellm.ai/docs/proxy/model_compare_ui
5) create a virtual key - https://docs.litellm.ai/docs/proxy/access_control
6) use this virtual key in your AI apps (e.g. TAPPaaS Open WebUI)

## Verification Tests

### Test 1: Service Health

```bash
# Check all services running
systemctl status postgresql redis-litellm podman-litellm

# Expected: All show "active (running)" in green
```

**Troubleshooting:**
```bash
# If any service failed
sudo journalctl -u <service-name> -n 50

# Common fixes:
sudo systemctl restart postgresql
sudo systemctl restart redis-litellm
sudo systemctl restart podman-litellm
```

### Test 2: API Health Check

```bash
# Test API endpoint
curl http://localhost:4000/health

# Expected output:
# "LiteLLM is healthy"
```

**Troubleshooting:**
```bash
# If connection refused
sudo systemctl status podman-litellm
sudo journalctl -u podman-litellm -n 100

# Check if port is listening
sudo ss -tlnp | grep 4000
```

### Test 3: Database Connectivity

```bash
# Test PostgreSQL
sudo -u postgres psql -c "SELECT version();"

# Test LiteLLM database
sudo -u postgres psql litellm -c "\dt"

# Expected: List of LiteLLM tables (LiteLLM_VerificationToken, etc.)
```

### Test 4: Redis Connectivity

```bash
# Test Redis
redis-cli PING

# Expected output:
# PONG

# Check cache status
redis-cli INFO stats | grep keyspace
```

### Test 5: API Authentication

```bash
# Set master key (from step 4)
export LITELLM_MASTER_KEY="sk-..."

# Test authenticated request
curl -X GET http://localhost:4000/key/info \
  -H "Authorization: Bearer $LITELLM_MASTER_KEY"

# Expected: JSON response with key info
```

### Test 6: Model Management

```bash
# List models (should be empty initially)
curl -X GET http://localhost:4000/model/info \
  -H "Authorization: Bearer $LITELLM_MASTER_KEY"

# Add a test model (requires provider API key)
curl -X POST http://localhost:4000/model/new \
  -H "Authorization: Bearer $LITELLM_MASTER_KEY" \
  -H "Content-Type: application/json" \
  -d '{
    "model_name": "gpt-3.5-turbo",
    "litellm_params": {
      "model": "openai/gpt-3.5-turbo",
      "api_key": "os.environ/OPENAI_API_KEY"
    }
  }'

# Verify model added
curl -X GET http://localhost:4000/model/info \
  -H "Authorization: Bearer $LITELLM_MASTER_KEY"
```

### Test 7: Complete Request Flow

```bash
# Test chat completion (requires model configured)
curl -X POST http://localhost:4000/chat/completions \
  -H "Authorization: Bearer $LITELLM_MASTER_KEY" \
  -H "Content-Type: application/json" \
  -d '{
    "model": "gpt-3.5-turbo",
    "messages": [{"role": "user", "content": "Hello!"}]
  }'

# Expected: JSON response with completion
```

### Test 8: Backup System

```bash
# Check backup directories exist
ls -lh /var/backup/

# Expected directories:
# postgresql/
# redis/
# litellm-env/

# Verify backup timers scheduled
systemctl list-timers | grep backup

# Expected: Three backup timers scheduled
```

### Test 9: Log Accessibility

```bash
# View LiteLLM logs
sudo journalctl -u podman-litellm --since today

# View PostgreSQL logs
sudo journalctl -u postgresql --since today

# View Redis logs
sudo journalctl -u redis-litellm --since today

# Follow live logs
sudo journalctl -u podman-litellm -f
```

### Test 10: Resource Usage

```bash
# Check memory usage
free -h

# Check disk usage
df -h

# Check container stats
podman stats --no-stream litellm

# Check PostgreSQL connections
sudo -u postgres psql -c "SELECT count(*) FROM pg_stat_activity;"

# Expected: < 10 connections (idle system)
```

## Post-Installation

**⚠️ Security:** Only expose externally behind a reverse proxy (Caddy/Nginx) with TLS.

### API Key Management

```bash
# Generate new API keys for users
curl -X POST http://localhost:4000/key/generate \
  -H "Authorization: Bearer $LITELLM_MASTER_KEY" \
  -H "Content-Type: application/json" \
  -d '{
    "models": ["gpt-3.5-turbo"],
    "max_budget": 10.0,
    "user_id": "user@example.com"
  }'

# Save returned key for user
```

### Enable Monitoring (Optional)

```bash
# View metrics endpoint
curl http://localhost:4000/metrics

# Integrate with Prometheus/Grafana for production monitoring
```

## Validation Checklist

- [ ] All services running (`systemctl status`)
- [ ] API health check passes (`/health`)
- [ ] Master key retrieved and saved
- [ ] PostgreSQL accessible
- [ ] Redis responding
- [ ] API authentication works
- [ ] Backup directories created
- [ ] Backup timers scheduled
- [ ] Logs accessible
- [ ] Resource usage normal

## Common Issues

### Issue: Container fails to start

```bash
# Check secrets file exists
sudo ls -la /etc/secrets/litellm.env

# If missing, regenerate
sudo rm /etc/secrets/litellm.env
sudo systemctl restart generate-litellm-secrets.service
sudo systemctl restart podman-litellm
```

### Issue: PostgreSQL connection refused

```bash
# Verify PostgreSQL running
sudo systemctl status postgresql

# Check socket
sudo ls -la /run/postgresql/

# Restart if needed
sudo systemctl restart postgresql
sudo systemctl restart podman-litellm
```

### Issue: High memory usage immediately

```bash
# Normal: PostgreSQL preallocates shared_buffers (2GB)
# Check if swapping occurs
free -h
vmstat 1 10

# If swapping heavily, reduce shared_buffers in configuration.nix
```

### Issue: Cannot pull container image

```bash
# Check network
ping -c 3 ghcr.io

# Manual pull
sudo podman pull ghcr.io/berriai/litellm:v1.81.3.rc.2

# Restart service
sudo systemctl restart podman-litellm
```

## Next Steps

1. **Configure Models:** Add your LLM provider models via API
2. **Create API Keys:** Generate keys for team members
3. **Setup Monitoring:** Configure alerting for production
4. **Schedule Backups:** Test backup restoration process
5. **Review Logs:** Monitor for any warnings/errors

## Support Resources

- LiteLLM Documentation: https://docs.litellm.ai/
- NixOS Manual: https://nixos.org/manual/nixos/stable/
- PostgreSQL Docs: https://www.postgresql.org/docs/15/
- Redis Documentation: https://redis.io/docs/

## Rollback

If you need to revert to previous configuration:

```bash
# Restore backup
sudo cp /root/nixos-backups/configuration.nix.backup-YYYY-MM-DD-HHMMSS \
  /etc/nixos/configuration.nix

# Apply
sudo nixos-rebuild switch
```

---

**Installation Complete!** 🎉

Your LiteLLM gateway is ready for production use.
```