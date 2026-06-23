# OpenWebUI

AI chat interface — multi-model conversations with persistent history, user management, and RAG support.

## What you get

| Capability | Access from | How |
|---|---|---|
| AI chat (all configured models) | Home network, work | `https://openwebui.srv_work.internal:8080` (internal) |
| Model switching | Chat UI | Select any model configured in LiteLLM |
| Chat history | All sessions | PostgreSQL — survives restarts |
| User accounts | Admin UI | Per-user API keys and usage limits |
| RAG (document search) | Chat UI | Upload docs, search in conversation |

## What is not included

- LLM providers — configured in LiteLLM, not here
- Voice input — browser-dependent; no server-side STT
- Internet access for the AI — models run via LiteLLM internally

## Requirements

- `srv_work` zone (VLAN 220)
- LiteLLM deployed and accessible (`litellm:models` dependency)
- NixOS template

## Dependencies

| Depends on | Purpose |
|---|---|
| `cluster:vm` | VM provisioning |
| `templates:nixos` | NixOS base image |
| `backup:vm` | Daily backups (PostgreSQL, Redis, container data) |
| `identity:identity` | Secrets management |
| `network:proxy` | HTTPS reverse proxy |
| `network:rules` | Internal firewall pinholes |
| `litellm:models` | LLM model routing |

For installation steps see [INSTALL.md](./INSTALL.md).
Upgrading? See [UPGRADE.md](./UPGRADE.md).
Restoring data? See [RESTORE.md](./RESTORE.md).
