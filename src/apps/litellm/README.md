# TAPPaaS LiteLLM

Unified AI API gateway — routes requests to multiple LLM providers with usage tracking, caching, and access control.

## What you get

| Capability | Access from | How |
|---|---|---|
| Unified LLM API | Any internal zone | OpenAI-compatible endpoint on port 4000 |
| Web UI | Internal network | `http://litellm.srv_work.internal:4000/ui` |
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

- `srv_work` zone (VLAN 220)
- NixOS template (`templates:nixos`)
- 4 vCPU, 4GB RAM minimum (see sizing below)

## Sizing

| Users | vCPU | RAM |
|---|---|---|
| ≤100 | 4 | 4 GB |
| ≤250 | 6 | 8 GB |
| 500+ | 8 | 16 GB |

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
