# TAPPaaS LiteLLM

Unified AI API gateway — routes requests to multiple LLM providers with usage tracking, caching, and access control.

## What you get

| Capability | Access from | How |
|---|---|---|
| Unified LLM API | Any internal zone | OpenAI-compatible endpoint on port 4000 |
| Web UI | Internal network | `http://litellm.srvwork.internal:4000/ui` |
| Usage tracking | Admin UI | Per-key request counts, cost, latency |
| Response caching | Automatic | Redis-backed; reduces provider API costs |
| Virtual API keys | Admin UI | Scope per user or application |

## Architecture

```
Clients → LiteLLM :4000 → LLM Providers (OpenRouter, Anthropic, …)
                        → PostgreSQL  (model config, usage, keys)
                        → Redis       (response cache)
```

## What is not included

- Provider API keys (added via UI post-install — see INSTALL.md)
- Model selection (configured in UI after install)
- External access — internal zones only; expose via dmz if needed

## Requirements

- `srvwork` zone (VLAN 220)
- NixOS template (`templates:nixos`)
- 4 vCPU, 4GB RAM minimum (see sizing below)

## Sizing

| Users | vCPU | RAM |
|---|---|---|
| ≤100 | 4 | 4 GB |
| ≤250 | 6 | 8 GB |
| 500+ | 8 | 16 GB |

## Operations

Provider credentials (OpenRouter, Perplexity, Abacus, etc.) are managed as
named, referenceable objects — models point at a credential by name rather
than embedding the key, so rotating a key updates every model that uses it
in one step.

| Task | Command |
|---|---|
| See models, credentials, virtual keys, teams (no secrets shown) | `scripts/litellm-credentials.sh inspect` |
| Register a new provider credential | `scripts/litellm-credentials.sh add --name <name> --provider <provider>` |
| Rotate an existing credential's value | `scripts/litellm-credentials.sh rotate --name <name>` |
| Wire a model to a credential | `scripts/litellm-credentials.sh assign-model --model <model> --credential <name>` |
| Full end-to-end key rotation (env file + credential + restart) | `scripts/rotate-provider-key.sh --vmname <vmname>` |

## Dependencies

| Depends on | Purpose |
|---|---|
| `cluster:vm` | VM provisioning |
| `templates:nixos` | NixOS base image |
| `backup:vm` | Daily backups |
| `identity:identity` | Secrets management |
| `firewall:proxy` | HTTPS reverse proxy |
| `firewall:rules` | Internal firewall pinholes |

For installation steps see [INSTALL.md](./INSTALL.md).
Upgrading? See [UPGRADE.md](./UPGRADE.md).
