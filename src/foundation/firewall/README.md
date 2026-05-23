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

## Installing the firewall (bootstrap)

The firewall is installed **during foundation bootstrap, before tappaas-cicd
exists**. `config-firewall.sh` stands up the OPNsense VM and seeds a complete
management-network config via the OPNsense **importer**, so it comes up fully
functional (LAN, DNS/DHCP, static hosts, hostname, API key) with **no GUI
clicking** — replacing the long manual GUI procedure. The VLAN/zone/proxy/rule
setup is layered on later by the opnsense-controller (`zone-manager`,
`caddy-manager`, `rules-manager`) inside cicd, which connects with the API key
seeded here.

### Image (issue #182)

The firewall installs from the OPNsense **dvd installer ISO** onto an
**expandable UFS disk** (32G). It no longer uses the `nano` image, whose fixed
raw layout could not be grown and caused disk-full update failures.

### Files

| File | Role |
|------|------|
| `config-firewall.sh` | Bootstrap orchestrator — run on a PVE node; creates the VM, seeds config, guides the installer. |
| `firewall-config.xml.template` | Parameterized OPNsense `config.xml` (placeholders `@APIKEYS@`, `@ROOT_PW_HASH@`). Other values are TAPPaaS conventions (mgmt `10.0.0.0/24`, `internal`/`mgmt.internal`, static hosts). No private keys/certs are committed; OPNsense regenerates the GUI cert on first boot. |

### Procedure

1. **Prerequisite — node networking.** Build the `lan`/`wan` bridges first (the
   OPNsense VM attaches `net0→lan`, `net1→wan`):
   ```bash
   ~/tappaas/config-network.sh --lan-port <ifX> --wan-port <ifY>
   ```
2. **Bootstrap the firewall** (downloads + decompresses the dvd ISO, generates
   an API key, builds the importer drive, creates and starts the VM):
   ```bash
   curl -fsSL https://raw.githubusercontent.com/TAPPaaS/TAPPaaS/main/src/foundation/firewall/config-firewall.sh >/root/tappaas/config-firewall.sh
   chmod +x /root/tappaas/config-firewall.sh
   /root/tappaas/config-firewall.sh
   ```
   It prompts for a root password (or generates one) and writes the API
   credentials to `~/.opnsense-credentials.txt` for cicd.
3. **Complete the OPNsense installer in the Proxmox console** (the only manual
   step — OPNsense has no unattended install):
   - At *“Press any key to start the configuration importer”* → select the
     **OPNCONFIG** FAT drive → it imports `config.xml`.
   - Log in as `installer` / `opnsense`, choose **Install (UFS)**, target = the
     32G disk, finish and reboot.
4. **Confirm** at the script's prompt; it flips boot order to the disk, detaches
   the installer CD + importer drive, and verifies `10.0.0.1` is reachable.
5. **Swap cables** — point the node at the firewall for routing + DNS:
   ```bash
   ~/tappaas/config-network.sh --swap-cables
   ```

### Bootstrap vs cicd

| Stage | Configures | Tooling |
|------|------------|---------|
| Bootstrap | VM + expandable UFS disk; LAN `10.0.0.1`; DHCP; Unbound+Dnsmasq DNS; mgmt static hosts; hostname; **API key enabled** | `config-firewall.sh` + seeded `config.xml` (no cicd) |
| Later | VLANs/zones, per-module reverse proxy, firewall rules, ACME certs | opnsense-controller (`zone-manager`/`caddy-manager`/`rules-manager`) in tappaas-cicd |

> **Maintenance note:** `firewall-config.xml.template` must track the OPNsense
> version in `firewall.json` — OPNsense's `config.xml` format can change across
> releases.

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
  `tappaas_module_<vmname>` populated with the peer's FQDN
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
and orphan detection. There are two prefixes:

```
tappaas-module:<vmname>:<direction>:<peer>:<port>[/<protocol>]   # manual rules (#151)
tappaas-svcdep:<consumer>:<service>:<provider>:<port>[/<protocol>]  # auto-pinholes (#173)
```

Examples:
- `tappaas-module:litellm:ingress:srv-work:4000`
- `tappaas-module:litellm:egress:vllm:11434`
- `tappaas-module:hassosova:egress:iot-home:5353/UDP`
- `tappaas-svcdep:hassosova:mqtt:mosquitto:1883`  ← auto-pinhole

The owner-module is always position 1; that's the consumer for `tappaas-svcdep`
and the rule-owning module for `tappaas-module`. `list-rules`, `verify-rules`,
`reconcile`, and `remove-rules` recognise both prefixes.

### Auto-pinholes from service dependencies (issue #173)

Manual `ingress` / `egress` entries cover bespoke firewall policy. For the
common case — "this module just needs to talk to the service it depends on" —
the firewall:rules service can synthesise the pinhole automatically.

A **service provider** opts in by dropping a `pinhole.json` in its service
directory declaring the ports the service answers on:

```jsonc
// <provider-module>/services/<service>/pinhole.json
{
  "ports": [
    { "port": 4000, "protocol": "TCP", "description": "LiteLLM API" },
    { "port": 4001, "protocol": "TCP", "description": "Prometheus scrape" }
  ]
}
```

A **consumer module** triggers the auto-pinhole simply by depending on the
service and declaring `firewall:rules` in its own dependsOn:

```jsonc
{
  "vmname": "translation-agent",
  "zone0": "srv-work",
  "dependsOn": [
    "cluster:vm",
    "firewall:rules",          // opt into per-module firewall
    "litellm:llm-proxy"        // provider:service with a pinhole.json
  ]
}
```

When the consumer's install runs, `rules-manager` walks `dependsOn`, finds
each provider's `pinhole.json`, and emits one auto-pinhole per declared port —
**only** when:

1. The two modules are in different zones (intra-zone traffic flows freely).
2. The consumer's zone is **not already** in the provider zone's `access-to`
   (zone-level rule covers it).
3. The consumer's zone **is** in the provider zone's `pinhole-allowed-from`
   (policy gate).

If condition 3 fails, the auto-pinhole is **skipped with a warning** — the
operator chose this trade-off on the original ticket: a missing zone policy
should not block an install, just be loud about what wasn't done.

Auto-pinholes are owned by the **consumer**: they're created when the consumer
is installed, recomputed on `reconcile` (so a changed dependsOn re-applies),
and removed on the consumer's teardown — regardless of the provider's state.

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

## Test network on a dedicated physical port (issue #225)

`test-network.sh` stands up a throwaway, isolated test network served on a
**spare physical NIC** of the node running the firewall VM — separate from the
VLAN trunk that carries the production zones. Plug a switch or AP into the spare
port and you get an isolated, internet-connected sandbox without touching
`zones.json` or the trunk.

```bash
test-network.sh                       # interactive: pick a vacant port, default 172.17.3.1/24
test-network.sh --port enp3s0         # non-interactive port choice
test-network.sh --subnet 172.17.9.1/24 --bridge testbr2
test-network.sh --status              # show current state
test-network.sh --delete              # tear down in reverse order
test-network.sh --check-mode ...      # dry run, no changes
```

What it does, in order (and reverses on `--delete`):

1. Finds the node hosting the firewall VM (`pvesh`), discovers vacant physical
   ports, and prompts for one.
2. Creates a Linux bridge on that node and enslaves the port, persisted in
   `/etc/network/interfaces` (backed up first) and applied with `ifreload`.
3. Attaches the bridge to the firewall VM as a new virtio NIC (`qm set --netN`),
   which appears in OPNsense as `vtnetN`.
4. Drives the OPNsense side via `test-network-manager` (a new
   `opnsense-controller` entry point): assigns the interface with a static
   gateway IP, enables DHCP, and installs the routing/firewall policy.

**Routing policy** (asymmetric, per the issue):

| From → To | Action | Notes |
|-----------|--------|-------|
| test → internet | allow | OPNsense automatic outbound NAT covers `172.16/12` |
| test → internal (RFC1918, incl. mgmt) | block | isolation |
| mgmt → test | allow | return traffic is stateful, so test→mgmt stays blocked |

All OPNsense artefacts (interface, DHCP range, rules) carry a `test-net`
description so teardown removes exactly what setup created.

> **Note:** `test-network-manager` is a new console-script entry point in the
> `opnsense-controller` package. Rebuild that package (e.g. via
> `update-tappaas` / `nixos-rebuild`) so the wrapper lands in `PATH`;
> `test-network.sh` falls back to `python3 -m opnsense_controller.test_network_cli`
> when the wrapper is not yet present.

See [`docs/test-network-setup.md`](docs/test-network-setup.md) for the full
setup/teardown runbook, options, verification, and troubleshooting.

## Related files

- [`zones.json`](zones.json) — canonical zone definitions (referenced from `from`/`to`)
- [`aliases.json`](aliases.json) — global aliases shared across modules
- [`services/rules/`](services/rules/) — capability lifecycle scripts
- `tappaas-cicd/opnsense-controller/src/opnsense_controller/rules_manager.py` — implementation
- [`../ZONES.md`](../ZONES.md) — zone reference
- [`../module-fields.json`](../module-fields.json) — full field schema
