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

## Example Configuration

```json
{
    "mgmt": {
        "type": "Management",
        "state": "Mandatory",
        "typeId": 0,
        "subId": 0,
        "vlantag": 0,
        "ip": "10.0.0.0/24",
        "bridge": "lan",
        "access-to": ["internet", "dmz", "srv", "client", "guest", "iot"],
        "description": "Internal self-management network, untagged traffic"
    },
    "srv": {
        "type": "Service",
        "state": "Active",
        "typeId": 2,
        "subId": 10,
        "vlantag": 210,
        "ip": "10.2.10.0/24",
        "bridge": "lan",
        "access-to": ["internet", "mgmt"],
        "pinhole-allowed-from": ["dmz", "client"],
        "DHCP-start": 50,
        "DHCP-end": 250,
        "description": "Primary service zone for business applications"
    },
    "dmz": {
        "type": "DMZ",
        "state": "Active",
        "typeId": 6,
        "subId": 10,
        "vlantag": 610,
        "ip": "10.6.10.0/24",
        "bridge": "lan",
        "access-to": ["srv"],
        "pinhole-allowed-from": ["internet"],
        "description": "Demilitarized zone for internet-facing services"
    }
}
```

## Computed Values

Several zone fields can be computed from others:

- **vlantag**: `typeId * 100 + subId` (e.g., typeId=2, subId=10 → vlantag=210)
- **ip**: `10.typeId.subId.0/24` (e.g., typeId=2, subId=10 → 10.2.10.0/24)

## Field Reference

For complete field definitions including all possible values, defaults, and validation rules, see:

**[zones-fields.json](zones-fields.json)**

This JSON schema file documents:
- All available fields and their types
- Valid values for enumerated fields
- Default values
- Computed field formulas
- Special values for access control lists
