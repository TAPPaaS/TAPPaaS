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
`config-firewall.sh` imports a **preconfigured OPNsense image**
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

The disk is an **expandable UFS** disk (32G) — the earlier `nano` image's
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

## The API certificate: unverified, watched (#310)

The mothership reaches the firewall's API (443/8443) with `--no-ssl-verify`: the firewall's
certificate is OPNsense's self-signed one, issued for `network.internal`, while every caller
connects to `firewall.mgmt.internal`. What that leaves open is narrow — the API key travels to
whoever answers as the firewall, and answering as it needs a foothold on the management LAN
(8443 is closed to every other zone, #384) — and blocking on a pinned certificate would stop
the nightly sweep at every firewall rebuild or certificate renewal. So the certificate is
**watched, not pinned**: `check-firewall-cert` on the mothership (hourly) records its fingerprint
in `config/firewall-cert.json` and logs a line when it changes, or once a day in its last 30
days; logging mails both as **FirewallCertChanged**. A change after a rebuild or a renewal is
expected; any other change means something else answers as the firewall. Proper verification
comes with a TAPPaaS internal CA issuing the firewall a certificate for its real name (#787).

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
  `tm_<vmname>` populated with the peer's FQDN (`<vmname>.<zone0>.internal`).
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
tappaas-module:<vmname>:<direction>:<peer>:<port>[/<protocol>]      # manual rules
tappaas-svcdep:<consumer>:<service>:<provider>:<port>[/<protocol>]  # auto-pinholes
```

Examples:
- `tappaas-module:litellm:ingress:srv_work:4000`
- `tappaas-module:litellm:egress:vllm:11434`
- `tappaas-module:hassosova:egress:iot-home:5353/UDP`
- `tappaas-svcdep:hassosova:mqtt:mosquitto:1883`  ← auto-pinhole

The owner-module is always position 1; that's the consumer for `tappaas-svcdep` and the
rule-owning module for `tappaas-module`. `list-rules`, `verify-rules`, `reconcile`, and
`remove-rules` recognise both prefixes.

### Auto-pinholes from service dependencies

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

A **consumer module** triggers the auto-pinhole simply by declaring the service — in
`dependsOn` or in `integratesWith` — and declaring `network:rules` in its own dependsOn:

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

When the consumer's install runs, `rules-manager` walks **both** `dependsOn` and
`integratesWith`, finds each provider's `pinhole.json`, and emits one auto-pinhole per
declared port — **only** when:

1. The two modules are in different zones (intra-zone traffic flows freely).
2. The provider's zone is **not already** in the consumer zone's `access-to`
   (`access-to` lists where a zone may go, so that zone-level rule covers it; `"all"`
   covers every zone). Until #770 this read the provider zone's list — the reverse
   direction — which skipped every consumer of a mgmt service as "covered".
3. The consumer's zone **is** in the provider zone's `pinhole-allowed-from`
   (policy gate) — or the provider is a **foundation** module whose `pinhole.json`
   says `"fromZones": "any"`. That exception exists for platform sinks every module
   feeds (today only `logging:logs`, a push-only port into mgmt, #770); it is ignored
   for community modules, so a module cannot widen the zone policy by shipping a file.

If condition 3 fails, the auto-pinhole is **skipped with a warning** — the operator
chose this trade-off on the original ticket: a missing zone policy should not block an
install, just be loud about what wasn't done.

Auto-pinholes are owned by the **consumer**: they're created when the consumer is
installed, recomputed on `reconcile` (so a changed declaration re-applies), and removed
on the consumer's teardown — regardless of the provider's state.

**Hardness and reachability are separate properties (#632).** `dependsOn` and
`integratesWith` differ in LIFECYCLE — whether a missing provider blocks the install —
not in whether traffic may flow. A module can legitimately be optional-but-reachable,
which is exactly what `integratesWith` exists to express, so both lists earn a pinhole
and both are subject to the same three conditions above. Walking only the hard list
meant a cross-zone optional integration got no path; worse, where a module had
previously declared the coordinate as a hard dependency, the rule already in OPNsense
became one nothing declared, and the next `reconcile --apply` pruned it as extra.

The provider is resolved the way the installer resolves it — an environment's own
`<provider>-<env>.json` wins over the shared `<provider>.json` — so a consumer in an
environment reaches the provider deployed alongside it. Looking the provider up by its
bare name silently emitted no rule for an environment-deployed provider, even for a hard
dependency `install-module.sh` had already validated.

### Sequence bands, zone rules and caddy-reach

Where module rules sit among the zone rules — the bands, the evaluation order, what each
zone's baseline holds, the anti-spoofing and admin-guard blocks, and why caddy-reach comes
before the private-network block — is described in one place:
[FIREWALL-RULES.md](../tappaas-cicd/manager/network-manager/FIREWALL-RULES.md).

### Validation

Compile-time, before any OPNsense API call:

1. **Schema** — fields/types match `module-fields.json`.
2. **Zone existence** — every zone-named peer exists in `zones.json`.
3. **Policy** — a rule crossing zones needs the target zone in the source zone's
   `access-to`, or the source zone in the target zone's `pinhole-allowed-from` (a module
   peer counts as its zone; a zone `ingress.from` must be in `pinhole-allowed-from`).
   Ingress from `internet` needs `internet` in the module zone's `pinhole-allowed-from`,
   except for the firewall's own module.
4. **Port consistency** — every `ingress.ports` value is in `module.ports[]`.
5. **Module existence** — every module-named peer has a corresponding `<peer>.json`
   on disk.

A violation is an error: the module's rules are not written, and the message names the
`network-manager modify` command that would allow the path.

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
| `network-manager reconcile` | orchestrator — runs every provider in order (`opnsense → proxmox → switch → ap`) |
| `switch-controller` | physical switches (controllers / switches / ports → trunk + access VLANs) |
| `ap-controller` | WiFi APs (SSID → VLAN via the vendor controller) |
| `proxmox-controller` | node bridge-vids + per-VM trunks |
| `setup-switches.sh` | interactive switch registration (bootstrap step) |
| `setup-wlan-secrets.sh` | set WiFi SSID names (in `zones.json`) + passphrases (0600 secrets file) |

Each provider follows a 5-verb contract (`interrogate → update-desired → delta → apply →
confirm`) over two files in `~/config/`: `switch-configuration-actual.json` (reality) and
`…-desired.json` (regenerated from `zones.json`). Vendor automation is plugin-based
(`scripts/plugins/<vendor>.sh`; `unifi.sh` shipped, `manual.sh` is the by-hand fallback).

**Full command reference, the inventory model, and how to add a switch brand:
[`scripts/README.md`](scripts/README.md).**

## Test network on a dedicated physical port

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

**Restart Unbound only through OPNsense:** `configctl unbound restart` (what TAPPaaS
uses) or `pluginctl -c unbound_start`. Both run OPNsense's `start.sh`, which writes
the config, changes to `/var/unbound` — the DNSBL module is loaded by a relative path —
and starts Unbound on `/var/unbound/unbound.conf`.

**Never `service unbound …`.** The `rc.d` script is the package's, not OPNsense's: it is
not enabled (`restart` refuses), and `onestart`/`onerestart` start a **second** Unbound
on the package's stock config, `/usr/local/etc/unbound/unbound.conf`, next to
OPNsense's. If that happened, stop the stray one and restart through OPNsense:

```sh
pkill -f 'unbound -c /usr/local/etc/unbound/unbound.conf'
configctl unbound restart
```

**DNS down on the firewall** (clients cannot resolve via the gateway): restart as above,
then check `pgrep -lf sbin/unbound` shows one process on `/var/unbound/unbound.conf`.
`unbound-checkconf /var/unbound/unbound.conf` must be run from `/var/unbound`; from any
other directory it reports `pythonmod: can't open file unbound-dnsbl/dnsbl_module.py`
without anything being wrong.

On OPNsense 25.x Unbound was built against Python 3.11 while dnspython existed only for
3.13, so every regenerated config failed to load; since 26.1 both are 3.13.

## Resilience & ingress without a public IP

**Public ingress with no public IP.** The default ingress path terminates at Caddy on the OPNsense
firewall on a routable WAN IP. A site behind CGNAT / dynamic IP / no-inbound instead publishes via a
**satellite** ([ADR-010](../../../docs/ADR/ADR-010-vps-satellite-reverse-proxy-backup.md)): an
operator-owned VPS runs a blind TLS-passthrough reverse-proxy and forwards `:443` over a WireGuard
tunnel to Caddy at home — no commercial tunnel SaaS, and TLS keys stay on-site. The satellite is
optional and non-invasive (a site with a public IP needs none); see the `satellite` foundation module.

**Internet-outage survival.** OPNsense runs a caching recursive resolver (Unbound), so the local
TAPPaaS ecosystem keeps resolving and functioning when the internet link drops (§"Troubleshooting:
Unbound / DNSBL"). Local-network redundancy via B.A.T.M.A.N. was considered but is not implemented.

**Firewall failover.** OPNsense can run active-active (CARP) for firewall HA, but that requires an
Ethernet-connection handover and is **out of scope** for a standard TAPPaaS install; single-firewall
is the supported topology. Node/service HA and disk redundancy are the cluster module's concern —
see `cluster/DESIGN.md` §"High Availability".

## Related files

- [`aliases.json`](aliases.json) — global aliases shared across modules
- [`services/`](services/) — capability lifecycle scripts (proxy, rules, …)
- [`scripts/`](scripts/) — network orchestration (switch-controller,
  ap-controller, setup-*; orchestrated by `network-manager reconcile`) — see
  [`scripts/README.md`](scripts/README.md)
- `tappaas-cicd/controller/opnsense-controller/` — `rules-manager` implementation
- [`../tappaas-cicd/manager/network-manager/ZONES.md`](../tappaas-cicd/manager/network-manager/ZONES.md) — zone reference
- [`../../../docs/ADR/ADR-008-switch-module-network-infrastructure.md`](../../../docs/ADR/ADR-008-switch-module-network-infrastructure.md) — design
- [`../schemas/module-fields.json`](../schemas/module-fields.json) — full field schema
- [`docs/netbird-setup.md`](docs/netbird-setup.md) — netbird remote-management setup
