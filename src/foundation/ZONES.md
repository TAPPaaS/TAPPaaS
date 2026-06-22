# Zone Definitions in TAPPaaS

## Introduction

The `zones.json` file defines the security zones of a TAPPaaS installation. Each record in the JSON defines a zone with its network configuration, access policies, and DHCP settings.

Individual TAPPaaS modules are connected to zones based on their respective `module.json` configuration. During firewall and tappaas-cicd installation, administrators can modify a copy of the zones file to customize their deployment.

The zone-manager tool reads `zones.json` and configures:
- VLAN interfaces on the firewall
- DHCP ranges for each zone
- Firewall rules based on access policies (when run with `--firewall-rules`)

## Zone Types

TAPPaaS defines six zone types, each with a specific security purpose:

| Type | typeId | Purpose |
|------|--------|---------|
| Management | 0 | TAPPaaS infrastructure and self-management |
| Service | 2 | Application and service modules |
| Client | 3 | End-user client devices |
| IoT | 4 | IoT devices (often less secure) |
| Guest | 5 | Untrusted guest access |
| DMZ | 6 | Demilitarized zone for exposed services |

> Zone keys use underscores, not hyphens (`srv_home`, `iot_cams`) — they are the
> single source of truth and must match their downstream consumers verbatim
> (OPNsense interface labels, UniFi VLAN/port-profile names). See issue #237.

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
| 1 — Service backends | `srv_home` `srv_work` `srv_cust` `srv_dev` `srv_test` `dmz` | Internet (+ declared IoT) | Module pinholes via `pinhole-allowed-from` |
| 2 — Trusted clients | `home` `work` | Internet + own service zone | Direct |
| 3 — IoT controlled | `iot_local` `iot_cloud` | `iot_cloud`: internet; `iot_local`: none | Zone-wide from `srv_home`/`home` |
| **4 — IoT isolated** | **`iot_cams` `iot_untrust`** | **`iot_cams`: none; `iot_untrust`: internet** | **Pinhole-only — no exceptions** |
| 5 — Untrusted clients | `guest` | Internet only | No inbound pinholes |

**Isolation invariant.** Tier-4 zones (`iot_cams`, `iot_untrust`) have
`"access-to": []` and **must never appear in any zone's `access-to`**. Access
into them is granted only by per-module pinhole declaration. Adding an isolation
zone to a non-`mgmt` `access-to` would nullify the pinhole mechanism — every host
in the source subnet would gain unconditional zone-wide reach. `iot_cams` in
particular must stay purpose-limited (GDPR Art. 25). The sole exception is
`mgmt` (Tier-0 control plane), which reaches all zones for operational visibility.

Access matrix (`✅` access-to · `🔓` pinhole-only · `❌` deny):

| → | internet | srv_home | srv_work | srv_cust | iot_local | iot_cloud | iot_cams | iot_untrust |
|---|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|
| `mgmt` | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| `srv_home` | ✅ | — | ❌ | ❌ | ✅ | ✅ | 🔓 | ❌ |
| `srv_work` | ✅ | ❌ | — | ❌ | ❌ | ❌ | 🔓 | ❌ |
| `home` | ✅ | ✅ | ❌ | ❌ | ✅ | ✅ | ❌ | ❌ |
| `work` | ✅ | ❌ | ✅ | ❌ | ❌ | ❌ | ❌ | ❌ |
| `guest` | ✅ | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ |

The canonical, machine-adjacent version of this model — including the PR review
checklist, mDNS policy, and IoT classification decision aid — lives in the
`_README` block at the top of [`firewall/zones.json`](firewall/zones.json). Keys
beginning with `_` are documentation and are ignored by all consumers.

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
        "access-to": ["internet", "srv_home", "srv_work", "home", "dmz"],
        "pinhole-allowed-from": [],
        "description": "Control plane: hypervisors, backup, firewall, identity, cicd"
    },
    "srv_home": {
        "type": "Service",
        "state": "Active",
        "typeId": "2",
        "subId": "10",
        "vlantag": 210,
        "ip": "10.2.10.0/24",
        "bridge": "lan",
        "access-to": ["internet", "iot_cloud", "iot_local"],
        "pinhole-allowed-from": [],
        "description": "Personal services: home automation, personal apps"
    },
    "iot_cams": {
        "type": "IoT",
        "state": "Active",
        "typeId": "4",
        "subId": "30",
        "vlantag": 430,
        "ip": "10.4.30.0/24",
        "bridge": "lan",
        "access-to": [],
        "pinhole-allowed-from": ["srv_home", "srv_work"],
        "description": "Surveillance: cameras + NVR, fully isolated"
    }
}
```

Note `iot_cams.access-to` is `[]`: an NVR in `srv_home`/`srv_work` reaches the
cameras only through an explicit per-module pinhole, never via `access-to`.

## Computed Values

Several zone fields can be computed from others:

- **vlantag**: `typeId * 100 + subId` (e.g., typeId=2, subId=10 → vlantag=210)
- **ip**: `10.typeId.subId.0/24` (e.g., typeId=2, subId=10 → 10.2.10.0/24)

## WiFi: the `SSID` field

A zone may declare an optional `SSID` field — the WiFi network name broadcast on
that zone's VLAN. It is consumed by the ADR-008 WiFi tooling (see
[`firewall/scripts/README.md`](firewall/scripts/README.md)):

- **`setup-wlan-secrets.sh`** walks the active zones that declare an `SSID`, lets
  you set the real name (replacing the shipped `<PLACEHOLDER>`), and stores the
  WPA passphrase in a 0600 secrets file (never in `zones.json`).
- **`ap-manager`** maps each SSID to its zone's VLAN on the WiFi controller.

The passphrase and per-SSID security level are **not** stored here — only the
SSID name and (via `vlantag`) its VLAN.

## Field Reference

For complete field definitions including all possible values, defaults, and validation rules, see:

**[zones-fields.json](schemas/zones-fields.json)**

This JSON schema file documents:
- All available fields and their types
- Valid values for enumerated fields
- Default values
- Computed field formulas
- Special values for access control lists

## Per-Module Firewall Rules

Zone-level rules govern coarse access between zones. **Per-module** rules
(`firewall:rules` capability) declare each module's ingress/egress contract in
its own JSON and are validated against the zone-level policy:

- Every `ingress.from` zone must be in the destination zone's `pinhole-allowed-from`.
- Egress to a zone not in the source zone's `access-to` is permitted but warned.

A peer that is **another module's name** is resolved via an OPNsense host alias
populated with the peer's FQDN (`<vmname>.<zone0>.internal`), kept fresh by
OPNsense Unbound against dnsmasq — DHCP IP changes do not require rule rewrites.

See [`firewall/README.md`](firewall/README.md) for the full schema, sequence
bands, and CLI reference.
