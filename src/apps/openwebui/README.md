# OpenWebUI

Primary audience: home and work users who want a private AI chat interface.

AI chat interface — multi-model conversations with persistent history, user
management, and RAG support.

## What you get

| Capability | Access from | How |
|------------|-------------|-----|
| AI chat (all configured models) | `home` zone | `http://openwebui.srvWork.internal:8080` |
| Model switching | Chat UI | Select any model configured in LiteLLM |
| Chat history | All sessions | PostgreSQL — survives restarts |
| User accounts | Admin UI | Per-user API keys and usage limits |
| RAG (document search) | Chat UI | Upload docs, search in conversation |

## What is not included

- LLM providers — configured in LiteLLM, not here
- Voice input — browser-dependent; no server-side STT
- Internet access for the AI — models run via LiteLLM internally

## Requirements

- `srvWork` zone (VLAN 220)
- LiteLLM deployed and accessible (`litellm:models` dependency)
- NixOS template (`templates:nixos`)
- 2 vCPU, 4 GB RAM, 32 GB disk by default

## Dependencies

| Depends on | Purpose |
|------------|---------|
| `cluster:vm` | VM provisioning |
| `templates:nixos` | NixOS base image |
| `backup:vm` | Daily backups (PostgreSQL, Redis, container data) |
| `network:proxy` | HTTPS reverse proxy (allowed from `home` zone) |
| `litellm:models` | LLM model routing and virtual key provisioning |
| `network:rules` | Internal firewall pinholes |

For installation steps see [INSTALL.md](./INSTALL.md).
