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
|------------|---------|
| `cluster:vm` | VM provisioning |
| `templates:nixos` | NixOS base image |
| `backup:vm` | Daily backups |
| `identity:identity` | Secrets management |
| `network:proxy` | HTTPS reverse proxy |
| `network:rules` | Internal firewall pinholes |

**No hard dependency on an inference backend — deliberately.** LiteLLM is
backend-agnostic: install whichever local backend matches your hardware —
`vllm-amd` (AMD unified-memory APUs), `ollama-nvidia` (any NVIDIA GPU), both
(LiteLLM fronts them all and routes by model name), or none (cloud providers
only) — then register its URL as a provider in the AI Hub UI
(e.g. `http://vllm-amd.srvWork.internal:8000` or
`http://ollama-nvidia.srvWork.internal:11434`). A hard `dependsOn` on one
specific backend would block installation on clusters without that vendor's
hardware. Caveat: if you deploy LiteLLM in a *different zone* than a backend,
add `<backend>:inference` to `dependsOn` (via the `/home/tappaas/config`
override) so rules-manager opens the cross-zone pinhole — in the default
same-zone (`srvWork`) layout no pinhole is needed.

For installation steps see [INSTALL.md](./INSTALL.md).
