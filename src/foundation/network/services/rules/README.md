# network:rules service

Compiles a module's declared **firewall surface** into OPNsense rules — who may
reach it, what it may reach, and the named aliases those rules are built from.
The whole rule set for the module is re-derived on every pass, so a rule the
operator removed from the declaration is removed from the firewall.

The module's firewall surface. Every change is a live OPNsense API call;
established connections may reset, but nothing reboots.

## Why `reconcile`

A rule set is reconciled by adding, changing **and removing** rules against
OPNsense's own model. Removing a rule the operator deleted from `ingress` cannot
be expressed as a scalar diff — a generic differ would see "the value changed"
and have nothing to apply. `update-service.sh` re-derives the whole rule set for
this module on every pass and deletes what is no longer declared.

<!-- BEGIN GENERATED FIELDS -- edit the manifest, not this block -->

## Fields

`network:rules` owns **4** declared field(s). Each table below carries the field's full definition and, where the service applies it, its ADR-020 change semantics.

### `ingress`

Inbound traffic permitted to this module's ports. Each entry is compiled into an OPNsense pass rule and validated against the destination zone's pinhole-allowed-from policy at compile time.

| Attribute | Value |
|---|---|
| Type | `array` |
| Default | *(none)* |
| Example | `[{"from": "srvWork", "ports": [4000], "description": "Intra-zone consumers read the API"}, {"from": "dmz", "ports": [4000], "description": "Caddy reverse proxy forwards the public hostname"}]` |
| Required by | *(none)* |
| Used by | `network:rules` |
| Change class | `in-place` |
| Apply mode | `reconcile` |

**About the field.** Module peer (from = another module name): compiler ensures an OPNsense host alias 'tappaas_module_<peer>' exists, populated with the peer's FQDN; the rule references the alias so DHCP IP changes are absorbed by Unbound resolution. (Underscores: OPNsense alias names cannot contain hyphens.)

**Why this change class.** Who may reach this module. A rule swap on OPNsense takes effect immediately; no guest is touched, so there is no downtime to authorize.

### `egress`

Outbound traffic exceptions beyond what the source zone's access-to already permits. Compiled into OPNsense pass rules on the source-zone interface.

| Attribute | Value |
|---|---|
| Type | `array` |
| Default | *(none)* |
| Example | `[{"to": "alias:llm_cloud_providers", "ports": [443], "description": "Upstream LLM providers"}, {"to": "vllm-amd", "ports": [11434], "description": "Local inference fallback"}]` |
| Required by | *(none)* |
| Used by | `network:rules` |
| Change class | `in-place` |
| Apply mode | `reconcile` |

**About the field.** Module peer (to = another module name): compiler creates a host alias 'tappaas_module_<peer>' from the peer's FQDN. A warning is emitted when 'to' is a zone not in the source zone's access-to list.

**Why this change class.** What this module may reach (consumer egress, ADR-COM-0002). Same cost as ingress.

### `ports`

Network ports this module exposes for inbound traffic. Source of truth for ingress validation.

| Attribute | Value |
|---|---|
| Type | `array` |
| Default | *(none)* |
| Example | `[{"port": 4000, "protocol": "TCP", "description": "Service API"}]` |
| Required by | *(none)* |
| Used by | `network:rules` |
| Change class | `in-place` |
| Apply mode | `reconcile` |

**About the field.** Ingress entries must reference ports declared here. Activated when network:rules is in dependsOn.

**Why this change class.** The module's declared service surface, from which the default ingress rules are derived.

### `aliases`

Module-local OPNsense aliases that this module's ingress/egress rules reference via 'alias:<name>'. Module-local aliases override identically named entries in firewall/aliases.json (a warning is emitted on collision).

| Attribute | Value |
|---|---|
| Type | `object` |
| Default |  |
| Example | `{"llm_cloud_providers": {"type": "host", "addresses": ["api.anthropic.com", "api.openai.com"], "description": "Curated whitelist of approved upstream model providers"}}` |
| Required by | *(none)* |
| Used by | `network:rules` |
| Change class | `in-place` |
| Apply mode | `reconcile` |

**About the field.** Aliases are created in OPNsense before referencing rules are applied, and removed on remove-rules unless still referenced by other modules.

**Why this change class.** Named address/port groups the module's rules refer to. Changing one re-points every rule that uses it — still a live firewall change, still no downtime.

<!-- END GENERATED FIELDS -->
