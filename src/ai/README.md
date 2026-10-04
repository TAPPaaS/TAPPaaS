# AI stack

Local AI for your organisation: a GPU model server, one gateway every client uses, and a chat
front end — no prompt leaves your site. How the parts fit: [DESIGN.md](DESIGN.md). On the
website: [AI Stack](https://tappaas.org/stacks/ai/).

**Planned:** [n8n](n8n/README.md) — AI-empowered workflow automation, through the LiteLLM
gateway (a placeholder directory, no module yet).

<!-- BEGIN GENERATED MODULES -- edit the module JSONs and src/module-catalog.json, not this block -->

| Module | What it is | Status |
|---|---|---|
| [vllm-amd](vllm-amd/README.md) | vLLM AMD ROCm inference — Ryzen AI MAX+ 395 (tappaas2) | Development |
| [litellm](litellm/README.md) | TAPPaaS LiteLLM | Development |
| [openwebui](openwebui/README.md) | TAPPaaS Open Webui | Development |

Install them as [INSTALL.md](INSTALL.md) says.

<!-- END GENERATED MODULES -->

## Architecture view

```kroki-plantuml
@startuml
!include <archimate/Archimate>

title TAPPaaS AI Stack

' Business Actor
Business_Actor(user, "Platform User")

' Application Components (AI Services)
Application_Component(webui, "OpenWebUI")
Application_Component(litellm, "LiteLLM")
Application_Component(vllm, "vLLM")

' External Application Services
Application_Service(openai, "OpenAI API")
Application_Service(anthropic, "Anthropic API")

' Application Services exposed by components
Application_Service(chatSvc, "Chat Service")
Application_Service(routingSvc, "Model Routing")
Application_Service(inferenceSvc, "Local Inference")

' Components realize services
Rel_Realization(webui, chatSvc)
Rel_Realization(litellm, routingSvc)
Rel_Realization(vllm, inferenceSvc)

' User uses chat service
Rel_Serving(chatSvc, user)

' Service dependencies
Rel_Serving(routingSvc, webui)
Rel_Serving(inferenceSvc, litellm)
Rel_Serving(openai, litellm)
Rel_Serving(anthropic, litellm)

@enduml
```

How modules are grouped into stacks: [ADR-004](../../docs/ADR/ADR-004-module-catalog-config-cascade.md),
*Where a module's directory is*. The module lists here and in [INSTALL.md](INSTALL.md) are generated
by `src/foundation/tappaas-cicd/scripts/gen-stack-readme.py` from `src/module-catalog.json`.
