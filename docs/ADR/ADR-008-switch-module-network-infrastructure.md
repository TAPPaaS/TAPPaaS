# ADR-008: Network Infrastructure Management — Zone Orchestration Across Control Points

**Status:** proposed
**Date:** 2026-06-13 (revised 2026-06-14: orchestrator + per-target provider model)
**Deciders:** @LarsRossen
**Related:** [ADR-001](ADR-001%20-%20Use%20Trunk%20Mode%20for%20TAPPaaS%20VM%20VLAN%20Connectivity.md) (trunk mode for VMs); [zones.json](../../src/foundation/firewall/zones.json) (canonical VLAN definitions); issues [#333], [#334] (inspect-vm trunk visibility), [#335] (firewall VM not trunked on zone add), [#339] (switch management)

---

## Context

TAPPaaS defines network zones in `zones.json`, and the firewall module configures OPNsense to route and firewall between them. But a VLAN/zone is only usable end-to-end when **every layer that touches that VLAN agrees on it** — and today only one of them (OPNsense L3) is reconciled from `zones.json`. Each VLAN passes through several independent **control points**, and a zone change must land on all of them or a guest silently gets no IP:

| Control point | Carries the VLAN as | Managed from `zones.json` today | Gap |
| ----- | ------------------------ | --- | --- |
| OPNsense (L3 routing, DHCP, DNS, firewall) | VLAN interface + DHCP + rules | ✅ `zone-manager` (OPNsense) | — |
| Proxmox VM trunks (firewall VM, future trunk-`ALL` VMs) | `qm set --netN ...,trunks=` | ⚠️ set once at provisioning; **not re-synced on zone add** | **#335** |
| Proxmox node bridges | vlan-aware bridge `bridge-vids` | ⚠️ `config-network` blanket `2-4094`, manual | not automated |
| Physical switches | trunk/access port VLANs | ❌ None | **#339** |
| WiFi access points | SSID → VLAN mapping | ❌ None | **#339** |

Two structural problems follow from this list:

1. **No single thing guarantees convergence.** OPNsense is treated as *the* network and everything else as downstream/manual. There is no orchestrator that takes one `zones.json` change and proves it reached every control point. #335 is the canonical failure: the OPNsense VLAN interface and node bridge are fine, but the firewall VM's static `trunks=` list never got the new VLAN, so the host's vlan-aware bridge drops the guest's tagged frames and DHCP never arrives — the guest VM runs but has no IP, silently.
2. **The control points are not symmetric in the design even though they are symmetric in reality.** OPNsense, Proxmox, switches, and APs are all just consumers of the same desired state. They should each reconcile themselves to `zones.json` through one uniform mechanism.

When a new zone is added to `zones.json` (e.g., a variant zone per ADR-005), the operator today must manually:

1. Update the firewall VM (and any other trunk-`ALL` VM) `qm set --netN trunks=`
2. Confirm the node bridge carries the VLAN
3. Log into each managed switch and add the VLAN; configure trunk and access ports
4. Update the WiFi controller to add/modify SSIDs mapped to the VLAN
5. Document all of this somewhere (usually nowhere)

This is error-prone, undocumented, and violates the "infrastructure as code" principle.

### Goals

1. **Guaranteed convergence** — One `zones.json` change is reconciled onto *every* control point (OPNsense, Proxmox, switches, APs) by a single orchestrator, or the run fails loudly. No control point is privileged; none is left manual-by-default.
2. **Uniform provider contract** — Every control point is reconciled through the same five-verb interface, so OPNsense, Proxmox, switches, and APs are handled symmetrically and can be tested/debugged independently.
3. **Inventory** — Maintain a single source of truth for switching infrastructure: switches, ports, WiFi APs, SSIDs
4. **Documentation** — Know what's connected to each port, what VLANs it carries
5. **Automation** — Push VLAN configuration to supported targets via API (UniFi and MikroTik switches in v1; Proxmox via `qm`/`ip`)

### Non-goals (v1)

- Switch firmware management
- Port security / 802.1X configuration
- Spanning tree tuning

---

## Decision

### 1. Architecture: One Orchestrator, Many Per-Target Providers

`zones.json` is the single source of truth (desired state). Every control point that carries a VLAN is a **provider** that reconciles its own *actual* state to that desired state through one uniform contract. A single **orchestrator** fans a `zones.json` change out to all providers and guarantees they all converge.

This flips the previous mental model — *OPNsense is the network, everything else is downstream* — into *`zones.json` is the network, and OPNsense/Proxmox/switches/APs are all equal consumers of it*. OPNsense stops being the privileged trigger and becomes one provider among four.

```text
                       zones.json   (desired: VLAN ids, types, ACLs, optional SSID)
                            │  single source of truth
        ┌───────────────────┴── zone-manager  (ORCHESTRATOR) ──────────────────┐
        │   validate → run providers (update-desired/interrogate/delta) →        │
        │   present combined plan → apply in dependency order → aggregate report │
        ▼               ▼                  ▼                 ▼                    ▼
  opnsense-manager  proxmox-manager   switch-manager     ap-manager       (future providers)
   L3 / DHCP /      node bridge-vids  physical switch    WiFi SSID →
   DNS / rules      + per-VM trunks=  trunk/access ports VLAN mapping
   OPNsense API     qm / ip link      UniFi / MikroTik   UniFi / …
```

#### Naming

The orchestrator keeps the familiar **`zone-manager`** name (operators keep typing it; it just now reconciles the whole stack instead of only OPNsense). Each control point gets a `‹target›-manager` provider — the bare, target-less word is the orchestrator, a target-prefixed word is a provider:

| Role | Name | Was |
| ---- | ---- | --- |
| **Orchestrator** (operator front door) | **`zone-manager`** | *(new role)* |
| OPNsense L3 reconciler | **`opnsense-manager`** | current `zone-manager` |
| Proxmox L2 reconciler (bridges + VM trunks) | **`proxmox-manager`** | *(new — generalizes `vmnet_sync_firewall_trunks`)* |
| Switch L2 reconciler | `switch-manager` | this ADR |
| WiFi reconciler | `ap-manager` | this ADR |

`zone-manager --only opnsense` reproduces today's narrow OPNsense-only behavior for scripts and tests that need it; an `opnsense` → `zone-manager` alias preserves muscle memory during migration (see §12).

#### Module Location and File Layout

All of this lives in the existing firewall module — L2 (switches, VLANs, WiFi), L3 (OPNsense), and the Proxmox hypervisor trunks are all "network infrastructure":

```
src/foundation/firewall/
├── firewall.json            # Existing module metadata
├── install.sh               # Updated: installs all providers + orchestrator
├── update.sh                # Updated: calls `zone-manager reconcile` (all providers)
├── test.sh                  # Updated: validates config schema + provider contract
├── zones.json               # Existing: canonical VLAN definitions (source of truth)
└── scripts/
    ├── zone-manager         # NEW role: ORCHESTRATOR (fans out to all providers)
    ├── opnsense-manager     # RENAMED from zone-manager: OPNsense L3 provider
    ├── proxmox-manager      # NEW: Proxmox provider (bridge-vids + per-VM trunks=)
    ├── switch-manager       # NEW: physical switch provider
    ├── ap-manager           # NEW: WiFi AP/SSID provider
    └── plugins/             # NEW: vendor automation plugins (switch/AP)
        ├── unifi.sh
        ├── mikrotik.sh
        └── manual.sh        # Fallback: outputs delta to stdout
```

The Proxmox provider reuses the existing [`vmnet_*` helpers](../../src/foundation/cluster/lib/vm-net.sh) (`vmnet_resolve_trunks`, `vmnet_sync_firewall_trunks`); see §8 for its full behavior. The orchestrator coordinates across nodes and runs on `tappaas-cicd`.

#### Decision Point: Rename "firewall" to "network"?

The module currently manages:
- OPNsense firewall VM configuration
- Zone definitions (`zones.json`)
- Zone-to-VLAN mappings
- **NEW:** Cross-stack zone orchestration (`zone-manager`)
- **NEW:** Proxmox bridge + VM-trunk reconciliation (`proxmox-manager`)
- **NEW:** Switch port configuration
- **NEW:** WiFi SSID configuration

- **Option A: Keep as "firewall"** — The OPNsense VM is still the centerpiece; switches/APs are supporting infrastructure.

- **Option B: Rename to "network"** — More accurately describes the full scope; requires renaming `src/foundation/firewall/` → `src/foundation/network/` and updating all references.

**Current decision:** Keep as "firewall" for v1 to avoid churn. Revisit when/if the module grows further.

### 2. Two-File Configuration Model

Switch configuration uses a **desired vs actual** model with two files:

| File | Purpose | Updated by |
| ---- | ------- | ---------- |
| `switch-configuration-desired.json` | What the infrastructure **should** look like | `switch-manager update-desired` (from zones.json, driven by the orchestrator) + manual edits |
| `switch-configuration-actual.json` | What the infrastructure **currently** looks like | `switch-manager` (interrogates switches) |

Both files live in the config directory alongside `zones.json` and `configuration.json`.

```json
{
  "$schema": "switch-inventory-schema.json",
  "version": "1.0",
  "lastUpdated": "2026-06-13T14:30:00Z",

  "switches": {
    "core-switch-1": {
      "uuid": "a1b2c3d4-e5f6-7890-abcd-ef1234567890",
      "vendor": "unifi",
      "model": "USW-Pro-48-PoE",
      "managementIp": "10.0.0.20",
      "location": "rack-1",
      "description": "Core distribution switch",
      "ports": {
        "1": {
          "mode": "trunk",
          "nativeVlan": null,
          "taggedVlans": [0, 200, 210, 220, 230, 310, 320, 410, 420, 610],
          "connectedTo": {
            "type": "node",
            "target": "tappaas1",
            "port": "nic0",
            "interface": "lan"
          },
          "source": "zones",
          "description": "Uplink to tappaas1 (all VLANs)"
        },
        "2": {
          "mode": "trunk",
          "nativeVlan": null,
          "taggedVlans": [0, 200, 210, 220, 230, 310, 320, 410, 420, 610],
          "connectedTo": {
            "type": "node",
            "target": "tappaas2",
            "port": "nic0",
            "interface": "lan"
          },
          "source": "zones",
          "description": "Uplink to tappaas2 (all VLANs)"
        },
        "45": {
          "mode": "access",
          "nativeVlan": 50,
          "taggedVlans": [],
          "connectedTo": {
            "type": "wan",
            "target": "firewall",
            "port": "nic1",
            "interface": "wan"
          },
          "source": "manual",
          "description": "WAN VLAN to firewall (via tappaas1 passthrough)"
        },
        "46": {
          "mode": "access",
          "nativeVlan": 50,
          "taggedVlans": [],
          "connectedTo": {
            "type": "wan",
            "target": "firewall",
            "port": "nic2",
            "interface": "wan-backup"
          },
          "source": "manual",
          "description": "WAN VLAN to firewall (via tappaas2 passthrough)"
        },
        "47": {
          "mode": "access",
          "nativeVlan": 50,
          "taggedVlans": [],
          "connectedTo": {
            "type": "device",
            "target": "wan-modem",
            "mac": "00:11:22:33:44:55"
          },
          "source": "manual",
          "description": "WAN modem uplink (ISP fiber ONT)"
        },
        "48": {
          "mode": "trunk",
          "nativeVlan": null,
          "taggedVlans": [0, 200, 210, 220, 230, 310, 320, 410, 420, 610],
          "connectedTo": {
            "type": "switch",
            "target": "access-switch-1",
            "port": "24"
          },
          "source": "zones",
          "description": "Trunk to access-switch-1 (all VLANs)"
        }
      }
    },
    "access-switch-1": {
      "uuid": "c3d4e5f6-a7b8-9012-cdef-345678901234",
      "vendor": "unifi",
      "model": "USW-24-PoE",
      "managementIp": "10.0.0.21",
      "location": "home-office",
      "description": "Access switch for home office and living room",
      "ports": {
        "1": {
          "mode": "access",
          "zone": "home",
          "nativeVlan": 310,
          "taggedVlans": [],
          "connectedTo": {
            "type": "device",
            "target": "office-printer",
            "mac": "aa:bb:cc:dd:ee:ff"
          },
          "source": "manual",
          "description": "HP LaserJet in home office"
        },
        "2": {
          "mode": "access",
          "zone": "iotCloud",
          "nativeVlan": 420,
          "taggedVlans": [],
          "connectedTo": {
            "type": "device",
            "target": "car-charger",
            "mac": "11:22:33:44:55:66"
          },
          "source": "manual",
          "description": "EV charger (iotCloud VLAN)"
        },
        "12": {
          "mode": "trunk",
          "nativeVlan": null,
          "taggedVlans": [310, 320, 410, 420],
          "connectedTo": {
            "type": "ap",
            "target": "ap-living-room"
          },
          "source": "manual",
          "description": "Trunk to living room AP"
        },
        "24": {
          "mode": "trunk",
          "nativeVlan": null,
          "taggedVlans": [0, 200, 210, 220, 230, 310, 320, 410, 420, 610],
          "connectedTo": {
            "type": "switch",
            "target": "core-switch-1",
            "port": "48"
          },
          "source": "zones",
          "description": "Trunk to core-switch-1 (all VLANs)"
        }
      }
    }
  },

  "accessPoints": {
    "ap-living-room": {
      "uuid": "b2c3d4e5-f6a7-8901-bcde-f23456789012",
      "vendor": "unifi",
      "model": "U6-Pro",
      "managementIp": "10.0.0.30",
      "location": "living-room-ceiling",
      "uplinkSwitch": "access-switch-1",
      "uplinkPort": "12",
      "ssids": {
        "TAPPaaS-Home": {
          "vlan": 310,
          "zone": "home",
          "security": "wpa3-personal",
          "enabled": true
        },
        "TAPPaaS-Work": {
          "vlan": 320,
          "zone": "work",
          "security": "wpa3-enterprise",
          "radiusServer": "identity.mgmt.internal",
          "enabled": true
        },
        "TAPPaaS-IoT": {
          "vlan": 420,
          "zone": "iotCloud",
          "security": "wpa2-personal",
          "enabled": true
        },
        "TAPPaaS-Guest": {
          "vlan": 500,
          "zone": "guest",
          "security": "wpa3-personal",
          "captivePortal": true,
          "enabled": true
        }
      }
    }
  },

  "wifiController": {
    "type": "unifi",
    "url": "https://unifi.mgmt.internal:8443",
    "managedBy": "tappaas-cicd"
  }
}
```

### 3. Port Modes and VLAN Assignment

| Mode | nativeVlan | taggedVlans | Use case |
| ---- | ---------- | ----------- | -------- |
| `access` | Required (VLAN ID) | `[]` | End devices: printers, chargers, cameras |
| `trunk` | Optional (for native VLAN) | List of VLAN IDs | Uplinks to nodes, APs, other switches |

### 4. Connection Types

The `connectedTo` field documents what's on the other end of the cable:

| Type | Target | Port | Interface | Description |
| ---- | ------ | ---- | --------- | ----------- |
| `node` | `tappaas1` | `nic0` | `lan` | Proxmox hypervisor NIC |
| `switch` | Switch name | Port number | — | Inter-switch link |
| `ap` | AP name | — | — | WiFi access point |
| `wan` | `firewall` | `nic1` | `wan` | OPNsense WAN passthrough NIC |
| `device` | Freeform name | — | — | End device (printer, charger, camera) |
| `unused` | `null` | — | — | Port not in use |
| `unknown` | `null` | — | — | Discovered port with connectivity (not yet identified) |

**Field definitions:**

- `type` — Category of connected equipment
- `target` — Hostname or device name
- `port` — Physical port/NIC on the target device (e.g., `nic0`, `nic1`, `1`, `eth0`)
- `interface` — Logical interface name on the target (e.g., `lan`, `wan`, `mgmt`)
- `mac` — (optional) MAC address for device identification

**Example connectedTo objects:**

```json
// Node uplink: switch port 1 → tappaas1's nic0 (lan interface)
"connectedTo": {
  "type": "node",
  "target": "tappaas1",
  "port": "nic0",
  "interface": "lan"
}

// WAN uplink: switch port 47 → firewall's nic1 (wan interface)
"connectedTo": {
  "type": "wan",
  "target": "firewall",
  "port": "nic1",
  "interface": "wan"
}

// Inter-switch link: switch port 48 → access-switch-1 port 1
"connectedTo": {
  "type": "switch",
  "target": "access-switch-1",
  "port": "1"
}

// End device with MAC for identification
"connectedTo": {
  "type": "device",
  "target": "office-printer",
  "mac": "aa:bb:cc:dd:ee:ff"
}
```

### 5. CLI Tools

#### `zone-manager` (orchestrator)

```bash
zone-manager reconcile                       # dry-run: combined plan across ALL providers
zone-manager reconcile --apply               # converge OPNsense + Proxmox + switches + APs (ordered)
zone-manager reconcile --only proxmox        # run a single provider's reconcile
zone-manager reconcile --only opnsense --apply
zone-manager status                          # aggregate drift report across all providers
```

#### `opnsense-manager` (OPNsense L3 provider — renamed from `zone-manager`)

```bash
# Edit zones.json + reconcile OPNsense L3 (VLAN interfaces, DHCP, DNS, firewall rules)
opnsense-manager add <zone> --vlantag 310 --type Client
opnsense-manager reconcile [--apply]         # the old `zone-manager --execute` behavior
```

#### `proxmox-manager` (Proxmox L2 provider)

```bash
proxmox-manager reconcile                    # show node bridge-vids + per-VM trunk drift (dry-run)
proxmox-manager reconcile --apply            # idempotent qm set --netN trunks= for all trunk-bearing VMs
proxmox-manager show <vmname>                # resolved vs actual trunks for one VM (cf. inspect-vm, #334)
```

#### `switch-manager`

```bash
# Inventory management
switch-manager add <name> --vendor unifi --model USW-Pro-48-PoE --ip 10.0.0.20
switch-manager remove <name>
switch-manager list
switch-manager show <name>

# Port configuration
switch-manager port <switch> <port> --mode trunk --tagged 210,220,310,320
switch-manager port <switch> <port> --mode access --native 310
switch-manager port <switch> <port> --connected-to node:tappaas1:lan
switch-manager port <switch> <port> --connected-to device:office-printer --mac aa:bb:cc:dd:ee:ff
switch-manager port <switch> <port> --description "Uplink to tappaas1"

# Reconciliation
switch-manager reconcile                    # Compare inventory against zones.json
switch-manager reconcile --apply            # (future) Push changes to switches
```

#### `ap-manager`

```bash
# AP inventory
ap-manager add <name> --vendor unifi --model U6-Pro --ip 10.0.0.30
ap-manager remove <name>
ap-manager list
ap-manager show <name>

# SSID configuration
ap-manager ssid <ap> add <ssid-name> --vlan 310 --zone home --security wpa3-personal
ap-manager ssid <ap> remove <ssid-name>
ap-manager ssid <ap> list

# Link to switch port
ap-manager link <ap> --switch core-switch-1 --port 24

# Reconciliation
ap-manager reconcile                        # Check SSIDs match zones.json
```

### 6. Five-Phase Reconciliation Process (the Provider Contract)

The five phases below **are the provider contract** from §1 — every provider (`opnsense-manager`, `proxmox-manager`, `switch-manager`, `ap-manager`) implements the same five verbs, and the `zone-manager` orchestrator drives them uniformly. The switch wording is used here because switches are the richest case (vendor plugins, port discovery); for Proxmox the same phases map onto bridge-vids + `qm set --netN trunks=` (see §8), and for OPNsense onto VLAN interfaces / DHCP / rules. Reconciliation is triggered by the orchestrator when `zones.json` changes, or a single provider can be run directly (e.g. `switch-manager reconcile`). It runs in five phases:

```text
┌─────────────────────────────────────────────────────────────────────────────┐
│                         RECONCILIATION PHASES                               │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│  Phase 0: UPDATE DESIRED                                                    │
│  ─────────────────────                                                      │
│  Read zones.json → update switch-configuration-desired.json                 │
│  • Add new VLANs to trunk ports connected to nodes                          │
│  • Add new SSIDs for zones with SSID field                                  │
│  • Remove VLANs/SSIDs for deleted zones                                     │
│  • Skip manual and discovered ports (preserve existing config)              │
│                                                                             │
│  Phase 1: INTERROGATE ACTUAL                                                │
│  ──────────────────────────                                                 │
│  Query switches for current config → update switch-configuration-actual.json│
│  • Retrieves ALL ports on each switch (not just configured ones)            │
│  • Uses vendor plugin (unifi.sh, mikrotik.sh, etc.) if available            │
│  • If no plugin: actual.json is manually maintained                         │
│                                                                             │
│  Phase 2: FIND DELTA                                                        │
│  ───────────────────                                                        │
│  Compare desired vs actual → generate delta                                 │
│  • VLANs to add to trunk ports                                              │
│  • VLANs to remove from trunk ports                                         │
│  • SSIDs to create/update/delete                                            │
│  • Port mode changes (access ↔ trunk)                                       │
│  • Flag unconfigured ports with link UP as DISCOVERED                       │
│                                                                             │
│  Phase 3: CONFIGURE DELTA                                                   │
│  ────────────────────────                                                   │
│  Apply changes to switches                                                  │
│  • If vendor plugin exists: push via API                                    │
│  • If no plugin: output delta to stdout for manual application              │
│  • Discovered ports: no changes applied (informational only)                │
│                                                                             │
│  Phase 4: UPDATE ACTUAL + REGISTER DISCOVERED                               │
│  ────────────────────────────────────────────                               │
│  After successful configuration:                                            │
│  • Update switch-configuration-actual.json to match switch state            │
│  • Register discovered ports in switch-configuration-desired.json           │
│    (source: "discovered") so they persist and appear in future reports      │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

#### Phase 0: Update Desired Configuration

When zones change, the `zone-manager` orchestrator runs each provider's `update-desired` — for the switch provider that is `switch-manager update-desired`:

```bash
# Automatically run by `zone-manager reconcile` after zones.json changes
switch-manager update-desired

# What it does:
# 1. Read zones.json
# 2. For each zone with a vlantag:
#    - Add VLAN to desired taggedVlans for trunk ports connected to nodes
#    - If zone has SSID field, add SSID to desired AP config
# 3. Remove VLANs/SSIDs for zones no longer in zones.json
# 4. Write switch-configuration-desired.json
```

#### Phase 1: Interrogate Actual Configuration

```bash
# Query switches for current configuration
switch-manager interrogate

# Uses vendor plugin if available:
# - plugins/unifi.sh → UniFi Network Controller API
# - plugins/mikrotik.sh → RouterOS API
# - plugins/manual.sh → Skip (actual.json manually maintained)
```

#### Phase 2: Find Delta

Phase 2 performs three types of comparison.

##### 2a. Compare desired vs actual for configured ports

```bash
# Compare desired vs actual
switch-manager delta

# Output example:
# DELTA: core-switch-1
#   Port 1: ADD tagged VLANs [299, 430]
#   Port 24: ADD tagged VLANs [500]
#   Port 10: CHANGE access VLAN 310 → 299 (zone 'home' VLAN changed)
#
# DELTA: ap-living-room
#   ADD SSID: TAPPaaS-Guest (VLAN 500, zone guest, wpa3-personal)
```

##### 2b. Detect access port VLAN changes via zone tracking

Access ports store the **zone name** (not just the VLAN tag) in their configuration. This allows detecting when a zone's VLAN tag changes:

```json
{
  "10": {
    "mode": "access",
    "zone": "home",
    "nativeVlan": 310,
    "connectedTo": { "type": "device", "target": "office-printer" },
    "source": "manual"
  }
}
```

During Phase 0 (`update-desired`), for each access port with a `zone` field:

1. Look up the zone in `zones.json`
2. If `zones.json[zone].vlantag` differs from `nativeVlan`, update `nativeVlan` to match
3. This ensures access ports automatically track zone VLAN reassignments

```text
Phase 2 delta detection for access ports:

For each access port in desired:
  if port.zone exists:
    current_vlan = zones.json[port.zone].vlantag
    if port.nativeVlan != current_vlan:
      → Generate delta: "CHANGE access VLAN {old} → {new} (zone '{zone}' VLAN changed)"
```

##### 2c. Discover unconfigured ports with connectivity

When Phase 1 (`interrogate`) queries the switch, it may find ports that:

- Have link state UP (something is connected)
- Are not in the desired configuration

These are added to the desired configuration as **discovered** ports:

```text
Phase 2 discovery logic:

For each port in actual config:
  if port has link_state == "up" AND port not in desired:
    → Add to desired with source: "discovered"
    → Set mode based on actual config (access/trunk)
    → Set connectedTo: { type: "unknown", target: null }
    → Generate INFO: "DISCOVERED: Port {n} has connectivity but is not configured"
```

##### Discovered port example

```json
{
  "15": {
    "mode": "access",
    "nativeVlan": 1,
    "taggedVlans": [],
    "connectedTo": {
      "type": "unknown",
      "target": null,
      "mac": "aa:bb:cc:dd:ee:ff"
    },
    "source": "discovered",
    "description": "Auto-discovered: unknown device connected"
  }
}
```

The operator should review discovered ports and either:

- Configure them properly: `switch-manager port core-switch-1 15 --connected-to device:new-printer --zone home`
- Mark them as unused: `switch-manager port core-switch-1 15 --connected-to unused`
- Leave as discovered (reconciliation will warn but not change)

##### Delta output with discovery

```text
$ switch-manager delta

DELTA: core-switch-1
  Port 1: ADD tagged VLANs [299, 430]
  Port 10: CHANGE access VLAN 310 → 299 (zone 'home' VLAN changed)

DISCOVERED: core-switch-1
  Port 15: Link UP, MAC aa:bb:cc:dd:ee:ff — not in configuration
    → Added to desired as source: "discovered"
    → Review and configure: switch-manager port core-switch-1 15 --connected-to device:<name>

DELTA: ap-living-room
  ADD SSID: TAPPaaS-Guest (VLAN 500, zone guest, wpa3-personal)
```

#### Phase 3: Configure Delta

```bash
# Apply changes (automated or manual)
switch-manager apply

# With vendor plugin (e.g., UniFi):
#   → Calls UniFi API to configure VLANs and SSIDs
#   → Returns success/failure per switch
#
# Without plugin (manual mode):
#   → Outputs delta to stdout with vendor-specific CLI commands
#   → User applies manually, then runs: switch-manager confirm
```

#### Manual Mode Output Example

When no vendor plugin is available, `switch-manager apply` outputs actionable instructions:

```
╔══════════════════════════════════════════════════════════════════════════════╗
║  MANUAL CONFIGURATION REQUIRED — No plugin for vendor 'generic'              ║
╠══════════════════════════════════════════════════════════════════════════════╣
║                                                                              ║
║  Switch: core-switch-1 (10.0.0.20)                                           ║
║  ────────────────────────────────────────────────────────────────────────────║
║  Port 1 (trunk to tappaas1):                                                 ║
║    Current tagged VLANs: 0, 200, 210, 220, 230, 310, 320, 410, 420, 610      ║
║    Desired tagged VLANs: 0, 200, 210, 220, 230, 299, 310, 320, 410, 420,     ║
║                          430, 500, 610                                       ║
║    ACTION: Add VLANs 299, 430, 500 to trunk                                  ║
║                                                                              ║
║  Port 24 (trunk to ap-living-room):                                          ║
║    Current tagged VLANs: 310, 320, 410, 420                                  ║
║    Desired tagged VLANs: 310, 320, 410, 420, 500                             ║
║    ACTION: Add VLAN 500 to trunk                                             ║
║                                                                              ║
╠══════════════════════════════════════════════════════════════════════════════╣
║  After applying these changes manually, run:                                 ║
║    switch-manager confirm                                                    ║
║  This updates switch-configuration-actual.json to match desired.             ║
╚══════════════════════════════════════════════════════════════════════════════╝
```

#### Phase 4: Update Actual and Register Discovered Ports

Phase 4 performs two tasks:

1. **Update actual config** — After Phase 3 succeeds (automated) or the user confirms (manual), update `switch-configuration-actual.json` to match the current switch state.

2. **Register discovered ports in desired** — Ports found during Phase 1 interrogation that were not already in the desired configuration are registered with `source: "discovered"`.

```bash
# After automated apply succeeds, or after manual confirmation:
switch-manager confirm

# What it does:
# 1. Updates switch-configuration-actual.json to match switch state
# 2. For each port in actual that is not in desired:
#    → Add to switch-configuration-desired.json with source: "discovered"
#    → These ports persist across reconciliations until the operator configures them
```

**Why register discovered ports in desired (not just actual)?**

- Ports in `actual.json` reflect the physical switch state — they are overwritten on each interrogation
- Ports in `desired.json` persist and track operator intent
- By adding discovered ports to `desired.json`, we ensure:
  - They appear in future delta reports until resolved
  - The operator knows about unconfigured devices
  - No configuration is lost if the device temporarily disconnects

```text
Phase 4 logic:

1. Copy switch state to actual.json (for ports with successful apply)
2. For each port in actual.json:
   if port not in desired.json:
     → Add to desired.json with:
       source: "discovered"
       mode: (from actual)
       nativeVlan: (from actual)
       connectedTo: { type: "unknown", mac: (from switch MAC table) }
       description: "Auto-discovered port — review and configure"
3. Write both actual.json and desired.json
```

### 7. Zone-to-SSID Mapping

Zones in `zones.json` can declare an optional `SSID` field:

```json
{
  "home": {
    "type": "Client",
    "vlantag": 310,
    "SSID": "TAPPaaS-Home",
    ...
  }
}
```

The reconcile logic uses this to validate that:
1. An SSID with that name exists on at least one AP
2. The SSID is mapped to the correct VLAN
3. The AP's trunk port carries that VLAN

### 8. Orchestration and the Provider Contract

`zone-manager` is the orchestrator. It owns no control point itself; it reads `zones.json`, runs every provider through the five-verb contract (§6), presents a combined plan, applies in dependency order, and aggregates one report. A run succeeds only when **every** provider's delta is empty — that is what makes "a zone change is guaranteed to reach every layer" true rather than hopeful.

#### The provider contract (five verbs)

Every provider implements the same interface. The orchestrator does not know or care whether a provider talks to the OPNsense API, `qm set`, or a UniFi controller — it just runs the verbs and checks the deltas.

| Verb | Meaning |
| ---- | ------- |
| `update-desired` | Translate `zones.json` → this target's desired shape |
| `interrogate` | Read the target's live *actual* state |
| `delta` | desired − actual (the drift) |
| `apply` | Converge idempotently — or emit manual instructions if no automation exists for this target |
| `confirm` | Persist actual after a successful apply |

`provider reconcile` = run all five in order. `zone-manager reconcile` = run every provider's `reconcile`, ordered.

#### Reconciliation flow

```text
┌─────────────────────────────────────────────────────────────────────────┐
│  1. Operator modifies zones.json (add/remove/update zones)               │
│     (or variant-manager --add-zone does it programmatically)             │
└────────────────────────────────┬────────────────────────────────────────┘
                                 ▼
┌─────────────────────────────────────────────────────────────────────────┐
│  2. zone-manager reconcile  (ORCHESTRATOR)                               │
│     • validate zones.json (schema)                                       │
│     • for each provider: update-desired → interrogate → delta            │
│     • present combined plan (dry-run by default; --apply to converge)    │
│     • apply in dependency order; aggregate per-provider status           │
│     • exit non-zero if ANY provider cannot reach an empty delta          │
└──────┬──────────────┬───────────────────┬────────────────────┬──────────┘
       ▼              ▼                   ▼                    ▼
 opnsense-manager  proxmox-manager   switch-manager       ap-manager
  L3 VLAN iface /  node bridge-vids  trunk/access port    SSID → VLAN
  DHCP / DNS /     + per-VM trunks=  VLANs (UniFi/         (UniFi/…)
  firewall rules   (qm / ip link)    MikroTik plugins)
```

#### Apply order — what actually guarantees a guest gets an IP

A new zone carries traffic end-to-end only when L3 exists **and** the L2 path is unbroken at every hop (switch trunk port → node bridge → VM trunk). The orchestrator applies providers in a fixed dependency order and reverses it for removal, so a live VLAN's gateway is never pulled out from under it:

- **Add:** `opnsense` (gateway + DHCP must exist first) → `proxmox` (bridge-vids + VM trunks) → `switch` (trunk/access ports) → `ap` (SSID).
- **Remove:** `ap` → `switch` → `proxmox` → `opnsense`.

Providers are independent and may run concurrently *within* a phase, but the orchestrator does not declare success until all have converged. A partial failure produces a per-provider status table — no more "the VM is up but silently has no IP."

#### The Proxmox provider (`proxmox-manager`) — closes #335 and the trunk-`ALL` future

`proxmox-manager` owns the two Proxmox control points the layer table (Context) marks unmanaged. It is **data-driven, not firewall-special** — the firewall stops being a hardcoded case:

1. **Per-VM trunks.** It scans every `~/config/*.json` for `trunks0`/`trunks1`, resolves each (including the `ALL`/`*` sentinel) against `zones.json` via [`vmnet_resolve_trunks`](../../src/foundation/cluster/lib/vm-net.sh), and idempotently `qm set --netN`s each NIC — preserving MAC/tag/queues — using the generalized [`vmnet_sync_firewall_trunks`](../../src/foundation/cluster/lib/vm-net.sh) logic. **Any** VM that declares `trunks0=ALL` (today only the firewall; tomorrow others) is reconciled identically. This is the root-cause fix for **#335**: a zone add re-resolves and re-applies trunks for every trunk-bearing VM instead of leaving a stale static list.
2. **Node bridge-vids.** It owns the `bridge-vids` on each node's `lan` bridge. **v1 default is least-privilege**: the bridge carries exactly the active VLAN set from `zones.json` (`vmnet_all_active_tags`), not the blanket `2-4094` that `config-network` writes today. The bridge becomes *managed* state with drift detection, and the bridge stops trunking VLANs no zone uses. Because rewriting a live node's `bridge-vids` (interfaces file + `ifreload`) is disruptive, the bridge-vids **apply is operator-gated** (`proxmox-manager bridge-vids --apply`, run under supervision); `reconcile` reports the drift but does not auto-apply it. Per-VM trunk apply (the #335 fix) is safe/idempotent and runs unguarded.

The per-VM trunk `delta` this provider computes is exactly the trunk-drift comparison surfaced per-VM by `inspect-vm` (**#334**); the orchestrator's combined report is the whole-system version of that inspection.

#### Triggering reconciliation

Reconciliation is triggered by the caller (operator or `variant-manager`), not internally by any single provider — so multiple zone edits batch into one pass:

```bash
# Step 1: Modify zones.json (batch multiple changes; opnsense-manager edits the file)
opnsense-manager add home --vlantag 310 --type Client
opnsense-manager add work --vlantag 320 --type Client

# Step 2: Reconcile the WHOLE stack in one ordered pass
zone-manager reconcile            # dry-run: show combined plan across all providers
zone-manager reconcile --apply    # converge OPNsense + Proxmox + switches + APs

# Scope to one provider when debugging:
zone-manager reconcile --only opnsense
zone-manager reconcile --only proxmox --apply
```

`update.sh` (firewall/network module) and `variant-manager --add-zone` call `zone-manager reconcile --apply` so a zone add lands on every control point automatically.

#### Why an orchestrator rather than provider-calls-provider?

- **Convergence guarantee**: a single component is responsible for "did every layer get it?" — and can fail the run if not.
- **Batching**: many zone edits → one reconcile pass per provider, not one per edit.
- **Independence**: each provider is testable/debuggable in isolation (`--only`), and a new control point is added by writing one more provider — no changes to the others.
- **Consistency**: all providers obey the same five-verb contract and the same dependency ordering.

#### Component Responsibilities

| Component | Role in Reconciliation |
| --------- | ---------------------- |
| `zones.json` | Single source of truth (desired state) — drives every provider |
| `zone-manager` | **Orchestrator** — validate, fan out to all providers, order the apply, aggregate the report, guarantee convergence |
| `opnsense-manager` | Provider — reconciles OPNsense to zones.json (L3: VLAN interfaces, DHCP, DNS, firewall rules). *Renamed from the old `zone-manager`.* |
| `proxmox-manager` | Provider — reconciles Proxmox to zones.json (node `bridge-vids` + per-VM `trunks=` for all trunk-bearing VMs). Fixes #335. |
| `switch-manager` | Provider — reconciles physical switches to zones.json (L2: port VLAN assignments) |
| `ap-manager` | Provider — reconciles APs to zones.json (WiFi: SSID/VLAN mappings) |
| Vendor plugins | Provide automation for specific switch/AP vendors |
| `update-module.sh` | Invokes `zone-manager reconcile --apply` during module updates |

### 9. Port Configuration Sources: Zones, Manual, and Discovered

Port configurations come from three sources, distinguished by the `source` field:

| Source | Value | Description |
| ------ | ----- | ----------- |
| `zones` | Auto-managed | VLANs derived from `zones.json`; updated by `switch-manager update-desired` |
| `manual` | User-managed | Manually configured; preserved during reconciliation |
| `discovered` | Auto-detected | Found during interrogation; pending operator review |

#### How It Works

**Zones-based ports (`source: "zones"`):**

- Automatically updated when `zones.json` changes
- `taggedVlans` is computed from all active zones
- Typically used for **node uplinks** (ports connected to Proxmox hypervisors)
- Phase 0 (`update-desired`) overwrites these ports based on zones.json

**Manual ports (`source: "manual"`):**

- Configured by the operator via `switch-manager port`
- Preserved during `update-desired` — zones.json changes do not modify them
- Used for: WAN uplinks, access ports, AP trunks, inter-switch links, end devices
- Operator is responsible for ensuring correct VLANs

**Discovered ports (`source: "discovered"`):**

- Auto-detected during Phase 1 (interrogate) when a port has connectivity but is not in the desired configuration
- Registered in `desired.json` during Phase 4 so they persist across reconciliations
- Appear in reconciliation output as requiring operator review
- Should be promoted to `manual` or `zones` once the operator identifies the device

#### Full Port Discovery Flow

When `switch-manager reconcile` runs, it discovers **all ports** on each named switch in the inventory:

```text
Phase 1 (Interrogate):
┌─────────────────────────────────────────────────────────────────────────┐
│  For each switch in inventory:                                          │
│    Query switch via vendor plugin (or skip if manual.sh)                │
│    Retrieve ALL ports and their state:                                  │
│      - Port number                                                      │
│      - Mode (access/trunk)                                              │
│      - Native VLAN / Tagged VLANs                                       │
│      - Link state (up/down)                                             │
│      - MAC address table entries (for device identification)            │
│    Write to switch-configuration-actual.json                            │
└─────────────────────────────────────────────────────────────────────────┘

Phase 2 (Delta):
┌─────────────────────────────────────────────────────────────────────────┐
│  Compare actual.json to desired.json:                                   │
│                                                                         │
│  For each port in actual:                                               │
│    if port exists in desired:                                           │
│      → Compare VLAN assignments, mode, etc.                             │
│      → Generate delta if different                                      │
│    if port NOT in desired AND link_state == "up":                       │
│      → Flag as DISCOVERED (pending registration)                        │
│      → Output: "Port N: Link UP, MAC xx:xx:xx — not configured"         │
└─────────────────────────────────────────────────────────────────────────┘

Phase 4 (Update Actual + Register Discovered):
┌─────────────────────────────────────────────────────────────────────────┐
│  After Phase 3 apply succeeds:                                          │
│                                                                         │
│  For each port in actual:                                               │
│    if port NOT in desired:                                              │
│      → Add to desired.json with:                                        │
│          source: "discovered"                                           │
│          connectedTo: { type: "unknown", mac: "..." }                   │
│          description: "Auto-discovered — review and configure"          │
│                                                                         │
│  Write both actual.json and desired.json                                │
└─────────────────────────────────────────────────────────────────────────┘
```

#### Discovered Port Lifecycle

```text
1. DETECTION
   Phase 1 interrogates switch → finds port 15 with link UP
   Port 15 is not in desired.json

2. FLAGGING
   Phase 2 outputs: "DISCOVERED: Port 15, MAC aa:bb:cc:dd:ee:ff"
   No changes applied to switch (discovered ports are informational)

3. REGISTRATION (Phase 4)
   Port 15 added to desired.json with source: "discovered"
   Now persists across future reconciliations

4. OPERATOR ACTION (one of):
   a) Configure as manual:
      switch-manager port core-switch-1 15 \
        --connected-to device:new-printer --zone home --source manual
      → Changes source from "discovered" to "manual"
      → Applies appropriate VLAN

   b) Mark as unused:
      switch-manager port core-switch-1 15 --connected-to unused
      → Changes connectedTo.type to "unused"
      → Stops appearing in discovery warnings

   c) Remove from inventory (device disconnected):
      switch-manager port core-switch-1 15 --remove
      → Removes from desired.json
      → Will be re-discovered if device reconnects

5. SUBSEQUENT RECONCILIATIONS
   If still source: "discovered", appears in output:
   "INFO: Port 15 still unconfigured (discovered) — review recommended"
```

#### Adding Manual Ports

```bash
# Add a manual access port for a printer
switch-manager port core-switch-1 10 \
    --mode access \
    --native 310 \
    --connected-to device:office-printer --mac aa:bb:cc:dd:ee:ff \
    --source manual \
    --description "HP LaserJet in home office"

# Add a manual trunk port for an AP
switch-manager port core-switch-1 24 \
    --mode trunk \
    --tagged 310,320,410,420 \
    --connected-to ap:ap-living-room \
    --source manual \
    --description "Trunk to living room AP"

# Add WAN uplink to firewall
switch-manager port core-switch-1 47 \
    --mode access \
    --connected-to wan:firewall:nic1:wan \
    --source manual \
    --description "WAN uplink to firewall"

# Mark a port as zones-managed (node uplink)
switch-manager port core-switch-1 1 \
    --mode trunk \
    --connected-to node:tappaas1:nic0:lan \
    --source zones \
    --description "Uplink to tappaas1 (all VLANs)"
```

#### Reconciliation Behavior by Source

During Phase 0 (`update-desired`):

```text
For each port in desired config:
  if source == "zones":
    → Recompute taggedVlans from all active zones in zones.json
    → Update the port configuration
  if source == "manual":
    → Skip — preserve existing configuration
  if source == "discovered":
    → Skip — preserve until operator configures
```

During Phase 4 (`update-actual`):

```text
For each port in actual config:
  if port not in desired:
    → Add to desired with source: "discovered"
```

This means:

1. **Adding a new zone** → Automatically adds VLAN to all `source: "zones"` trunk ports
2. **Removing a zone** → Automatically removes VLAN from `source: "zones"` ports
3. **Manual ports unchanged** → Operator must manually update if needed
4. **Discovered ports persist** → Remain in desired.json until operator configures or removes them

#### Validation and Warnings

Reconciliation warns about potential issues:

**Manual port missing VLAN:**

```text
WARNING: Manual port core-switch-1:24 (ap-living-room trunk) missing VLAN 299
  Zone 'acme-corp' (VLAN 299) exists but is not on this manual trunk port.
  If ap-living-room should serve this zone, add VLAN manually:
    switch-manager port core-switch-1 24 --tagged +299
```

**Discovered port pending review:**

```text
INFO: Discovered port core-switch-1:15 still unconfigured
  MAC: aa:bb:cc:dd:ee:ff, Mode: access, VLAN: 1
  Configure: switch-manager port core-switch-1 15 --connected-to device:<name> --zone <zone>
  Or mark unused: switch-manager port core-switch-1 15 --connected-to unused
```

#### Port Source in Data Model

The `source` field is part of the Port Object. All three source types are shown below:

```json
{
  "1": {
    "mode": "trunk",
    "taggedVlans": [0, 200, 210, 220, 230, 310, 320, 410, 420, 610],
    "connectedTo": {
      "type": "node",
      "target": "tappaas1",
      "port": "nic0",
      "interface": "lan"
    },
    "source": "zones",
    "description": "Uplink to tappaas1 (all VLANs)"
  },
  "10": {
    "mode": "access",
    "nativeVlan": 310,
    "connectedTo": {
      "type": "device",
      "target": "office-printer",
      "mac": "aa:bb:cc:dd:ee:ff"
    },
    "source": "manual",
    "description": "HP LaserJet in home office"
  },
  "15": {
    "mode": "access",
    "nativeVlan": 1,
    "taggedVlans": [],
    "connectedTo": {
      "type": "unknown",
      "target": null,
      "mac": "11:22:33:44:55:66"
    },
    "source": "discovered",
    "description": "Auto-discovered port — review and configure"
  }
}
```

### 10. Vendor Plugin Architecture

Each switch/AP vendor can have a plugin that provides automation for that vendor's hardware. Plugins live in `src/foundation/firewall/scripts/plugins/` and implement a standard interface.

#### Plugin Interface

Each plugin is a bash script that implements these functions:

```bash
#!/usr/bin/env bash
# Plugin: unifi.sh — UniFi Network Controller automation

# Called during Phase 1: Interrogate actual configuration
# Outputs JSON to stdout representing current switch/AP state
plugin_interrogate() {
    local switch_name="$1"
    local management_ip="$2"
    # Query UniFi controller API, output JSON
}

# Called during Phase 3: Apply delta
# Returns 0 on success, 1 on failure
plugin_apply() {
    local switch_name="$1"
    local delta_json="$2"
    # Push configuration via UniFi controller API
}

# Returns true if this plugin can manage the given vendor/model
plugin_supports() {
    local vendor="$1"
    local model="$2"
    [[ "$vendor" == "unifi" ]]
}
```

#### Plugin Selection

When `switch-manager` needs to interact with a switch, it selects a plugin based on the `vendor` field:

```bash
# Plugin selection logic
select_plugin() {
    local vendor="$1"
    local model="$2"

    for plugin in plugins/*.sh; do
        if source "$plugin" && plugin_supports "$vendor" "$model"; then
            echo "$plugin"
            return 0
        fi
    done

    # No matching plugin — use manual fallback
    echo "plugins/manual.sh"
}
```

#### Available Plugins

| Plugin | Vendor | Automation | Status |
| ------ | ------ | ---------- | ------ |
| `unifi.sh` | UniFi | Full (Controller API) | v1 |
| `mikrotik.sh` | MikroTik | Full (Direct REST API) | v1 |
| `meraki.sh` | Cisco Meraki | Full (Dashboard API) | Deferred |
| `manual.sh` | Generic/Unknown | None (stdout delta) | v1 |

#### Manual Plugin (Fallback)

The `manual.sh` plugin is the fallback when no vendor-specific plugin exists. It:

1. **Phase 1 (Interrogate):** Returns empty/stale data (actual.json is manually maintained)
2. **Phase 3 (Apply):** Outputs the delta to stdout in human-readable format with vendor-agnostic instructions
3. **Phase 4 (Confirm):** Waits for user to run `switch-manager confirm` after manual application

```bash
# manual.sh — Fallback plugin for unsupported vendors
plugin_interrogate() {
    warn "No automation plugin for this switch — actual config must be maintained manually"
    echo "{}"  # Return empty; user maintains actual.json
}

plugin_apply() {
    local switch_name="$1"
    local delta_json="$2"

    echo "═══════════════════════════════════════════════════════════════"
    echo "  MANUAL CONFIGURATION REQUIRED"
    echo "  Switch: $switch_name"
    echo "═══════════════════════════════════════════════════════════════"
    echo ""
    echo "$delta_json" | jq -r '.changes[] | "  \(.action): \(.description)"'
    echo ""
    echo "  After applying these changes, run: switch-manager confirm"
    echo "═══════════════════════════════════════════════════════════════"

    return 1  # Indicate manual action required
}
```

### 11. Vendor Integration Details

This section documents the specific API integration for each supported vendor.

#### 10.1 UniFi (Controller-Based)

UniFi switches and APs are managed through the **UniFi Network Controller** (or UniFi OS on UDM/UDR devices). The controller exposes an undocumented but stable REST API.

**Architecture:**

```text
┌─────────────────┐     HTTPS/REST      ┌─────────────────────┐
│  switch-manager │ ─────────────────── │  UniFi Controller   │
│  (plugins/      │                     │  (or UniFi OS)      │
│   unifi.sh)     │                     │                     │
└─────────────────┘                     └─────────────────────┘
                                                  │
                                           Adopts/Manages
                                                  │
                              ┌───────────────────┼───────────────────┐
                              ▼                   ▼                   ▼
                        ┌──────────┐        ┌──────────┐        ┌──────────┐
                        │  USW-48  │        │  USW-24  │        │  U6-Pro  │
                        │ (switch) │        │ (switch) │        │  (AP)    │
                        └──────────┘        └──────────┘        └──────────┘
```

**Controller Module:** The UniFi Controller is deployed as a TAPPaaS module (`src/apps/unifi-controller/`) in the `mgmt` zone. It runs in a NixOS VM and manages all UniFi devices.

**API Details:**

| Aspect | Value |
| ------ | ----- |
| Base URL | `https://unifi.mgmt.internal:8443/api` (self-hosted) or `https://<ip>/proxy/network/api` (UniFi OS) |
| Authentication | Cookie-based session (login returns `unifises` and `csrf_token` cookies) |
| Content-Type | `application/json` |
| Documentation | Undocumented; reverse-engineered. See [unifi-api on GitHub](https://github.com/Art-of-WiFi/UniFi-API-client) |

**Key Endpoints:**

```bash
# Login (returns session cookies)
POST /api/login
{"username": "admin", "password": "..."}

# List sites
GET /api/self/sites

# List devices (switches, APs)
GET /api/s/{site}/stat/device

# Get port profiles (VLAN configurations)
GET /api/s/{site}/rest/portconf

# Create port profile
POST /api/s/{site}/rest/portconf
{
  "name": "TAPPaaS-Trunk-All",
  "native_networkconf_id": "",
  "tagged_networkconf_ids": ["id1", "id2", ...],
  "port_security_enabled": false
}

# Apply port profile to switch port
PUT /api/s/{site}/rest/device/{device_id}
{
  "port_overrides": [
    {"port_idx": 1, "portconf_id": "profile_id"}
  ]
}

# List networks (VLANs)
GET /api/s/{site}/rest/networkconf

# Create VLAN network
POST /api/s/{site}/rest/networkconf
{
  "name": "acme-corp",
  "vlan": 299,
  "purpose": "corporate",
  "enabled": true
}

# List WLANs (SSIDs)
GET /api/s/{site}/rest/wlanconf

# Create WLAN
POST /api/s/{site}/rest/wlanconf
{
  "name": "TAPPaaS-Guest",
  "security": "wpapsk",
  "wpa_mode": "wpa3",
  "networkconf_id": "vlan_network_id",
  "enabled": true
}
```

**Plugin Implementation (`plugins/unifi.sh`):**

```bash
#!/usr/bin/env bash
# Plugin: unifi.sh — UniFi Network Controller automation

UNIFI_BASE_URL="${UNIFI_BASE_URL:-https://unifi.mgmt.internal:8443}"
UNIFI_SITE="${UNIFI_SITE:-default}"

# Session management
_unifi_login() {
    local user="$1" pass="$2"
    curl -sSk -c /tmp/unifi-cookies.txt -b /tmp/unifi-cookies.txt \
        -H "Content-Type: application/json" \
        -d "{\"username\":\"$user\",\"password\":\"$pass\"}" \
        "${UNIFI_BASE_URL}/api/login"
}

plugin_supports() {
    [[ "$1" == "unifi" ]]
}

plugin_interrogate() {
    local switch_name="$1"
    # Query controller for device state, extract port configs
    curl -sSk -b /tmp/unifi-cookies.txt \
        "${UNIFI_BASE_URL}/api/s/${UNIFI_SITE}/stat/device" \
        | jq --arg name "$switch_name" '.data[] | select(.name == $name)'
}

plugin_apply() {
    local switch_name="$1" delta_json="$2"
    # Parse delta and call appropriate endpoints
    # ... implementation details ...
}
```

#### 10.2 MikroTik (Direct REST API — No Controller)

MikroTik RouterOS 7.1+ includes a built-in **REST API** that allows direct device management without a central controller. Each switch/router exposes its own API endpoint.

**Architecture:**

```text
┌─────────────────┐     HTTPS/REST      ┌─────────────────┐
│  switch-manager │ ─────────────────── │  MikroTik CRS   │
│  (plugins/      │                     │  (RouterOS 7+)  │
│   mikrotik.sh)  │                     │  REST API       │
└─────────────────┘                     └─────────────────┘

┌─────────────────┐     HTTPS/REST      ┌─────────────────┐
│  switch-manager │ ─────────────────── │  MikroTik hAP   │
│  (plugins/      │                     │  (RouterOS 7+)  │
│   mikrotik.sh)  │                     │  REST API       │
└─────────────────┘                     └─────────────────┘
```

**No Controller Required:** Unlike UniFi, MikroTik devices are managed directly. Each device runs its own REST API server on port 443 (HTTPS) or a custom port.

**Prerequisites:**

1. RouterOS 7.1 or newer
2. REST API service enabled: `/ip/service/set www-ssl disabled=no`
3. API user with appropriate permissions:

   ```routeros
   /user/group/add name=api-group policy=read,write,api,rest-api
   /user/add name=tappaas group=api-group password=...
   ```

**API Details:**

| Aspect | Value |
| ------ | ----- |
| Base URL | `https://<switch-ip>/rest` |
| Authentication | HTTP Basic Auth or session token |
| Content-Type | `application/json` |
| Documentation | [MikroTik REST API Docs](https://help.mikrotik.com/docs/spaces/ROS/pages/47579162/REST+API) |

**Key Endpoints:**

```bash
# List all VLANs
GET /rest/interface/vlan

# Create VLAN
PUT /rest/interface/vlan
{
  "name": "vlan299",
  "vlan-id": 299,
  "interface": "bridge1"
}

# List bridge ports
GET /rest/interface/bridge/port

# Add port to bridge with VLAN filtering
PUT /rest/interface/bridge/port
{
  "interface": "ether1",
  "bridge": "bridge1",
  "pvid": 1,
  "frame-types": "admit-only-vlan-tagged"
}

# Configure VLAN filtering on bridge
PUT /rest/interface/bridge/vlan
{
  "bridge": "bridge1",
  "tagged": "ether1,ether2",
  "vlan-ids": 299
}

# List current VLAN assignments
GET /rest/interface/bridge/vlan

# Delete a VLAN entry
DELETE /rest/interface/bridge/vlan/*{id}

# Get system identity (for verification)
GET /rest/system/identity
```

**Plugin Implementation (`plugins/mikrotik.sh`):**

```bash
#!/usr/bin/env bash
# Plugin: mikrotik.sh — MikroTik RouterOS REST API automation (no controller)

plugin_supports() {
    [[ "$1" == "mikrotik" ]]
}

plugin_interrogate() {
    local switch_name="$1"
    local mgmt_ip="$2"
    local user="${MIKROTIK_USER:-tappaas}"
    local pass="${MIKROTIK_PASS}"

    # Get bridge VLAN configuration
    local vlans bridge_ports
    vlans=$(curl -sSk -u "$user:$pass" "https://${mgmt_ip}/rest/interface/bridge/vlan")
    bridge_ports=$(curl -sSk -u "$user:$pass" "https://${mgmt_ip}/rest/interface/bridge/port")

    # Combine into standardized format
    jq -n --argjson vlans "$vlans" --argjson ports "$bridge_ports" \
        '{vlans: $vlans, ports: $ports}'
}

plugin_apply() {
    local switch_name="$1" delta_json="$2"
    local mgmt_ip="$3"
    local user="${MIKROTIK_USER:-tappaas}"
    local pass="${MIKROTIK_PASS}"

    # Parse delta and apply changes
    echo "$delta_json" | jq -c '.changes[]' | while read -r change; do
        local action=$(echo "$change" | jq -r '.action')
        local vlan_id=$(echo "$change" | jq -r '.vlan_id')
        local ports=$(echo "$change" | jq -r '.ports | join(",")')

        case "$action" in
            add_vlan_to_trunk)
                # Add VLAN to bridge with tagged ports
                curl -sSk -u "$user:$pass" -X PUT \
                    -H "Content-Type: application/json" \
                    -d "{\"bridge\":\"bridge1\",\"tagged\":\"$ports\",\"vlan-ids\":$vlan_id}" \
                    "https://${mgmt_ip}/rest/interface/bridge/vlan"
                ;;
            remove_vlan_from_trunk)
                # Find and delete the VLAN entry
                local vlan_entry_id
                vlan_entry_id=$(curl -sSk -u "$user:$pass" \
                    "https://${mgmt_ip}/rest/interface/bridge/vlan" \
                    | jq -r ".[] | select(.\"vlan-ids\" == \"$vlan_id\") | .\".id\"")
                if [[ -n "$vlan_entry_id" ]]; then
                    curl -sSk -u "$user:$pass" -X DELETE \
                        "https://${mgmt_ip}/rest/interface/bridge/vlan/$vlan_entry_id"
                fi
                ;;
        esac
    done
}
```

#### 10.3 Comparison: Controller vs Direct API

| Aspect | UniFi (Controller) | MikroTik (Direct) |
| ------ | ------------------ | ----------------- |
| Central management | Yes (controller required) | No (each device independent) |
| Single point of failure | Controller is SPOF | No SPOF |
| TAPPaaS module required | Yes (`unifi-controller`) | No |
| Credentials | One set for controller | Per-device credentials |
| Firmware updates | Via controller | Per-device |
| Bulk operations | Easy (one API call) | Loop over devices |
| Device discovery | Automatic (adoption) | Manual inventory |

**Recommendation:** For small deployments (1-3 switches), MikroTik's direct API is simpler. For larger deployments with many UniFi devices, the controller provides better management UX despite the additional module.

#### 10.4 Credentials Management

Both plugins retrieve credentials from TAPPaaS secrets:

```bash
# UniFi credentials (stored in /etc/secrets/unifi-controller.env)
UNIFI_USER="tappaas-admin"
UNIFI_PASS="<from secrets>"
UNIFI_BASE_URL="https://unifi.mgmt.internal:8443"

# MikroTik credentials (stored per-device in /etc/secrets/switches/)
# /etc/secrets/switches/core-switch-1.env
MIKROTIK_USER="tappaas"
MIKROTIK_PASS="<from secrets>"
```

The `switch-manager` loads credentials before calling plugins:

```bash
load_switch_credentials() {
    local switch_name="$1"
    local vendor="$2"

    case "$vendor" in
        unifi)
            source /etc/secrets/unifi-controller.env
            ;;
        mikrotik)
            source "/etc/secrets/switches/${switch_name}.env"
            ;;
    esac
}
```

---

## Data Model Details

### Switch Object

| Field | Type | Required | Description |
| ----- | ---- | :------: | ----------- |
| `uuid` | string | ✅ | Unique identifier (vendor-assigned or generated) |
| `vendor` | string | ✅ | `unifi`, `mikrotik`, `cisco`, `generic` |
| `model` | string | | Hardware model |
| `managementIp` | string | ✅ | IP address for management access |
| `location` | string | | Physical location (rack, room) |
| `description` | string | | Human-readable description |
| `ports` | object | ✅ | Port configurations keyed by port number |

### Port Object

| Field | Type | Required | Description |
| ----- | ---- | :------: | ----------- |
| `mode` | enum | ✅ | `access` or `trunk` |
| `zone` | string | For access | Zone name from zones.json (enables VLAN tracking) |
| `nativeVlan` | int | For access | Untagged VLAN (derived from zone if zone is set) |
| `taggedVlans` | array | For trunk | List of tagged VLAN IDs |
| `connectedTo` | object | | What's on the other end (see Connection Types) |
| `source` | enum | ✅ | `zones`, `manual`, or `discovered` |
| `description` | string | | Human-readable description |
| `poe` | boolean | | PoE enabled (for PoE switches) |

**Source values:**

- `zones` — Auto-managed from zones.json (via `switch-manager update-desired`, driven by the `zone-manager` orchestrator); VLANs updated when zones.json changes
- `manual` — User-configured; preserved during reconciliation
- `discovered` — Auto-added during Phase 2 when port has connectivity but no config

### ConnectedTo Object

| Field | Type | Required | Description |
| ----- | ---- | :------: | ----------- |
| `type` | enum | ✅ | `node`, `switch`, `ap`, `wan`, `device`, `unused`, `unknown` |
| `target` | string | | Hostname or device name (null for `unused`/`unknown`) |
| `port` | string | | Physical port/NIC on target (e.g., `nic0`, `1`) |
| `interface` | string | | Logical interface name (e.g., `lan`, `wan`) |
| `mac` | string | | MAC address (for device identification; often available for `unknown`) |

**Type `unknown`:** Used for discovered ports where something is connected but not yet identified. The MAC address is typically available from the switch's MAC table.

### Access Point Object

| Field | Type | Required | Description |
| ----- | ---- | :------: | ----------- |
| `uuid` | string | ✅ | Unique identifier |
| `vendor` | string | ✅ | `unifi`, `mikrotik`, `generic` |
| `model` | string | | Hardware model |
| `managementIp` | string | | IP address (may be DHCP) |
| `location` | string | | Physical location |
| `uplinkSwitch` | string | | Switch name it's connected to |
| `uplinkPort` | string | | Port number on that switch |
| `ssids` | object | ✅ | SSID configurations |

### SSID Object

| Field | Type | Required | Description |
| ----- | ---- | :------: | ----------- |
| `vlan` | int | ✅ | VLAN ID for this SSID |
| `zone` | string | ✅ | Zone name from zones.json |
| `security` | enum | ✅ | `open`, `wpa2-personal`, `wpa3-personal`, `wpa2-enterprise`, `wpa3-enterprise` |
| `radiusServer` | string | For enterprise | RADIUS server address |
| `captivePortal` | boolean | | Guest portal enabled |
| `enabled` | boolean | ✅ | SSID is active |

---

## 12. Migration: Firewall to Network Module

This ADR proposes expanding the firewall module's scope to include switch and AP management. A logical follow-on is renaming the module from `firewall` to `network` to reflect its broader responsibility. This section documents the migration path.

### 12.1 Rationale for Renaming

The "firewall" module currently manages:

- OPNsense firewall VM (routing, NAT, firewall rules)
- `zones.json` — network zone definitions
- `opnsense-manager` (renamed from `zone-manager`) — OPNsense VLAN and interface configuration
- DNS services (Unbound)
- DHCP services
- Reverse proxy (Caddy)

With ADR-008, it will also manage:

- `zone-manager` orchestration across all control points
- `proxmox-manager` — node bridges + per-VM trunks
- Switch inventory and port configuration
- AP inventory and SSID configuration
- `switch-manager` and `ap-manager` commands

The name "network" better describes this expanded scope.

### 12.2 Files and References to Update

#### Primary Directory Rename

```text
src/foundation/firewall/  →  src/foundation/network/
```

This affects ~60 files including:

| Current Path | New Path |
| ------------ | -------- |
| `src/foundation/firewall/firewall.json` | `src/foundation/network/network.json` |
| `src/foundation/firewall/zones.json` | `src/foundation/network/zones.json` |
| `src/foundation/firewall/update.sh` | `src/foundation/network/update.sh` |
| `src/foundation/firewall/test.sh` | `src/foundation/network/test.sh` |
| `src/foundation/firewall/services/*` | `src/foundation/network/services/*` |

#### Module Catalog Update

In `src/module-catalog.json`:

```json
{
    "moduleName": "network",           // was: "firewall"
    "repo": "foundation",
    "moduleJson": "src/foundation/network/network.json",  // was: firewall/firewall.json
    "vmid": 110,
    "stack": "foundation",
    "category": "platform",
    "status": "stable"
}
```

#### Cross-References in Other Files

Files that reference the firewall module path or name:

| File | Change Required |
| ---- | --------------- |
| `CLAUDE.md` | Update foundation module list |
| `INSTALL.md` | Update installation order documentation |
| `src/foundation/tappaas-cicd/install2.sh` | Update `firewall` references |
| `src/foundation/tappaas-cicd/scripts/apply-zones-merge.sh` | Update path to zones.json |
| `src/foundation/cluster/install.sh` | Update firewall module references |
| `src/apps/*/install.sh` | Any that call `update-module.sh firewall` |
| `.github/workflows/build-opnsense-image.yml` | Update artifact paths if needed |

#### Module JSON Internal References

The `network.json` file itself needs:

```json
{
    "description": "TAPPaaS Network Module (firewall, zones, switches, APs)",
    "vmname": "firewall",      // VM name stays "firewall" (OPNsense hostname)
    "provides": ["firewall", "network", "zones"],
    ...
}
```

Note: The VM name (`vmname`) remains `firewall` because that's the OPNsense VM's hostname. Only the *module* name changes.

#### dependsOn References

Modules that depend on the firewall module:

```bash
# Find all modules that depend on firewall
grep -r '"dependsOn"' src/apps/ src/foundation/ | grep -l firewall
```

These must be updated from `"dependsOn": ["firewall"]` to `"dependsOn": ["network"]`.

### 12.3 Live System Migration Procedure

For systems already running with the `firewall` module installed:

#### Pre-Migration Checklist

```bash
# 1. Ensure clean git state
cd /home/tappaas/TAPPaaS
git status  # should be clean

# 2. Snapshot the firewall VM (rollback point)
snapshot-vm.sh firewall "pre-network-migration"

# 3. Verify firewall is healthy
test-module.sh firewall
```

#### Step 1: Pull the Updated Code

```bash
# On tappaas-cicd
cd /home/tappaas/TAPPaaS
git pull origin main
```

The repository will have:

- `src/foundation/network/` (new location)
- `src/foundation/firewall/` removed
- Updated `module-catalog.json`

#### Step 2: Update Local Symlinks and Paths

The TAPPaaS tooling uses `module-catalog.json` to locate modules. After pulling the updated code:

```bash
# Verify the catalog points to the new location
jq '.foundationModules[] | select(.moduleName == "network")' src/module-catalog.json
```

#### Step 3: Run the Network Module Update

```bash
# The update script handles the transition
update-module.sh network
```

The `network/update.sh` script should detect if it's the first run after migration and:

1. Verify the firewall VM (VMID 110) still exists
2. Confirm OPNsense services are running
3. Update any on-VM paths if needed (none expected — VM internals are unchanged)

#### Step 4: Verify Services

```bash
# Run the test suite
test-module.sh network

# Manual verification
ssh root@firewall.mgmt.internal "configctl unbound status"
ssh root@firewall.mgmt.internal "configctl filter status"
```

#### Step 5: Update Dependent Modules (if any)

If you have custom modules that explicitly depend on "firewall":

```bash
# Find and update
grep -r '"firewall"' src/apps/*/\*.json
# Edit each to change dependsOn from "firewall" to "network"
```

### 12.4 Rollback Procedure

If migration fails:

```bash
# 1. Restore firewall VM from snapshot
restore-vm.sh firewall "pre-network-migration"

# 2. Revert git to previous state
cd /home/tappaas/TAPPaaS
git checkout HEAD~1

# 3. Verify firewall works
test-module.sh firewall
```

### 12.5 Backwards Compatibility

For a transition period, the module catalog can include both names:

```json
{
    "moduleName": "network",
    "aliases": ["firewall"],    // Legacy name still works
    ...
}
```

The `update-module.sh` and `test-module.sh` scripts would resolve aliases before looking up the module. This allows old documentation and muscle memory to keep working.

### 12.6 Timeline Recommendation

| Phase | Action |
| ----- | ------ |
| v0.9 | ADR-008 implemented under `src/foundation/firewall/` |
| v1.0 | Rename to `src/foundation/network/`, add alias support |
| v1.1 | Deprecation warning when using `firewall` alias |
| v2.0 | Remove alias support |

---

## Consequences

### Positive

- **Guaranteed cross-stack convergence** — one orchestrator reconciles a zone change onto OPNsense, Proxmox, switches, and APs, or fails the run. Eliminates the silent "VM up, no IP" class of bug (#335).
- **Symmetric, extensible model** — every control point is a provider behind one five-verb contract; a new layer (e.g. a cloud overlay) is added by writing one more provider.
- **Single source of truth** — `zones.json` drives every layer; the switch/AP inventory is documentation-as-code for the physical network.
- **Proactive validation** — catch VLAN mismatches (e.g. a VM missing a trunk VLAN) before guests lose connectivity; the orchestrator's combined drift report generalizes `inspect-vm` (#334).
- **Foundation for automation** — API-based provisioning can be added incrementally, provider by provider.

### Negative / Risks

- **Orchestrator complexity** — a new coordination layer with ordering and partial-failure semantics to get right.
- **Rename churn** — `zone-manager` → `opnsense-manager` touches scripts/tests/docs; mitigated by the alias and `--only opnsense`.
- **Manual synchronization** — v1 still requires manual switch configuration where no vendor plugin exists.
- **Inventory drift** — Inventory can diverge from reality if not maintained.
- **Vendor lock-in risk** — Deep integration favors UniFi initially.

### Mitigations

- The `zone-manager` orchestrator defaults to dry-run; `--apply` is explicit, and a non-empty delta after apply fails the run.
- `opnsense` → `zone-manager` alias and `--only <provider>` preserve existing behavior/muscle memory during the rename.
- `test.sh` validates inventory schema and warns on potential drift
- `reconcile` output provides copy-pasteable commands for manual application
- Vendor-specific code isolated in provider modules

---

## Implementation Plan

Each sprint is independently shippable. Sprints 0 and 1 deliver the orchestrator + the Proxmox provider, which fix #335 on their own — switch/AP automation (Sprints 2–5) layers on top.

### Sprint 0: Orchestrator + Provider Contract

1. Define the five-verb provider contract (`update-desired`/`interrogate`/`delta`/`apply`/`confirm`) and the `zone-manager` orchestrator skeleton (validate → fan out → ordered apply → aggregate report; dry-run default, `--apply`, `--only <provider>`).
2. Rename the existing `zone-manager` → `opnsense-manager`; add an `opnsense` → `zone-manager` compatibility alias. **No behavior change** — `zone-manager --only opnsense` reproduces today's flow.
3. Wire `update.sh` and `variant-manager --add-zone` to call `zone-manager reconcile --apply`.

### Sprint 1: Proxmox Provider (fixes #335)

1. Implement `proxmox-manager` as a provider over the existing [`vmnet_*` helpers](../../src/foundation/cluster/lib/vm-net.sh).
2. Per-VM trunks: scan `~/config/*.json` for `trunks0`/`trunks1`, resolve (incl. `ALL`) against zones.json, idempotent `qm set --netN` preserving MAC/tag/queues — for **all** trunk-bearing VMs, not just the firewall.
3. Node `bridge-vids` ownership — **least-privilege (active VLAN set from zones.json) is the v1 default**; apply is operator-gated (`bridge-vids --apply`) because it rewrites a live node's interfaces + `ifreload`.
4. `delta` surfaces per-VM trunk drift (the `inspect-vm` view from #334).

> **Naming/migration note:** `zone-manager` is currently the OPNsense reconciler binary, referenced by ~10 scripts/tests and built by the opnsense-controller nix flake. Taking that name for the orchestrator (and renaming the binary → `opnsense-manager`) is the **final, supervised** step of Sprint 0. The orchestrator therefore ships first under the transitional entry point `zone-reconcile`; `opnsense-manager` is added as an additive alias immediately. The `zone-manager` symlink swap + caller migration happens once the orchestrator is proven.

### Sprint 2: Switch Provider — Foundation

1. Add `switch-manager` and `ap-manager` scripts to `src/foundation/firewall/scripts/`
2. Define JSON schema for `switch-configuration-desired.json` and `switch-configuration-actual.json`
3. Implement `switch-manager add/remove/list/show`
4. Implement `switch-manager port` for port configuration
5. Update `firewall/install.sh` to create empty configuration files
6. Create `plugins/manual.sh` fallback plugin

### Sprint 3: AP and SSID Management

1. Implement `ap-manager add/remove/list/show`
2. Implement `ap-manager ssid` subcommands
3. Implement `ap-manager link` for switch-to-AP association
4. Add SSID-to-zone validation

### Sprint 4: Switch Reconciliation Phases

1. Implement Phase 0: `switch-manager update-desired` (zones.json → desired.json)
2. Implement Phase 2: `switch-manager delta` (desired vs actual comparison)
3. Implement Phase 3: `switch-manager apply` with manual.sh fallback
4. Implement Phase 4: `switch-manager confirm`
5. Register `switch-manager` (and `ap-manager`) with the `zone-manager` orchestrator so they run in the ordered reconcile pass

### Sprint 5: Vendor Plugins (v1 scope)

1. Implement Phase 1: `switch-manager interrogate` framework
2. UniFi plugin (`plugins/unifi.sh`) — Network Controller API integration
3. MikroTik plugin (`plugins/mikrotik.sh`) — RouterOS REST API integration (no controller)
4. `switch-manager apply` with automated provisioning via plugins
5. Credentials management integration with `/etc/secrets/`

---

## Test Plan

### Unit Tests (test.sh)

| Test | Description |
| ---- | ----------- |
| SW-01 | `switch-manager add` creates switch entry with required fields |
| SW-02 | `switch-manager port --mode trunk` validates taggedVlans is array |
| SW-03 | `switch-manager port --mode access` requires nativeVlan |
| SW-04 | `switch-manager reconcile` detects VLAN in zones.json missing from trunks |
| SW-05 | `switch-manager reconcile` detects VLAN on switch not in zones.json |
| AP-01 | `ap-manager add` creates AP entry with required fields |
| AP-02 | `ap-manager ssid add` validates zone exists in zones.json |
| AP-03 | `ap-manager link` updates both AP and switch port records |
| AP-04 | `ap-manager reconcile` detects SSID VLAN mismatch |

### Integration Tests (--deep)

| Test | Description |
| ---- | ----------- |
| INT-01 | Add variant zone, run reconcile, verify warning about missing VLAN |
| INT-02 | Add switch, add port, verify inventory persists across module reload |
| INT-03 | Full workflow: add switch, add AP, link, add SSID, reconcile |

---

## Appendix: Example Reconciliation Output

```text
$ switch-manager reconcile

TAPPaaS Switch Infrastructure Reconciliation
=============================================

Comparing switch-inventory.json against zones.json...

ZONES ANALYSIS
--------------
Active zones in zones.json: 14
  mgmt (VLAN 0), srvHome (210), srvWork (220), srvCust (230), home (310),
  work (320), iotLocal (410), iotCloud (420), iotCams (430), guest (500),
  dmz (610), acme-corp (299)

SWITCH ANALYSIS: core-switch-1
------------------------------
Port 1 (trunk to tappaas1):
  ✓ Carries VLANs: 0, 200, 210, 220, 230, 310, 320, 410, 420, 610
  ⚠ MISSING: VLAN 299 (acme-corp) — variant zone not on trunk
  ⚠ MISSING: VLAN 430 (iotCams) — zone not on trunk
  ⚠ MISSING: VLAN 500 (guest) — zone not on trunk

Port 2 (trunk to tappaas2):
  ✓ Carries VLANs: 0, 200, 210, 220, 230, 310, 320, 410, 420, 610
  ⚠ MISSING: VLAN 299 (acme-corp) — variant zone not on trunk
  ⚠ MISSING: VLAN 430 (iotCams) — zone not on trunk
  ⚠ MISSING: VLAN 500 (guest) — zone not on trunk

WIFI ANALYSIS: ap-living-room
-----------------------------
SSID 'TAPPaaS-Home' (VLAN 310 → zone home): ✓ OK
SSID 'TAPPaaS-Work' (VLAN 320 → zone work): ✓ OK
SSID 'TAPPaaS-IoT' (VLAN 420 → zone iotCloud): ✓ OK
SSID 'TAPPaaS-Guest' (VLAN 500 → zone guest): ✓ OK

Uplink port (core-switch-1:24):
  ✓ Carries VLANs: 310, 320, 410, 420
  ⚠ MISSING: VLAN 500 (guest) — SSID configured but VLAN not on trunk

RECOMMENDATIONS
---------------
Run these commands to fix the gaps:

  # Add variant zone VLAN to node uplinks
  switch-manager port core-switch-1 1 --tagged +299
  switch-manager port core-switch-1 2 --tagged +299

  # Add iotCams VLAN to node uplinks (if iotCams VMs will run)
  switch-manager port core-switch-1 1 --tagged +430
  switch-manager port core-switch-1 2 --tagged +430

  # Add guest VLAN to AP trunk
  switch-manager port core-switch-1 24 --tagged +500

Summary: 3 switches, 2 APs, 5 warnings, 0 errors
```

---

## References

- [ADR-001: Trunk Mode for TAPPaaS VM VLAN Connectivity](ADR-001%20-%20Use%20Trunk%20Mode%20for%20TAPPaaS%20VM%20VLAN%20Connectivity.md)
- [zones.json](../../src/foundation/firewall/zones.json) — Canonical VLAN definitions
- [INSTALL-ENVIRONMENT.md](../../INSTALL-ENVIRONMENT.md) — Environment zone L2 troubleshooting
- [UniFi Network Controller API](https://ubntwiki.com/products/software/unifi-controller/api)
