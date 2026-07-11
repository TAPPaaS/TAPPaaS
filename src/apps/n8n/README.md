# n8n

Primary audience: TAPPaaS users who want AI-empowered workflow automation.

Local AI-empowered orchestrator — automate workflows that connect your
services and AI models.

> Status: placeholder. This module is not implemented yet — there is no
> `n8n.json`, no install/update/test scripts, and no VM configuration. The
> planned approach (from the original notes) is a VM running Docker, with a
> Docker Compose setup of n8n and PostgreSQL. AI access is planned to go
> through the LiteLLM gateway (`litellm:models`), like the other AI clients
> (see `docs/Architecture/AIDesign.md`).

## What you get

| Capability | Access from | How |
|------------|-------------|-----|
| Workflow orchestration (n8n) | not yet defined | planned: n8n via Docker Compose |
| Workflow persistence | not yet defined | planned: PostgreSQL via Docker Compose |

## What is not included

- A working installation — the module is a placeholder and cannot be
  installed yet

## Requirements

- A VM running Docker (planned; not yet automated)

## Dependencies

No `n8n.json` exists yet, so the module's `dependsOn` list is not defined.

| Depends on | Purpose |
|------------|---------|
| — | to be defined when `n8n.json` is written |

For installation steps see [INSTALL.md](./INSTALL.md).
