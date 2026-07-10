# LiteLLM

Primary audience: TAPPaaS admin and users of AI models (via apps or the API).

Unified AI API gateway — routes requests to multiple LLM providers with usage
tracking, caching, and access control.

## What you get

| Capability | Access from | How |
|------------|-------------|-----|
| Unified LLM API | Any internal zone (via pinhole) | OpenAI-compatible endpoint on port 4000 |
| Web UI | Internal network | `http://litellm.srvWork.internal:4000/ui` |
| Usage tracking | Admin UI | Per-key request counts, cost, latency |
| Response caching | Automatic | Redis-backed; reduces provider API costs |
| Virtual API keys | Admin UI | Scope per user or application |
| Model service for modules | `litellm:models` consumers | Virtual key auto-provisioned at install |

## What is not included

- Provider API keys (added via UI post-install — see INSTALL.md)
- Model selection (configured in UI after install)
- External access — internal zones only; expose via dmz if needed

## Requirements

- `srvWork` zone (VLAN 220)
- NixOS template (`templates:nixos`)
- 4 vCPU, 4 GB RAM, 32 GB disk by default (sizing guidance in DESIGN.md)

## Dependencies

| Depends on | Purpose |
|------------|---------|
| `cluster:vm` | VM provisioning |
| `templates:nixos` | NixOS base image |
| `backup:vm` | Daily backups |
| `identity:identity` | Secrets management |
| `network:proxy` | HTTPS reverse proxy |
| `network:rules` | Internal firewall pinholes |
| `vllm-amd:inference` | Local LLM inference backend |

For installation steps see [INSTALL.md](./INSTALL.md).
