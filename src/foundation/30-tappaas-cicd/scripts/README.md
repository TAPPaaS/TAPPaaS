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

Checks if a module's JSON configuration file needs updating.

**Usage:**
```bash
update-json.sh <module-name>
```

**Returns:**
- Exit 0 (true) - JSON needs updating
- Exit 1 (false) - No update needed or user customizations exist

**Logic:**
1. If `<module>.json.orig` exists in `/home/tappaas/config/`:
   - User has customized the file
   - Prints warning if upstream source has changed
   - Returns false (never auto-updates customized files)

2. If no `.orig` file exists:
   - Compares source `./<module>.json` with `/home/tappaas/config/<module>.json`
   - Returns true if files differ (update needed)
   - Returns false if files are identical

**Example usage in scripts:**
```bash
if update-json.sh mymodule; then
    echo "Updating mymodule.json..."
    cp mymodule.json /home/tappaas/config/
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
├── test-config.sh               # Validate installation
├── update-cron.sh               # Set up daily update cron job
└── update-json.sh               # Check if JSON configs need updating
```
