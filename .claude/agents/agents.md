# TAPPaaS Agent Registry & Routing

## Routing Decision Tree

When a user request comes in, classify it and dispatch to the appropriate agent(s):

### Single-Agent Tasks
```
Bash script create/modify     -> bash-dev
NixOS .nix create/modify      -> nix-dev
Python code create/modify     -> python-dev
Create/update tests           -> tester
Security audit/review         -> security
Network/firewall/DNS/DHCP     -> infra
Architecture/design question  -> architect
```

### Multi-Agent Tasks
```
New module deployment:
  1. architect   (design JSON config, zone, resources)
  2. nix-dev     (create .nix file — uses architect output)
  3. bash-dev    (create install.sh + update.sh — parallel with nix-dev)
  4. infra       (Caddy handler, firewall rules, DNS)
  5. tester      (create test.sh)
  6. security    (review ALL outputs)

Module with web interface + SSO:
  Same as above, plus:
  - infra adds Caddy reverse proxy handler
  - architect includes Authentik integration in design
  - nix-dev configures forward-auth or OIDC client

Bug investigation:
  1. Route to relevant specialist (bash-dev/nix-dev/python-dev/infra)
  2. tester creates regression test after fix

Foundation change:
  1. architect   (assess impact on dependency chain)
  2. Relevant specialist (bash-dev/nix-dev/python-dev)
  3. security    (review)
  4. tester      (regression tests)
```

### Escalation to pm
Use the `pm` agent when:
- Task involves 3+ agents
- Task has complex dependencies between phases
- User request is vague and needs decomposition
- Risk assessment needed before implementation

## Multi-Agent Context Passing Protocol

When dispatching sequential agents, pass prior outputs as context:
1. Include the previous agent's output in the next agent's prompt
2. Clearly label what was produced by which agent
3. For parallel agents (e.g., nix-dev + bash-dev), share the architect's output with both

## Agent File Reference
Each agent's full definition and prompt template is in:
- `agent-pm.md`, `agent-architect.md`, `agent-bash-dev.md`
- `agent-python-dev.md`, `agent-nix-dev.md`, `agent-tester.md`
- `agent-security.md`, `agent-infra.md`

## Invoking Agents

Use Claude Code's Task tool with `subagent_type="general-purpose"` and include:
1. The agent's prompt template from its definition file
2. The specific task description
3. Context from prior agents (if multi-agent workflow)
4. Relevant file paths the agent should read

Example:
```
Task tool call:
  description: "nix-dev: Create nextcloud.nix"
  subagent_type: "general-purpose"
  prompt: [agent prompt template] + [architect's JSON design] + [specific task]
```
