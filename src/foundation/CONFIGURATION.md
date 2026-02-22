# TAPPaaS Configuration

## Introduction

The `configuration.json` file is the central configuration file for a TAPPaaS installation. It defines global system settings, the domain and email for SSL certificates, and the list of Proxmox nodes in the cluster.

This file is installed to `/home/tappaas/config/configuration.json` on the tappaas-cicd VM and distributed to all Proxmox nodes at `/root/tappaas/configuration.json`.

**Important**: Always edit the installed copy, not the source file in git. Use `copy-jsons.sh` to distribute changes to all nodes.

## Required Changes

Before deploying TAPPaaS, you **must** update fields that have values starting with `CHANGE`:

- `tappaas.domain` - Your actual domain name
- `tappaas.email` - Your administrator email address

## Configuration Sections

### tappaas

Global system configuration including:
- **version** - TAPPaaS version identifier
- **domain** - Primary domain for SSL certificates and service URLs
- **email** - Admin email for Let's Encrypt and notifications
- **nodeCount** - Number of Proxmox nodes in the cluster
- **upstreamGit** - Git repository for TAPPaaS source
- **branch** - Git branch (affects update scheduling)
- **updateSchedule** - When to apply system updates (applies to all nodes)

### tappaas-nodes

Array of Proxmox node configurations, each containing:
- **hostname** - Node hostname (e.g., `tappaas1`, `tappaas2`)
- **ip** - Management IP address

## Example Configuration

```json
{
    "tappaas": {
        "version": "0.5",
        "domain": "mytappaas.dev",
        "email": "admin@mytappaas.dev",
        "nodeCount": 3,
        "upstreamGit": "github.com/TAPPaaS/TAPPaaS",
        "branch": "main",
        "updateSchedule": ["monthly", "Thursday", 2]
    },
    "tappaas-nodes": [
        {
            "hostname": "tappaas1",
            "ip": "192.168.1.10"
        },
        {
            "hostname": "tappaas2",
            "ip": "192.168.1.11"
        },
        {
            "hostname": "tappaas3",
            "ip": "192.168.1.12"
        }
    ]
}
```

## Update Scheduling

The `updateSchedule` field in the `tappaas` section controls when system updates are applied to all nodes. It's an array with three values:

| Position | Name | Description |
|----------|------|-------------|
| 0 | frequency | `daily`, `weekly`, or `monthly` |
| 1 | weekday | Day of week (ignored for daily) |
| 2 | hour | Hour of day (0-23) |

### Schedule Behavior by Branch

| Branch | Behavior |
|--------|----------|
| `main` or `stable` | Updates only run during first week of month (days 1-7) |
| Other branches | Updates run every day (for development) |

### Schedule Examples

```json
// Daily at 2 AM
"updateSchedule": ["daily", null, 2]

// Weekly on Wednesday at 3 AM
"updateSchedule": ["weekly", "Wednesday", 3]

// Monthly on first Tuesday at 2 AM
"updateSchedule": ["monthly", "Tuesday", 2]
```

## File Locations

| Location | Purpose |
|----------|---------|
| `src/foundation/configuration.json` | Git source (template) |
| `/home/tappaas/config/configuration.json` | Installed copy on tappaas-cicd |
| `/root/tappaas/configuration.json` | Copy on each Proxmox node |

## Field Reference

For complete field definitions including all possible values, defaults, and validation rules, see:

**[configuration-fields.json](configuration-fields.json)**

This JSON schema file documents:
- All available fields and their types
- Required vs optional fields
- Default values
- Valid value ranges and formats
- Update schedule configuration details
