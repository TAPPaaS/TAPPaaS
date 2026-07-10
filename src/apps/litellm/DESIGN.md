# LiteLLM — Design notes

Implementation and operations detail that does not belong in the service-catalog
README or the install guide.

## Architecture

```
Clients → LiteLLM :4000 → LLM Providers (vllm-amd, OpenRouter, Anthropic, …)
                        → PostgreSQL  (model config, usage, keys)
                        → Redis       (response cache)
```

- LiteLLM runs as a Podman container (`podman-litellm`) with host networking.
- PostgreSQL 17 and Redis 7 run natively on the NixOS VM, localhost-only.
- Redis uses AOF persistence (`appendonly` + `appendfsync everysec`).
- The master key is auto-generated on first boot (`generate-litellm-secrets`)
  and stored in `/etc/secrets/litellm.env`. Provider keys are stored in the
  database via the UI/API, not in the env file.
- VM firewall opens ports 22 (SSH) and 4000 (LiteLLM API) only.

## Sizing

| Users | vCPU | RAM |
|-------|------|-----|
| ≤100 | 4 | 4 GB |
| ≤250 | 6 | 8 GB |
| 500+ | 8 | 16 GB |

## `litellm:models` service

`services/models/` implements the `models` capability listed in `provides`.
When a consuming module declares `dependsOn: ["litellm:models"]`,
`install-module.sh` calls `services/models/install-service.sh`, which:

- provisions a permanent virtual key (VK) in LiteLLM for the consumer
  (idempotent — an existing VK for the consumer alias is reused);
- writes the key and base URL to `/etc/secrets/litellm-svckey.env` on the
  consumer VM;
- persists the generated key on the litellm VM at
  `/etc/secrets/litellm-svc-<consumer>.key` so it can be recovered on re-runs.

`services/models/pinhole.json` declares port 4000/TCP so rules-manager can
synthesise a cross-zone ingress pinhole for consumers in other zones.

## Provider key rotation

`scripts/rotate-provider-key.sh` orchestrates the 3-step rotation SOP for a
provider key stored in `/etc/secrets/litellm.env` (e.g. `OPENROUTER_API_KEY`):
update the env file and restart, PATCH the DB credential, then verify all
DB-stored models carry an explicit `api_key`. See the script header for usage.

## Backup and restore

Daily automated backups (30-day retention, monthly cleanup timer):

| Component | Time | Location |
|-----------|------|----------|
| PostgreSQL dump | 02:00 | `/var/backup/postgresql/` |
| Redis snapshot | 02:30 | `/var/backup/redis/` |
| Secrets | 02:45 | `/var/backup/litellm-env/` |

Manual restore of the database:

    # PostgreSQL
    sudo systemctl stop podman-litellm
    gunzip -c /var/backup/postgresql/litellm-YYYY-MM-DD.sql.gz | sudo -u postgres psql litellm
    sudo systemctl start podman-litellm

## Upgrades

Version-specific upgrade notes (data migration, what survives an upgrade) are
in [UPGRADE.md](./UPGRADE.md).
