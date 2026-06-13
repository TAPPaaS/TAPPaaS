# ADR-008: Switch Module — Network Infrastructure Management

**Status:** proposed
**Date:** 2026-06-13
**Deciders:** @LarsRossen
**Related:** [ADR-001](ADR-001%20-%20Use%20Trunk%20Mode%20for%20TAPPaaS%20VM%20VLAN%20Connectivity.md) (trunk mode for VMs); [zones.json](../../src/foundation/firewall/zones.json) (canonical VLAN definitions)

---

## Context

TAPPaaS defines network zones in `zones.json`, and the firewall module configures OPNsense to route and firewall between them. But **the physical layer — switches and WiFi access points — is currently unmanaged**:

| Layer | Managed by TAPPaaS today | Gap |
| ----- | ------------------------ | --- |
| L3 routing + firewall | OPNsense (firewall module) | ✅ |
| L2 VLANs on firewall VM | `qm set` trunk config | ✅ (ADR-001) |
| L2 VLANs on Proxmox bridges | `config-network` (manual) | ⚠️ Documented, not automated |
| **L2 VLANs on physical switches** | **None** | ❌ Manual |
| **WiFi SSIDs → VLANs** | **None** | ❌ Manual |

When a new zone is added to `zones.json` (e.g., a variant zone per ADR-005), the operator must:

1. Log into each managed switch and add the VLAN
2. Configure trunk ports to carry the new VLAN
3. Configure access ports if devices need to terminate on that VLAN
4. Update WiFi controller to add/modify SSIDs mapped to the VLAN
5. Document all of this somewhere (usually nowhere)

This is error-prone, undocumented, and violates the "infrastructure as code" principle.

### Goals

1. **Inventory** — Maintain a single source of truth for switching infrastructure: switches, ports, WiFi APs, SSIDs
2. **Documentation** — Know what's connected to each port, what VLANs it carries
3. **Reconciliation** — When `zones.json` changes, identify what switch/WiFi config changes are needed
4. **Automation** — Push VLAN configuration to supported switches via API (UniFi and MikroTik in v1)

### Non-goals (v1)

- Switch firmware management
- Port security / 802.1X configuration
- Spanning tree tuning

---

## Decision

### 1. Switch Management is Part of the Firewall Module

Switch and WiFi management is **integrated into the existing firewall module**, not a separate module. This reflects that L2 (switches, VLANs, WiFi) and L3 (OPNsense routing/firewall) are both "network infrastructure":

- Lives at `src/foundation/firewall/` (existing module)
- New CLI tools added: `switch-manager`, `ap-manager`
- Triggered automatically by `zone-manager` when `zones.json` changes
- Maintains configuration in `~/config/switch-configuration-desired.json` and `~/config/switch-configuration-actual.json`

```
src/foundation/firewall/
├── firewall.json            # Existing module metadata
├── install.sh               # Updated: also installs switch/ap-manager
├── update.sh                # Updated: calls zone-manager reconciliation
├── test.sh                  # Updated: validates switch config schema
├── zones.json               # Existing: canonical VLAN definitions
└── scripts/
    ├── zone-manager         # Existing: now triggers switch reconciliation
    ├── switch-manager       # NEW: CLI for switch/port configuration
    ├── ap-manager           # NEW: CLI for WiFi AP/SSID configuration
    └── plugins/             # NEW: vendor automation plugins
        ├── unifi.sh
        ├── mikrotik.sh
        └── manual.sh        # Fallback: outputs delta to stdout
```

#### Decision Point: Rename "firewall" to "network"?

The module currently manages:
- OPNsense firewall VM configuration
- Zone definitions (`zones.json`)
- Zone-to-VLAN mappings
- **NEW:** Switch port configuration
- **NEW:** WiFi SSID configuration

- **Option A: Keep as "firewall"** — The OPNsense VM is still the centerpiece; switches/APs are supporting infrastructure.

- **Option B: Rename to "network"** — More accurately describes the full scope; requires renaming `src/foundation/firewall/` → `src/foundation/network/` and updating all references.

**Current decision:** Keep as "firewall" for v1 to avoid churn. Revisit when/if the module grows further.

### 2. Two-File Configuration Model

Switch configuration uses a **desired vs actual** model with two files:

| File | Purpose | Updated by |
| ---- | ------- | ---------- |
| `switch-configuration-desired.json` | What the infrastructure **should** look like | `zone-manager` (from zones.json) + manual edits |
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
        "10": {
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
        "24": {
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
        "47": {
          "mode": "access",
          "nativeVlan": null,
          "taggedVlans": [],
          "connectedTo": {
            "type": "wan",
            "target": "firewall",
            "port": "nic1",
            "interface": "wan"
          },
          "source": "manual",
          "description": "WAN uplink to firewall"
        },
        "48": {
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
      "uplinkSwitch": "core-switch-1",
      "uplinkPort": "24",
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

### 6. Five-Phase Reconciliation Process

Reconciliation is triggered automatically when `zone-manager` modifies `zones.json`, or can be run manually via `switch-manager reconcile`. It runs in five phases:

```
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
│                                                                             │
│  Phase 1: INTERROGATE ACTUAL                                                │
│  ──────────────────────────                                                 │
│  Query switches for current config → update switch-configuration-actual.json│
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
│                                                                             │
│  Phase 3: CONFIGURE DELTA                                                   │
│  ────────────────────────                                                   │
│  Apply changes to switches                                                  │
│  • If vendor plugin exists: push via API                                    │
│  • If no plugin: output delta to stdout for manual application              │
│                                                                             │
│  Phase 4: UPDATE ACTUAL                                                     │
│  ──────────────────────                                                     │
│  After successful configuration, update switch-configuration-actual.json    │
│  • Only runs if Phase 3 succeeded (automated) or user confirms (manual)     │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

#### Phase 0: Update Desired Configuration

When `zone-manager` adds/removes zones, it calls `switch-manager update-desired`:

```bash
# Automatically called by zone-manager after zones.json changes
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

#### Phase 4: Update Actual

```bash
# After automated apply succeeds, or after manual confirmation:
switch-manager confirm

# Updates switch-configuration-actual.json to match desired
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

### 8. Integration with zone-manager

When `zone-manager` modifies `zones.json`, it automatically triggers switch reconciliation:

```bash
# Inside zone-manager after modifying zones.json:
zone-manager add home --vlantag 310 --type Client

# zone-manager internally calls:
switch-manager update-desired    # Phase 0: update desired config from zones.json
switch-manager reconcile         # Phases 1-4: interrogate, delta, apply, confirm
```

This ensures that:

1. Adding a new zone immediately identifies which switch ports need the new VLAN
2. Removing a zone warns about orphaned VLANs on switches
3. The operator gets immediate feedback about L2 infrastructure changes needed

| Component | Role in Reconciliation |
| --------- | ---------------------- |
| `zones.json` | Source of truth for VLANs — drives desired configuration |
| `zone-manager` | Triggers reconciliation after zone changes |
| `switch-manager` | Manages switch inventory and runs reconciliation phases |
| `ap-manager` | Manages AP/SSID inventory; called by switch-manager for WiFi changes |
| Vendor plugins | Provide automation for specific switch/AP vendors |

### 9. Manual vs Zones-Based Port Configuration

Port configurations come from two sources, distinguished by the `source` field:

| Source | Value | Description |
| ------ | ----- | ----------- |
| `zones` | Auto-managed | VLANs derived from `zones.json`; updated by `switch-manager update-desired` |
| `manual` | User-managed | Manually configured; preserved during reconciliation |

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

#### Reconciliation Behavior

During Phase 0 (`update-desired`):

```text
For each port in desired config:
  if source == "zones":
    → Recompute taggedVlans from all active zones in zones.json
    → Update the port configuration
  if source == "manual":
    → Skip — preserve existing configuration
```

This means:

1. **Adding a new zone** → Automatically adds VLAN to all `source: "zones"` trunk ports
2. **Removing a zone** → Automatically removes VLAN from `source: "zones"` ports
3. **Manual ports unchanged** → Operator must manually update if needed

#### Validation and Warnings

Reconciliation warns about potential issues with manual ports:

```text
WARNING: Manual port core-switch-1:24 (ap-living-room trunk) missing VLAN 299
  Zone 'acme-corp' (VLAN 299) exists but is not on this manual trunk port.
  If ap-living-room should serve this zone, add VLAN manually:
    switch-manager port core-switch-1 24 --tagged +299
```

#### Port Source in Data Model

The `source` field is part of the Port Object:

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

- `zones` — Auto-managed by zone-manager; VLANs updated when zones.json changes
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
- `zone-manager` — VLAN and interface configuration
- DNS services (Unbound)
- DHCP services
- Reverse proxy (Caddy)

With ADR-008, it will also manage:

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

- **Single source of truth** for switching infrastructure
- **Documentation as code** — the inventory describes the physical network
- **Proactive validation** — catch VLAN mismatches before guests lose connectivity
- **Foundation for automation** — API-based provisioning can be added incrementally

### Negative / Risks

- **Manual synchronization** — v1 requires manual switch configuration
- **Inventory drift** — Inventory can diverge from reality if not maintained
- **Vendor lock-in risk** — Deep integration favors UniFi initially

### Mitigations

- `test.sh` validates inventory schema and warns on potential drift
- `reconcile` output provides copy-pasteable commands for manual application
- Vendor-specific code isolated in provider modules

---

## Implementation Plan

### Sprint 1: Foundation

1. Add `switch-manager` and `ap-manager` scripts to `src/foundation/firewall/scripts/`
2. Define JSON schema for `switch-configuration-desired.json` and `switch-configuration-actual.json`
3. Implement `switch-manager add/remove/list/show`
4. Implement `switch-manager port` for port configuration
5. Update `firewall/install.sh` to create empty configuration files
6. Create `plugins/manual.sh` fallback plugin

### Sprint 2: AP and SSID Management

1. Implement `ap-manager add/remove/list/show`
2. Implement `ap-manager ssid` subcommands
3. Implement `ap-manager link` for switch-to-AP association
4. Add SSID-to-zone validation

### Sprint 3: Reconciliation Phases

1. Implement Phase 0: `switch-manager update-desired` (zones.json → desired.json)
2. Implement Phase 2: `switch-manager delta` (desired vs actual comparison)
3. Implement Phase 3: `switch-manager apply` with manual.sh fallback
4. Implement Phase 4: `switch-manager confirm`
5. Integrate with `zone-manager` to trigger full reconciliation on zone changes

### Sprint 4: Vendor Plugins (v1 scope)

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
- [INSTALL-VARIANT.md](../../INSTALL-VARIANT.md) — Variant zone L2 troubleshooting
- [UniFi Network Controller API](https://ubntwiki.com/products/software/unifi-controller/api)
