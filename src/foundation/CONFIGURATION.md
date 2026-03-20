# TAPPaaS Configuration

## Introduction

The `configuration.json` file is the central configuration file for a TAPPaaS installation. It defines global system settings, the domain and email for SSL certificates, and the list of Proxmox nodes in the cluster.

This file is installed to `/home/tappaas/config/configuration.json` on the tappaas-cicd VM. It resides only on tappaas-cicd and is not distributed to Proxmox nodes.

**Important**: Always edit the installed copy, not the source file in git.

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
- **repositories** - Array of module repositories (managed by `repository.sh`)
- **updateSchedule** - When to apply system updates (applies to all nodes)

### tappaas-nodes

Array of Proxmox node configurations, each containing:
- **hostname** - Actual system hostname of the Proxmox node (no naming convention enforced)
- **dns-hostname** - *(optional)* DNS hostname for FQDN construction (e.g., `<dns-hostname>.mgmt.internal`). Defaults to `hostname` if not set. Useful for legacy systems where the PVE hostname differs from the desired DNS name.
- **ip** - Management IP address

## Example Configuration

```json
{
    "tappaas": {
        "version": "0.5",
        "domain": "mytappaas.dev",
        "email": "admin@mytappaas.dev",
        "nodeCount": 3,
        "repositories": [
            {
                "name": "TAPPaaS",
                "url": "github.com/TAPPaaS/TAPPaaS",
                "branch": "main",
                "path": "/home/tappaas/TAPPaaS"
            }
        ],
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
            "hostname": "pve3",
            "dns-hostname": "tappaas3",
            "ip": "192.168.1.12"
        }
    ]
}
```

## Repositories

The `repositories` array tracks all module repositories. The first entry is the main TAPPaaS repository that was cloned during initial setup. Additional repositories can be added for community or private modules using `repository.sh`.

Each repository entry contains:

| Field | Description | Example |
|-------|-------------|---------|
| `name` | Repository name (derived from URL) | `TAPPaaS` |
| `url` | Git URL without `https://` prefix | `github.com/TAPPaaS/TAPPaaS` |
| `branch` | Git branch to track | `main` |
| `path` | Absolute local clone path | `/home/tappaas/TAPPaaS` |

**Managing repositories:**
```bash
# Add a community repository
repository.sh add github.com/someone/tappaas-community --branch main

# List all tracked repositories
repository.sh list

# Switch a repository to a different branch
repository.sh modify tappaas-community --branch develop

# Remove a repository
repository.sh remove tappaas-community
```

All repositories are pulled during the update cycle (`pre-update.sh`). Modules from any repository can be installed using `install-module.sh` as usual.

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

## Validation

Use `validate-configuration.sh` to check `configuration.json` for correctness:

```bash
# Basic validation (file structure, field values, uniqueness)
validate-configuration.sh

# Full validation with connectivity and cluster checks
validate-configuration.sh --check-connectivity --check-cluster --check-repos

# Validate a specific file
validate-configuration.sh --config /path/to/configuration.json
```

Validation runs automatically during the update cycle (`pre-update.sh` and `cluster/update.sh`).

## Legacy Systems (dns-hostname)

For legacy Proxmox systems where nodes don't follow the `tappaasN` naming convention, use `dns-hostname` to specify the DNS name used for FQDN construction while keeping the actual system hostname in `hostname`:

```json
{
    "hostname": "pve1",
    "dns-hostname": "tappaas1",
    "ip": "10.0.0.10"
}
```

This allows `pve1` to be addressed as `tappaas1.mgmt.internal` without renaming the node. If `dns-hostname` is not set, `hostname` is used for DNS.

## File Locations

| Location | Purpose |
|----------|---------|
| `src/foundation/configuration.json` | Git source (template) |
| `/home/tappaas/config/configuration.json` | Installed copy on tappaas-cicd |

## Field Reference

For complete field definitions including all possible values, defaults, and validation rules, see:

**[configuration-fields.json](configuration-fields.json)**

This JSON schema file documents:
- All available fields and their types
- Required vs optional fields
- Default values
- Valid value ranges and formats
- Update schedule configuration details
