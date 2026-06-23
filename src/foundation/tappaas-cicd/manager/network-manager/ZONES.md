# Zone Definitions in TAPPaaS

## Introduction

`zones.json` defines the security zones of a TAPPaaS installation. Each top-level
key is a zone with its network configuration, access policy, and DHCP settings.
Keys beginning with `_` (e.g. `_README`) are documentation blocks and are ignored
by every consumer.

**network-manager owns the entire zones lifecycle.** It is the single front door
for the network: it does CRUD on `zones.json` (the desired network state),
transforms the distributed template at install, reconciles release drift on every
update, audits consistency, distributes the file to the Proxmox nodes, and
reconciles the four infrastructure planes (OPNsense, Proxmox, switch, access
points) so a zone's VLAN actually reaches the firewall, the hosts, the physical
switch, and the WiFi. There is **no separate `zone-controller`** — the desired-state
authority lives inside network-manager.

Modules connect to zones via their `module.json` (`zone0`, ingress/egress).
The `zones.json` template ships under this directory; the live, per-installation
copy lives at `${TAPPAAS_CONFIG:-/home/tappaas/config}/zones.json`.

> The legacy `variant-manager` and `apply-zones-merge.sh` are **retired**. Variants
> were replaced by ADR-007 **environments** (`config/environments/<env>.json`); the
> bash merge was ported into `network-manager zones-merge` (see below).
> The full design is in the appendix "Zones lifecycle…" sections A–D of
> `docs/design/ADR-007-implementation.md`.

## The zone object

| Field | Meaning |
|-------|---------|
| `type` / `typeId` | Security classification (see below). `typeId` is the numeric band. |
| `state` | Activation state (see below). |
| `subId` | 0–99, identifies the zone within its type band. |
| `vlantag` | VLAN tag. Computed: `typeId * 100 + subId` (0 = untagged). |
| `ip` | Subnet CIDR. Computed: `10.<typeId>.<subId>.0/24`. |
| `bridge` | VLAN trunk interface (`lan` / `wan` / `opt1` / `opt2`). |
| `access-to` | Zones (and `internet`) this zone may reach, subnet-to-subnet. |
| `pinhole-allowed-from` | Zones that may open per-module pinholes into this zone. |
| `DHCP-start` / `DHCP-end` | DHCP range offsets within the subnet (default 50–250). |
| `description` | Human-readable purpose. |
| `SSID` | Optional WiFi network name broadcast on this zone's VLAN. |

Auto-allocated VLANs use the 60–99 window within each type band. Zone keys match
`^[a-z][a-z0-9-]*$` (camelCase template zones like `srvHome`/`iotCams`; renamed
per-installation zones use hyphens, e.g. `myOrg-private`).

### Zone types

| Type | typeId | Purpose |
|------|--------|---------|
| Management | 0 | TAPPaaS nodes and self-management; locked down. Usually one zone, `mgmt`. |
| Service | 2 | Application/service modules. Multiple service zones may exist. |
| Client | 3 | End-user client devices. |
| IoT | 4 | IoT devices (often less secure). |
| Guest | 5 | Untrusted / guest access. |
| DMZ | 6 | Demilitarized zone for controlled-exposure services. |
| Overlay | 7 | Non-VLAN overlay (e.g. NetBird/WireGuard); no interface/DHCP/rules, always `Manual`, `vlantag=0`. Carries its own source CIDR so consumers can resolve it. |

### Zone `state`

| State | Meaning |
|-------|---------|
| **Active** | network-manager creates/maintains the OPNsense interface, DHCP scope, and baseline firewall rules. |
| **Mandatory** | Same as Active; the zone must exist and cannot be disabled. |
| **Inactive** | Defined but **not** provisioned (no interface/DHCP/rules); removed if it exists. The schema default. |
| **Disabled** | Same as Inactive. |
| **Manual** | network-manager neither creates nor removes it — managed externally/by the operator (e.g. `mgmt`, `netbird`). |

## Access Model: Tiers and the Isolation Invariant

Two independent mechanisms control reachability between zones:

| Mechanism | Scope | Set by |
|---|---|---|
| `access-to` | Entire source subnet → entire target subnet | Zone designer, in `zones.json` (baseline) |
| `pinhole-allowed-from` + module `install.sh` | Specific source VM IP → specific port | Module author (runtime) |

Zones are organised into trust tiers:

| Tier | Zones | Default egress | Ingress mechanism |
|---|---|---|---|
| 0 — Control plane | `mgmt` | All zones | No inbound pinholes |
| 1 — Service backends | `srvHome` `srvWork` `srvCust` `srvDev` `srvTest` `dmz` | Internet (+ declared IoT) | Module pinholes via `pinhole-allowed-from` |
| 2 — Trusted clients | `home` `work` | Internet + own service zone | Direct |
| 3 — IoT controlled | `iotLocal` `iotCloud` | `iotCloud`: internet; `iotLocal`: none | Zone-wide from `srvHome`/`home` |
| **4 — IoT isolated** | **`iotCams` `iotUntrust`** | **`iotCams`: none; `iotUntrust`: internet** | **Pinhole-only — no exceptions** |
| 5 — Untrusted clients | `guest` | Internet only | No inbound pinholes |

**Isolation invariant.** Tier-4 zones (`iotCams`, `iotUntrust`) have
`"access-to": []` and **must never appear in any zone's `access-to`**. Access
into them is granted only by per-module pinhole declaration. Adding an isolation
zone to a non-`mgmt` `access-to` would nullify the pinhole mechanism — every host
in the source subnet would gain unconditional zone-wide reach. `iotCams` in
particular must stay purpose-limited (GDPR Art. 25). The sole exception is
`mgmt` (Tier-0 control plane), which reaches all zones for operational visibility.

Access matrix (`✅` access-to · `🔓` pinhole-only · `❌` deny):

| → | internet | srvHome | srvWork | srvCust | iotLocal | iotCloud | iotCams | iotUntrust |
|---|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|
| `mgmt` | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| `srvHome` | ✅ | — | ❌ | ❌ | ✅ | ✅ | 🔓 | ❌ |
| `srvWork` | ✅ | ❌ | — | ❌ | ❌ | ❌ | 🔓 | ❌ |
| `home` | ✅ | ✅ | ❌ | ❌ | ✅ | ✅ | ❌ | ❌ |
| `work` | ✅ | ❌ | ✅ | ❌ | ❌ | ❌ | ❌ | ❌ |
| `guest` | ✅ | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ |

The canonical, machine-adjacent version of this model — including the PR review
checklist, mDNS policy, and IoT classification decision aid — lives in the
`_README` block at the top of [`zones.json`](zones.json). Keys beginning with `_`
are documentation and are ignored by all consumers.

## network-manager commands (the zones lifecycle)

One compiled CLI, `network-manager`, owns every flow that touches `zones.json`:

| Command | Purpose |
|---------|---------|
| `zone list` / `zone exists <n>` / `zone get <n>` | Read CRUD on `zones.json`. |
| `zone add <n> [--from-zone S] [--vlan N] [--check]` | Author a new zone **and reconcile all four planes** (so the VLAN reaches everything). `--from-zone` inherits type/bridge/access. |
| `zone delete <n> [--check]` | Disable the zone, reconcile all planes, then drop the key. |
| `reconcile [--apply] [--only <plane>]` | The 4-plane converge loop — `opnsense \| proxmox \| switch \| ap`. Default is a non-mutating dry-run (exit 2 = drift). |
| `zones-init --name <N>` | Install-time template transform (the per-installation rename, see below). |
| `zones-merge [--diff]` | Rename-aware 3-way reconciliation against the upstream template; run on every `update-tappaas` (replaces `apply-zones-merge.sh`). |
| `zones-check [--strict]` | Offline consistency audit (dangling refs, missing fields, lost zones). |
| `zones-distribute [--dry-run]` | Push the live `zones.json` to every Proxmox node so VMs can be created in its zones. |

`environment-manager` calls `network-manager` when an environment needs a zone
created or checked; domain/cert lifecycle stays with `environment-manager`.

## The per-installation rename and the three-file model

The distributed template encodes the generic, org-agnostic zones (`srv`, `home`,
`guest`, the per-category `srvHome`/`srvWork`/… etc.). A fresh install runs
`network-manager zones-init --name <N>` once to stamp the zones for the
installation named `<N>`:

- **rename** `srv` → `<N>` (forced **Active** — the default service zone),
  `home` → `<N>-private`, `guest` → `<N>-guest`;
- **state → Inactive** on the per-category zones it supersedes (`srvHome`,
  `srvWork`, `srvCust`, `srvDev`, `work`), **except** any zone still referenced by
  a deployed module's `zone0` (the occupancy guard, so a live service is never
  silently de-provisioned);
- **rewrite every zone-name reference** (`access-to`, `pinhole-allowed-from`, …)
  through the rename map.

So a brand-new `myOrg` system has an Active footprint of `myOrg`, `myOrg-private`,
`myOrg-guest`, `iotLocal`, `iotCloud`, `iotCams` (+ `dmz` Mandatory; `mgmt`/`netbird`
Manual); everything else is Inactive/Disabled — defined, ready to activate.

### Three files, run on every update (rename-aware 3-way merge)

Keeping the rename robust across releases uses three files in `${CONFIG_DIR}`,
all in the installation's renamed namespace:

- **`zones.json`** — *current*: the live, per-installation zones.
- **`zones.json.orig`** — *baseline*: the version of the source the current was
  last merged from.
- **`zones.rename.json`** — *source*: the upstream repo template **with this
  installation's rename applied** (regenerated on demand from `site.json .name`;
  never hand-edited).

`network-manager zones-merge` runs on every `update-tappaas`:

1. read the current repo template → apply the same rename algorithm → (re)write
   `zones.rename.json` (re-basing upstream changes into the renamed namespace);
2. 3-way merge *current* vs *baseline* vs *source* — per field: `state` is
   **operator-pinned, never adopted**; every other field adopts the source when
   `current == orig`, else the local edit wins. Zone-level: source-only → **ADD**;
   current-only → **keep + warn**; same `vlantag` / different name → **flag a
   possible rename (do not auto-rename)**;
3. write merged → `zones.json` and **advance `zones.json.orig` ← `zones.rename.json`**.

Because `srv`/`home`/`guest` never appear in `zones.rename.json` (they are renamed
away), the "source-only → ADD" rule can never re-create them — which is what
closes the recurring duplicate-VLAN corruption the old `apply-zones-merge.sh` had.

## Example Configuration

```json
{
    "mgmt": {
        "type": "Management",
        "state": "Manual",
        "typeId": "0",
        "subId": "0",
        "vlantag": 0,
        "ip": "10.0.0.0/24",
        "bridge": "lan",
        "access-to": ["internet", "srvHome", "srvWork", "home", "dmz"],
        "pinhole-allowed-from": [],
        "description": "Control plane: hypervisors, backup, firewall, identity, cicd"
    },
    "srvHome": {
        "type": "Service",
        "state": "Active",
        "typeId": "2",
        "subId": "10",
        "vlantag": 210,
        "ip": "10.2.10.0/24",
        "bridge": "lan",
        "access-to": ["internet", "iotCloud", "iotLocal"],
        "pinhole-allowed-from": [],
        "description": "Personal services: home automation, personal apps"
    },
    "iotCams": {
        "type": "IoT",
        "state": "Active",
        "typeId": "4",
        "subId": "30",
        "vlantag": 430,
        "ip": "10.4.30.0/24",
        "bridge": "lan",
        "access-to": [],
        "pinhole-allowed-from": ["srvHome", "srvWork"],
        "description": "Surveillance: cameras + NVR, fully isolated"
    }
}
```

Note `iotCams.access-to` is `[]`: an NVR in `srvHome`/`srvWork` reaches the
cameras only through an explicit per-module pinhole, never via `access-to`.

## Computed Values

- **vlantag**: `typeId * 100 + subId` (e.g. typeId=2, subId=10 → 210)
- **ip**: `10.<typeId>.<subId>.0/24` (e.g. typeId=2, subId=10 → 10.2.10.0/24)

## WiFi: the `SSID` field

A zone may declare an optional `SSID` field — the WiFi network name broadcast on
that zone's VLAN. It is consumed by the ADR-008 WiFi tooling (see
[`firewall/scripts/README.md`](../../../firewall/scripts/README.md)):

- **`setup-wlan-secrets.sh`** walks the active zones that declare an `SSID`, lets
  you set the real name (replacing the shipped `<PLACEHOLDER>`), and stores the
  WPA passphrase in a 0600 secrets file (never in `zones.json`).
- **`ap-manager`** maps each SSID to its zone's VLAN on the WiFi controller.

The passphrase and per-SSID security level are **not** stored here — only the
SSID name and (via `vlantag`) its VLAN.

## Field Reference

For complete field definitions including all possible values, defaults, and
validation rules, see
[`schemas/zones-fields.json`](../../../schemas/zones-fields.json):
all available fields and their types, valid values for enumerated fields
(including the `state` enum), defaults, computed-field formulas, and the special
access-control values.

## Per-Module Firewall Rules

Zone-level rules govern coarse access between zones. **Per-module** rules
(`firewall:rules` capability) declare each module's ingress/egress contract in
its own JSON and are validated against the zone-level policy:

- Every `ingress.from` zone must be in the destination zone's `pinhole-allowed-from`.
- Egress to a zone not in the source zone's `access-to` is permitted but warned.

A peer that is **another module's name** is resolved via an OPNsense host alias
populated with the peer's FQDN (`<vmname>.<zone0>.internal`), kept fresh by
OPNsense Unbound against dnsmasq — DHCP IP changes do not require rule rewrites.

See [`firewall/README.md`](../../../firewall/README.md) for the full schema,
sequence bands, and CLI reference.
