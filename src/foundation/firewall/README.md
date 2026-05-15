# Firewall Foundation Module

OPNsense-backed firewall capability for TAPPaaS. Provides zone-level rules via
`zone-manager` and **per-module rules** via `rules-manager`.

This module is the canonical source of `zones.json` and `aliases.json`. The
deployed copies in `/home/tappaas/config/` are seeded from here.

## Capabilities

| Capability | Entry point | Purpose |
|------------|-------------|---------|
| `firewall:proxy` | `services/proxy/*.sh` → `caddy-manager` | Caddy reverse-proxy registration per consumer module |
| `firewall:rules` | `services/rules/*.sh` → `rules-manager` | Per-module ingress/egress firewall rules compiled from `module.json` |

A consumer module opts in by adding the capability to its `dependsOn`, e.g.:

```json
"dependsOn": ["cluster:vm", "firewall:proxy", "firewall:rules"]
```

## Per-Module Firewall Rules

The `firewall:rules` capability lets each module declare its inbound and
outbound network contract in its own JSON. Rules are compiled deterministically
into OPNsense and reconciled on every update.

### Schema fields (see [`module-fields.json`](../module-fields.json))

| Field | Purpose |
|-------|---------|
| `ports[]` | Network ports the module exposes for inbound traffic. Source of truth for ingress validation. |
| `ingress[]` | Inbound traffic permitted to those ports (`from`, `ports`, `protocol`, `description`). |
| `egress[]` | Outbound exceptions beyond the source zone's `access-to` (`to`, `ports`, `protocol`, `description`). |
| `aliases{}` | Module-local OPNsense aliases referenced by `alias:<name>`. Overrides identically named entries in [`aliases.json`](aliases.json). |

The `from` / `to` fields accept:

- A **zone name** (must exist in `zones.json`)
- The literal `"internet"` (resolves to WAN-side `any`)
- Another **module name** — resolved to an OPNsense host alias
  `tappaas-module-<vmname>` populated with the peer's FQDN
  (`<vmname>.<zone0>.internal`). OPNsense's Unbound resolves the FQDN against
  dnsmasq, so DHCP-driven IP changes flow through without rule rewrites.
- `"alias:<name>"` — references a module-local alias or a global entry in
  [`aliases.json`](aliases.json).

### Worked example

```json
{
  "vmname": "litellm",
  "zone0": "srv-work",
  "dependsOn": ["cluster:vm", "firewall:proxy", "firewall:rules"],
  "ports": [
    { "port": 4000, "protocol": "TCP", "description": "LiteLLM API" }
  ],
  "ingress": [
    { "from": "srv-work", "ports": [4000], "description": "Intra-zone consumers" },
    { "from": "dmz",      "ports": [4000], "description": "Reverse proxy" }
  ],
  "egress": [
    { "to": "alias:llm_providers", "ports": [443],   "description": "Upstream LLM APIs" },
    { "to": "vllm",                "ports": [11434], "description": "Local inference fallback" }
  ],
  "aliases": {
    "llm_providers": {
      "type": "host",
      "addresses": ["api.anthropic.com", "api.openai.com"],
      "description": "Approved upstream providers"
    }
  }
}
```

### Rule identity

Every compiled rule carries a canonical description used for idempotent upsert
and orphan detection:

```
tappaas-module:<vmname>:<direction>:<peer>:<port>[/<protocol>]
```

Examples:
- `tappaas-module:litellm:ingress:srv-work:4000`
- `tappaas-module:litellm:egress:vllm:11434`
- `tappaas-module:hassosova:egress:iot-home:5353/UDP`

### Sequence bands

| Band | Range | Source | Purpose |
|------|-------|--------|---------|
| 0 | 0–99 | OPNsense auto | Anti-lockout |
| 1 | 100–999 | `zone-manager` | Infrastructure (DHCP, NTP, ICMP) |
| 2 | 1000–9999 | `zone-manager` | Foundation deny defaults |
| **3** | **10000–19999** | **`rules-manager` ingress** | Per-module pinholes |
| **4** | **20000–29999** | **`rules-manager` egress** | Per-module egress exceptions |
| 5 | 30000–39999 | `zone-manager` | Zone-level `access-to` allows |
| 6 | 40000–49999 | Manual | Logging-only |
| 7 | 50000–59999 | Manual | Administrator overrides |

Within bands 3 and 4, each module receives a deterministic 100-slot range based
on a stable hash of its `vmname`. Slot collisions are detected at compile time.

### Validation

Compile-time, before any OPNsense API call:

1. **Schema** — fields/types match `module-fields.json`.
2. **Zone existence** — every zone-named peer exists in `zones.json`.
3. **Policy** — every `ingress.from` is in destination zone's `pinhole-allowed-from`.
4. **Port consistency** — every `ingress.ports` value is in `module.ports[]`.
5. **Module existence** — every module-named peer has a corresponding `<peer>.json` on disk.

Egress to a zone not in the source zone's `access-to` is permitted but logged
as a warning (exceptions are intentional).

### `firewallType: "NONE"` fallback

When `firewall.json` declares `firewallType: "NONE"`, the service scripts skip
OPNsense entirely and `rules-manager` prints the rules in a human-readable form
for manual entry into the operator's firewall. Exit code 0.

## CLI: `rules-manager`

```bash
rules-manager add-rules <module>          # compile + apply
rules-manager reconcile <module>          # diff + apply + prune orphans
rules-manager remove-rules <module>       # delete all rules/aliases for module
rules-manager verify-rules <module> [--deep]
rules-manager list-rules [--module <n>] [--orphans]
rules-manager create-alias <name> --type host --addresses ip1,ip2
rules-manager remove-alias <name>

# Common flags:
#   --firewall-type opnsense|NONE
#   --zones-file <path>          --aliases-file <path>
#   --modules-dir <path>         --check-mode
#   --output text|json           --no-ssl-verify
#   --credential-file <path>     --debug
```

The CLI is normally invoked by the `services/rules/*.sh` capability scripts on
the consumer module's lifecycle hooks, but can be run directly for debugging.

## Related files

- [`zones.json`](zones.json) — canonical zone definitions (referenced from `from`/`to`)
- [`aliases.json`](aliases.json) — global aliases shared across modules
- [`services/rules/`](services/rules/) — capability lifecycle scripts
- `tappaas-cicd/opnsense-controller/src/opnsense_controller/rules_manager.py` — implementation
- [`../ZONES.md`](../ZONES.md) — zone reference
- [`../module-fields.json`](../module-fields.json) — full field schema
