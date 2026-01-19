# TAPPaaS-CICD Scripts

Utility scripts for TAPPaaS-CICD operations. These scripts are installed to `/home/tappaas/bin/` during setup.

## Scripts

### common-install-routines.sh

Shared library of functions and utilities for module installation scripts.

**Usage:** Source this file in install scripts:
```bash
. /home/tappaas/bin/common-install-routines.sh
```

**Features:**
- Color definitions for terminal output (YW, BL, RD, GN, etc.)
- `info()` - Print informational messages in green
- `get_config_value()` - Extract values from module JSON configuration
- Validates that script runs on tappaas-cicd host
- Loads JSON configuration from `/home/tappaas/config/<vmname>.json`

**Example:**
```bash
. common-install-routines.sh mymodule
vmid=$(get_config_value "vmid")
cores=$(get_config_value "cores" "2")  # with default value
```

---

### copy-jsons.sh

Copies all JSON configuration files to all Proxmox nodes in the cluster.

**Usage:**
```bash
copy-jsons.sh
```

**What it does:**
1. Queries the Proxmox cluster for all nodes via `pvesh`
2. Copies all `.json` files from `/home/tappaas/config/` to each node
3. Sets permissions to read-only (444) on the remote files

**Requirements:**
- SSH access to all Proxmox nodes as root
- `jq` installed for JSON parsing

---

### test-config.sh

Validates the TAPPaaS-CICD installation by running a series of checks.

**Usage:**
```bash
test-config.sh
```

**Checks performed:**
- tappaas user exists
- SSH keys exist for tappaas user
- TAPPaaS repository is cloned
- NixOS configuration is applied

**Output:**
- Color-coded status messages (green=OK, red=error, blue=warning)
- Detailed log written to `/home/tappaas/logs/test-config.log`

---

### update-cron.sh

Creates a cron entry to run the TAPPaaS update scheduler daily.

**Usage:**
```bash
update-cron.sh
```

**What it does:**
- Removes any existing `update-tappaas` cron entries
- Creates a new cron entry for user `tappaas` to run at 2:00 AM daily
- The `update-tappaas` command handles all scheduling logic internally

**Cron entry created:**
```
0 2 * * * /home/tappaas/bin/update-tappaas
```

---

### update-json.sh

Updates a module's JSON configuration file if the source differs from the installed version.

**Usage:**
```bash
update-json.sh <module-name>
```

**Returns:**
- Exit 0 (true) - JSON was updated (source copied to installed)
- Exit 1 (false) - No update needed or user customizations exist

**Logic:**
1. If `<module>.json.orig` exists in `/home/tappaas/config/`:
   - User has customized the file
   - Prints warning if upstream source has changed
   - Returns false (never auto-updates customized files)

2. If no `.orig` file exists:
   - Compares source `./<module>.json` with `/home/tappaas/config/<module>.json`
   - If files differ: copies source to installed location and returns true
   - If files are identical: returns false

**Example usage in scripts:**
```bash
if update-json.sh mymodule; then
    echo "mymodule.json was updated"
fi
```

**Customization workflow:**
To preserve local customizations:
```bash
# Before editing, save the original
cp /home/tappaas/config/module.json /home/tappaas/config/module.json.orig
# Now edit the config
vim /home/tappaas/config/module.json
```

---

### update-HA.sh

Manages Proxmox High Availability (HA) and ZFS replication for a TAPPaaS module based on its JSON configuration.

**Usage:**
```bash
update-HA.sh <module-name>
```

**What it does:**
Based on the module's `HANode` field in `<module>.json`:

1. **If HANode is "NONE" or not present:**
   - Removes VM from any HA group
   - Deletes any existing replication jobs

2. **If HANode is set to a valid node (e.g., "tappaas2"):**
   - Validates the HA node is reachable
   - Verifies storage exists on both nodes
   - Creates/updates HA group with both nodes
   - Adds VM to HA group with automatic failover
   - Sets up ZFS replication using `replicationSchedule` (default: `*/15`)

**JSON fields used:**
| Field | Description | Default |
|-------|-------------|---------|
| `vmid` | VM ID (required) | - |
| `node` | Primary node | `tappaas1` |
| `HANode` | Secondary node for HA | `NONE` |
| `replicationSchedule` | Cron-style replication interval | `*/15` |
| `storage` | ZFS storage pool | `tanka1` |

**Example:**
```bash
# Configure HA for nextcloud module
update-HA.sh nextcloud

# After removing HANode from JSON, remove HA config
update-HA.sh nextcloud
```

**Requirements:**
- SSH access to all Proxmox nodes as root
- Same storage pool must exist on both primary and HA nodes
- Proxmox HA services must be enabled (pve-ha-lrm, pve-ha-crm, corosync)

---

### setup-caddy.sh

Installs and configures the Caddy reverse proxy on the OPNsense firewall.

**Usage:**
```bash
setup-caddy.sh
```

**What it does:**
- Installs the os-caddy package on the firewall
- Creates firewall rules for HTTP (port 80) and HTTPS (port 443)
- Prints manual configuration steps for completing setup in OPNsense GUI

**Note:** Additional manual configuration is required. See the tappaas-cicd README.md for details.

---

## Installation

These scripts are automatically installed by `install.sh`:
```bash
cp scripts/*.sh /home/tappaas/bin/
chmod +x /home/tappaas/bin/*.sh
```

## Directory Structure

```
scripts/
├── README.md                    # This file
├── common-install-routines.sh   # Shared library for install scripts
├── copy-jsons.sh                # Distribute configs to nodes
├── setup-caddy.sh               # Install Caddy reverse proxy on firewall
├── test-config.sh               # Validate installation
├── update-cron.sh               # Set up daily update cron job
├── update-HA.sh                 # Manage HA and replication for modules
└── update-json.sh               # Check if JSON configs need updating
```
