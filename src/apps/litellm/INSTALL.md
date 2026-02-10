# LiteLLM on TAPPaaS - Installation Guide

Step-by-step deployment instructions for TAPPaaS LiteLLM

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
```bash
cd
cd TAPPaaS/src/apps/litellm
./install.sh litellm
```

**Duration:** ~5-10 minutes (first run downloads PostgreSQL, Redis, Podman images)

### 4. Retrieve Master Key

```bash
# View in journal
ssh tappaas@litellm.srv.internal "sudo journalctl -u generate-litellm-secrets.service | grep sk-"

# OR read from file (output easer to read)
ssh tappaas@litellm.srv.internal "sudo cat /etc/secrets/litellm.env | grep LITELLM_MASTER_KEY"

# Example output:
# LITELLM_MASTER_KEY=sk-a3f8b2c1d4e...c7d8e9f0a1
```

**⚠️ CRITICAL:** Save this key in your password manager. You'll need it for API access.


Go to - [litellm.srv.internal:4000/ui](http://litellm.srv.internal:4000/ui)
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

please run:
```bash
./test.sh
```

Verify that all test pass

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