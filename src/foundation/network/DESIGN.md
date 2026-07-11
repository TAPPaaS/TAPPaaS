# network — Design notes

Implementation and reference detail for the network module (OPNsense firewall, zones,
DNS, per-module rules, reverse proxy). For the catalog entry see [README.md](./README.md);
for installation see [INSTALL.md](./INSTALL.md); for test coverage see [TEST.md](./TEST.md).

This module is the canonical source of [`aliases.json`](aliases.json); the deployed copy
in `/home/tappaas/config/` is seeded from here. The canonical `zones.json` lives with
`network-manager`
([`../tappaas-cicd/manager/network-manager/zones.json`](../tappaas-cicd/manager/network-manager/zones.json)),
which transforms it into the live per-installation `config/zones.json` at install time.

## Capabilities

| Capability | Entry point | Purpose |
|------------|-------------|---------|
| `network:proxy` | `services/proxy/*.sh` → `caddy-manager` | Caddy reverse-proxy registration per consumer module |
| `network:rules` | `services/rules/*.sh` → `rules-manager` | Per-module ingress/egress firewall rules compiled from `module.json` |

A consumer module opts in by adding the capability to its `dependsOn`, e.g.:

```json
"dependsOn": ["cluster:vm", "network:proxy", "network:rules"]
```

## Firewall bootstrap (prebuilt image)

The firewall is installed **during foundation bootstrap, before tappaas-cicd exists**.
`config-firewall.sh` (issues #141, #182, #231) imports a **preconfigured OPNsense image**
(built by GitHub Actions, published as a Release — see
`.github/workflows/build-opnsense-image.yml`) that boots straight to a working firewall
at `10.0.0.1` — LAN, DNS/DHCP, static hosts, hostname, API enabled — with **no GUI
clicking and no installer** (this replaced the earlier dvd-ISO + manual console-installer
procedure).

Deployment-unique credentials, over one-shot SSH: OPNsense has no API to create/rotate
API keys, so the unique API key + root password are applied by replacing
`/conf/config.xml` (rendered from `firewall-config.xml.template`) over the image's
well-known bootstrap SSH, then rebooting. The deployed config has SSH **off**, so the
bootstrap credentials die with the push; they are only ever reachable on the isolated
bootstrap LAN. API credentials for cicd land in `~/.opnsense-credentials.txt`.

The disk is an **expandable UFS** disk (32G, issue #182) — the earlier `nano` image's
fixed raw layout could not be grown and caused disk-full update failures.

### Files

| File | Role |
|------|------|
| `config-firewall.sh` | Bootstrap orchestrator — run on a PVE node; creates the VM from the prebuilt image and pushes the unique config. |
| `firewall-config.xml.template` | Parameterized OPNsense `config.xml` (placeholders `@APIKEYS@`, `@ROOT_PW_HASH@`). Other values are TAPPaaS conventions (mgmt `10.0.0.0/24`, `internal`/`mgmt.internal`, static hosts). No private keys/certs are committed; OPNsense regenerates the GUI cert on first boot. |
| `migrate-firewall-to-network.sh` | Supervised migration of a legacy `firewall` module install to the `network` name (ADR-007 P8). |
| `update.sh` | Module update: OPNsense software update → conditional reboot → DNS health check → zone-manager → proxy/trunk reconfiguration. |

### Bootstrap vs cicd

| Stage | Configures | Tooling |
|------|------------|---------|
| Bootstrap | VM + expandable UFS disk; LAN `10.0.0.1`; DHCP; Unbound+Dnsmasq DNS; mgmt static hosts; hostname; **API key enabled** | `config-firewall.sh` + seeded `config.xml` (no cicd) |
| Later | VLANs/zones, per-module reverse proxy, firewall rules, ACME certs | opnsense-controller (`zone-manager`/`caddy-manager`/`rules-manager`) in tappaas-cicd |

> **Maintenance note:** `firewall-config.xml.template` must track the OPNsense version
> in `network.json` — OPNsense's `config.xml` format can change across releases.

> **Naming note (ADR-007 P8):** the module was renamed `firewall` → `network`; the
> OPNsense **host** is still `firewall.mgmt.internal` (the host rename is a deferred
> supervised migration). `update.sh` resolves `config/network.json` first and falls back
> to the legacy `config/firewall.json`.

## Per-module firewall rules

The `network:rules` capability lets each module declare its inbound and outbound network
contract in its own JSON. Rules are compiled deterministically into OPNsense and
reconciled on every update.

### Schema fields (see [`module-fields.json`](../schemas/module-fields.json))

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
  `tappaas_module_<vmname>` populated with the peer's FQDN (`<vmname>.<zone0>.internal`).
  OPNsense's Unbound resolves the FQDN against dnsmasq, so DHCP-driven IP changes flow
  through without rule rewrites.
- `"alias:<name>"` — references a module-local alias or a global entry in
  [`aliases.json`](aliases.json).

### Worked example

```json
{
  "vmname": "litellm",
  "zone0": "srv_work",
  "dependsOn": ["cluster:vm", "network:proxy", "network:rules"],
  "ports": [
    { "port": 4000, "protocol": "TCP", "description": "LiteLLM API" }
  ],
  "ingress": [
    { "from": "srv_work", "ports": [4000], "description": "Intra-zone consumers" },
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

Every compiled rule carries a canonical description used for idempotent upsert and
orphan detection. There are two prefixes:

```
tappaas-module:<vmname>:<direction>:<peer>:<port>[/<protocol>]      # manual rules (#151)
tappaas-svcdep:<consumer>:<service>:<provider>:<port>[/<protocol>]  # auto-pinholes (#173)
```

Examples:
- `tappaas-module:litellm:ingress:srv_work:4000`
- `tappaas-module:litellm:egress:vllm:11434`
- `tappaas-module:hassosova:egress:iot-home:5353/UDP`
- `tappaas-svcdep:hassosova:mqtt:mosquitto:1883`  ← auto-pinhole

The owner-module is always position 1; that's the consumer for `tappaas-svcdep` and the
rule-owning module for `tappaas-module`. `list-rules`, `verify-rules`, `reconcile`, and
`remove-rules` recognise both prefixes.

### Auto-pinholes from service dependencies (issue #173)

Manual `ingress` / `egress` entries cover bespoke firewall policy. For the common case —
"this module just needs to talk to the service it depends on" — the network:rules
service can synthesise the pinhole automatically.

A **service provider** opts in by dropping a `pinhole.json` in its service directory
declaring the ports the service answers on:

```jsonc
// <provider-module>/services/<service>/pinhole.json
{
  "ports": [
    { "port": 4000, "protocol": "TCP", "description": "LiteLLM API" },
    { "port": 4001, "protocol": "TCP", "description": "Prometheus scrape" }
  ]
}
```

A **consumer module** triggers the auto-pinhole simply by depending on the service and
declaring `network:rules` in its own dependsOn:

```jsonc
{
  "vmname": "translation-agent",
  "zone0": "srv_work",
  "dependsOn": [
    "cluster:vm",
    "network:rules",           // opt into per-module firewall
    "litellm:llm-proxy"        // provider:service with a pinhole.json
  ]
}
```

When the consumer's install runs, `rules-manager` walks `dependsOn`, finds each
provider's `pinhole.json`, and emits one auto-pinhole per declared port — **only** when:

1. The two modules are in different zones (intra-zone traffic flows freely).
2. The consumer's zone is **not already** in the provider zone's `access-to`
   (zone-level rule covers it).
3. The consumer's zone **is** in the provider zone's `pinhole-allowed-from`
   (policy gate).

If condition 3 fails, the auto-pinhole is **skipped with a warning** — the operator
chose this trade-off on the original ticket: a missing zone policy should not block an
install, just be loud about what wasn't done.

Auto-pinholes are owned by the **consumer**: they're created when the consumer is
installed, recomputed on `reconcile` (so a changed dependsOn re-applies), and removed on
the consumer's teardown — regardless of the provider's state.

### Sequence bands

| Band | Range | Source | Purpose |
|------|-------|--------|---------|
| 0 | 0–99 | OPNsense auto | Anti-lockout |
| 1 | 100–999 | `zone-manager` | Infrastructure (DHCP, NTP, ICMP); Caddy reachability to the DMZ gateway `/32` on tcp/80+443 from every internet-capable zone (seq 990/991, #366) |
| 2 | 1000–9999 | `zone-manager` | Foundation deny defaults |
| **3** | **10000–19999** | **`rules-manager` ingress** | Per-module pinholes |
| **4** | **20000–29999** | **`rules-manager` egress** | Per-module egress exceptions |
| 5 | 30000–39999 | `zone-manager` | Zone-level rules: gateway + `access-to` allows, then rfc1918 block + internet |
| 6 | 40000–49999 | Manual | Logging-only |
| 7 | 50000–59999 | Manual | Administrator overrides |

Within bands 3 and 4, each module receives a deterministic 100-slot range based on a
stable hash of its `vmname`. Slot collisions are detected at compile time.

Rules use `quick` (first match wins; **lower sequence = higher priority**). Band 5 sits
*above* the module bands so a zone's rfc1918 catch-all block (which isolates a zone from
unlisted internal networks) is evaluated *after* per-module pinholes — otherwise it would
shadow them and silently break cross-zone module connectivity (#243). Within band 5 each
zone gets a deterministic 100-slot range (stable hash of the zone name; cross-zone slot
collisions are harmless since each zone's rules bind to its own interface). The
intra-slot offsets are fixed — `base+0` gateway, `base+1..+89` one pass per `access-to`
zone, `base+90..+92` rfc1918 block, `base+99` internet — so adding a zone to `access-to`
never renumbers or collides with the block/internet rules.

### Validation

Compile-time, before any OPNsense API call:

1. **Schema** — fields/types match `module-fields.json`.
2. **Zone existence** — every zone-named peer exists in `zones.json`.
3. **Policy** — every `ingress.from` is in destination zone's `pinhole-allowed-from`.
4. **Port consistency** — every `ingress.ports` value is in `module.ports[]`.
5. **Module existence** — every module-named peer has a corresponding `<peer>.json`
   on disk.

Egress to a zone not in the source zone's `access-to` is permitted but logged as a
warning (exceptions are intentional).

### `firewallType: "NONE"` fallback

When `network.json` declares `firewallType: "NONE"`, the service scripts skip OPNsense
entirely and `rules-manager` prints the rules in a human-readable form for manual entry
into the operator's firewall. Exit code 0.

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

The CLI is normally invoked by the `services/rules/*.sh` capability scripts on the
consumer module's lifecycle hooks, but can be run directly for debugging.

## Physical network: switches & WiFi (ADR-008)

Beyond OPNsense (L3), `zones.json` is also reconciled onto **Proxmox** bridges/trunks,
**physical switches**, and **WiFi APs** so a zone's VLAN is carried everywhere it needs
to be. These providers live in [`scripts/`](scripts/) and run on tappaas-cicd (symlinked
into `~/bin`):

| Script | Role |
|--------|------|
| `zone-reconcile` | orchestrator — runs every provider in order (`opnsense → proxmox → switch → ap`) |
| `switch-controller` | physical switches (controllers / switches / ports → trunk + access VLANs) |
| `ap-manager` | WiFi APs (SSID → VLAN via the vendor controller) |
| `proxmox-manager` | node bridge-vids + per-VM trunks (#335) |
| `setup-switches.sh` | interactive switch registration (bootstrap step #351) |
| `setup-wlan-secrets.sh` | set WiFi SSID names (in `zones.json`) + passphrases (0600 secrets file) |

Each provider follows a 5-verb contract (`interrogate → update-desired → delta → apply →
confirm`) over two files in `~/config/`: `switch-configuration-actual.json` (reality) and
`…-desired.json` (regenerated from `zones.json`). Vendor automation is plugin-based
(`scripts/plugins/<vendor>.sh`; `unifi.sh` shipped, `manual.sh` is the by-hand fallback).

**Full command reference, the inventory model, and how to add a switch brand:
[`scripts/README.md`](scripts/README.md).**

## Test network on a dedicated physical port (issue #225)

`test-network.sh` stands up a throwaway, isolated test network served on a **spare
physical NIC** of the node running the firewall VM — separate from the VLAN trunk that
carries the production zones. Plug a switch or AP into the spare port and you get an
isolated, internet-connected sandbox without touching `zones.json` or the trunk.

```bash
test-network.sh                       # interactive: pick a vacant port, default 172.17.3.1/24
test-network.sh --port enp3s0         # non-interactive port choice
test-network.sh --subnet 172.17.9.1/24 --bridge testbr2
test-network.sh --status              # show current state
test-network.sh --delete              # tear down in reverse order
test-network.sh --check-mode ...      # dry run, no changes
```

What it does, in order (and reverses on `--delete`):

1. Finds the node hosting the firewall VM (`pvesh`), discovers vacant physical ports,
   and prompts for one.
2. Creates a Linux bridge on that node and enslaves the port, persisted in
   `/etc/network/interfaces` (backed up first) and applied with `ifreload`.
3. Attaches the bridge to the firewall VM as a new virtio NIC (`qm set --netN`), which
   appears in OPNsense as `vtnetN`.
4. Drives the OPNsense side via `test-network-manager` (an `opnsense-controller` entry
   point): assigns the interface with a static gateway IP, enables DHCP, and installs
   the routing/firewall policy.

**Routing policy** (asymmetric, per the issue):

| From → To | Action | Notes |
|-----------|--------|-------|
| test → internet | allow | OPNsense automatic outbound NAT covers `172.16/12` |
| test → internal (RFC1918, incl. mgmt) | block | isolation |
| mgmt → test | allow | return traffic is stateful, so test→mgmt stays blocked |

All OPNsense artefacts (interface, DHCP range, rules) carry a `test-net` description so
teardown removes exactly what setup created.

> **Note:** `test-network-manager` is a console-script entry point in the
> `opnsense-controller` package. Rebuild that package (e.g. via `update-tappaas` /
> `nixos-rebuild`) so the wrapper lands in `PATH`; `test-network.sh` falls back to
> `python3 -m opnsense_controller.test_network_cli` when the wrapper is not yet present.

See [`docs/test-network-setup.md`](docs/test-network-setup.md) for the full
setup/teardown runbook, options, verification, and troubleshooting.

## Troubleshooting: Unbound / DNSBL

**Symptom:** DNS resolution fails on the mgmt network (clients cannot resolve via
`10.0.0.1`), typically during `zone-manager --execute` or right after a firewall
update. Unbound logs show `ModuleNotFoundError: No module named 'dns'`.

**Root cause (Python version mismatch):** OPNsense 25.x compiles Unbound against
**Python 3.11** but ships dnspython only as **py313-dnspython** (py311-dnspython does
not exist in the OPNsense repos). The `unbound.inc` PHP plugin *unconditionally* adds
`python iterator` to the module-config and includes the DNSBL python script, so any
operation that regenerates the Unbound config (zone-manager API calls, an OPNsense
update) produces a config Unbound cannot load. The prebuilt image works only because it
ships a pre-generated `/var/unbound/unbound.conf` — the failure appears on the first
regeneration. This is why `update.sh` runs the OPNsense update + reboot **before**
zone-manager, followed by a DNS health check.

**Second root cause (working-directory path):** the DNSBL module is referenced by a
relative path, and only one of the two Unbound start paths sets the working directory:

| Method | Script | Has `cd /var/unbound/` | Result |
|--------|--------|------------------------|--------|
| `pluginctl -c unbound_start` | `/usr/local/opnsense/scripts/unbound/start.sh` | Yes | **Works** |
| `service unbound restart` | `/usr/local/etc/rc.d/unbound` | No | **Fails** |

Restarting via the `rc.d` script runs `unbound-checkconf` from the wrong directory:
`pythonmod: can't open file unbound-dnsbl/dnsbl_module.py for reading`. The OPNsense
API and configd use `pluginctl`, so API-driven restarts work.

**Recovery** (on the firewall, csh):

```csh
pluginctl -c unbound_start
```

This uses `start.sh`, which handles the working directory correctly. Equivalent
verbose form: `cd /var/unbound && /usr/local/sbin/unbound-checkconf
/var/unbound/unbound.conf && service unbound restart`. To diagnose, `service unbound
status` + `unbound-checkconf /var/unbound/unbound.conf` — running-but-checkconf-fails
means the process holds an old working config and any restart will fail.

**Permanent-fix options** (none applied yet — the update.sh ordering is the mitigation):

1. Patch `unbound.inc` to drop the Python module from the module-config (disables DNSBL
   integration; overwritten by OPNsense updates).
2. Wait for OPNsense to fix the mismatch (ship py311-dnspython or rebuild Unbound
   against Python 3.13).
3. Patch `/usr/local/etc/rc.d/unbound` to `cd /var/unbound` before its checkconf calls
   (fixes the path issue, not the version mismatch).
4. Disable DNSBL entirely (removes DNS-level ad/malware blocking).

## Related files

- [`aliases.json`](aliases.json) — global aliases shared across modules
- [`services/`](services/) — capability lifecycle scripts (proxy, rules, …)
- [`scripts/`](scripts/) — network orchestration (zone-reconcile, switch-controller,
  ap-manager, setup-*) — see [`scripts/README.md`](scripts/README.md)
- `tappaas-cicd/controller/opnsense-controller/` — `rules-manager` implementation
- [`../tappaas-cicd/manager/network-manager/ZONES.md`](../tappaas-cicd/manager/network-manager/ZONES.md) — zone reference
- [`../../../docs/ADR/ADR-008-switch-module-network-infrastructure.md`](../../../docs/ADR/ADR-008-switch-module-network-infrastructure.md) — design
- [`../schemas/module-fields.json`](../schemas/module-fields.json) — full field schema
- [`docs/netbird-setup.md`](docs/netbird-setup.md) — netbird remote-management setup
