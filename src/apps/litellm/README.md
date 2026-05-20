# TAPPaaS LiteLLM

Unified AI API gateway — routes requests to multiple LLM providers with usage tracking, caching, and access control.

See `litellm.json` for current version and VM configuration. Upgrading from an older version? See [UPGRADE.md](UPGRADE.md).

## Architecture

```
Clients → LiteLLM :4000 → PostgreSQL (models, usage, keys)
                        → Redis (response cache)
                        → LLM Providers (OpenRouter, Anthropic, ...)
```

## What the install does automatically

- Provisions VM, installs NixOS, starts PostgreSQL + Redis + LiteLLM container
- Generates a random master key on first boot (`/etc/secrets/litellm.env`)
- Configures daily backups: PostgreSQL dump (02:00), Redis snapshot (02:30), secrets (02:45)
- 30-day backup retention

## What an admin must do after install

### 1. Get the master key

```bash
ssh tappaas@<vmname>.<zone0>.internal "sudo cat /etc/secrets/litellm.env"
```

Save this key — it is the admin password for the UI and API.

### 2. Open the UI

`http://<vmname>.<zone0>.internal:4000/ui`

Login with the master key as password.

### 3. Add provider credentials

Settings → Credentials — add API keys for OpenRouter, Anthropic, Perplexity, etc.
No secrets file editing needed; credentials are stored in the database.

Reference: https://docs.litellm.ai/docs/proxy/ui_credentials

### 4. Add models and create user keys

- Add models: https://docs.litellm.ai/docs/proxy/ai_hub
- Create virtual keys for users: https://docs.litellm.ai/docs/proxy/access_control

## Sizing

| Users | vCPU | RAM  | Workers |
|-------|------|------|---------|
| ≤100  | 4    | 4GB  | 4       |
| ≤250  | 4-6  | 8GB  | 4       |
| 500+  | 8    | 16GB | 8       |

## Troubleshooting

```bash
# Service status
systemctl status postgresql redis-litellm podman-litellm

# Container logs
journalctl -u podman-litellm -f

# Restart container
systemctl restart podman-litellm

# Regenerate master key (only if lost — destroys existing key)
sudo rm /etc/secrets/litellm.env
sudo systemctl restart generate-litellm-secrets podman-litellm
```

## Backup / restore

```bash
# Manual PostgreSQL backup
sudo -u postgres pg_dump litellm | gzip > backup-$(date +%F).sql.gz

# Restore
sudo systemctl stop podman-litellm
gunzip -c backup.sql.gz | sudo -u postgres psql litellm
sudo systemctl start podman-litellm
```

## License

Mozilla Public License 2.0 (MPL-2.0)
