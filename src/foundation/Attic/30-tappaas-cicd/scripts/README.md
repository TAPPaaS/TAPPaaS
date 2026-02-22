# TAPPaaS-CICD Scripts

Utility scripts for TAPPaaS-CICD operations. These scripts are installed to `/home/tappaas/bin/` during setup.

## Scripts

### common-install-routines.sh

Shared library of functions and utilities for module installation scripts.

**Usage:** Source this file in install scripts:
```bash
. /home/tappaas/bin/common-install-routines.sh <vmname>
```

**Features:**
- Color definitions for terminal output (YW, BL, RD, GN, etc.)
- `info()` - Print informational messages in green
- `warn()` - Print warning messages in yellow
- `error()` - Print error messages in red
- `get_config_value()` - Extract values from module JSON configuration
- `check_json()` - Validate a module JSON file against module-fields.json schema
- Validates that script runs on tappaas-cicd host
- Loads JSON configuration from `/home/tappaas/config/<vmname>.json`

**Example:**
```bash
. common-install-routines.sh mymodule
vmid=$(get_config_value "vmid")
cores=$(get_config_value "cores" "2")  # with default value
check_json /home/tappaas/config/mymodule.json || exit 1
```

---

### copy-update-json.sh

Copies a module JSON file to the config directory and optionally updates fields.

**Usage:**
```bash
copy-update-json.sh <module-name> [--<field> <value>]...
```

**Parameters:**

| Parameter | Description | Example |
|-----------|-------------|---------|
| `module-name` | Name of the module | `identity` |
| `--<field> <value>` | Set JSON field to value (repeatable) | `--node "tappaas2"` |

**Example:**
```bash
# Copy identity.json with default values
copy-update-json.sh identity

# Copy and modify fields
copy-update-json.sh identity --node "tappaas2" --cores 4
copy-update-json.sh nextcloud --memory 4096 --zone0 "trusted"
```

**What it does:**
1. Copies `./<module>.json` from current directory to `/home/tappaas/config/`
2. Automatically sets the `location` field to the module directory
3. Validates field names against `module-fields.json` schema
4. Applies `--<field> <value>` modifications to the copied JSON
5. Creates a `.orig` backup if modifications are made
6. Validates the resulting JSON is valid

**Notes:**
- Integer fields (per schema) are stored as JSON numbers
- String fields are stored as JSON strings
- Unknown field names will cause an error

---

### create-configuration.sh

Creates the `configuration.json` file for the TAPPaaS system by querying the running cluster.

**Usage:**
```bash
create-configuration.sh <upstreamGit> <branch> <domain> <email> <updateSchedule> [weekday] [hour]
```

**Parameters:**

| Parameter | Description | Example |
|-----------|-------------|---------|
| `upstreamGit` | Git URL of the upstream repository | `github.com/TAPPaaS/TAPPaaS` |
| `branch` | Branch to use for updates | `main` |
| `domain` | Primary domain for TAPPaaS | `mytappaas.dev` |
| `email` | Admin email for SSL and notifications | `admin@mytappaas.dev` |
| `updateSchedule` | Update frequency | `monthly`, `weekly`, `daily`, `none` |
| `weekday` | (Optional) Day of week for updates, default: Thursday | `Wednesday` |
| `hour` | (Optional) Hour of day 0-23, default: 2 | `3` |

**Example:**
```bash
create-configuration.sh github.com/TAPPaaS/TAPPaaS main mytappaas.dev admin@mytappaas.dev monthly
create-configuration.sh github.com/TAPPaaS/TAPPaaS main mytappaas.dev admin@mytappaas.dev weekly Wednesday 3
```

**What it does:**
1. Queries Proxmox cluster for all nodes via `pvesh`
2. Lists all VMs and their IP addresses
3. Creates `/home/tappaas/config/configuration.json` with a global `updateSchedule`

**Generated configuration includes:**
- `upstreamGit`, `branch`, `domain`, `email`, `updateSchedule` from arguments (in the `tappaas` section)
- `nodes` array with hostname and IP for each node

---

### install-vm.sh

Creates a VM on Proxmox using a module's JSON configuration. This is a library script meant to be sourced by module install scripts.

**Usage:** Source this file in module install scripts:
```bash
. /home/tappaas/bin/install-vm.sh
```

**What it does:**
1. Sources `copy-update-json.sh` to copy the module JSON to config
2. Sources `common-install-routines.sh` to load config functions
3. Validates the JSON configuration
4. Copies the JSON to the target Proxmox node
5. Calls `Create-TAPPaaS-VM.sh` on the node to create the VM
6. Cleans up the temporary JSON file on the node

**Exported variables after sourcing:**
- `VMNAME` - VM name from configuration
- `VMID` - VM ID from configuration
- `NODE` - Proxmox node where VM is created
- `ZONE0NAME` - Primary network zone

**Example module install.sh:**
```bash
#!/usr/bin/env bash
set -euo pipefail

# Create the VM
. /home/tappaas/bin/install-vm.sh

# Get additional config values
IMAGE_TYPE="$(get_config_value 'imageType' 'clone')"

# Run post-install steps
/home/tappaas/bin/update-os.sh "${VMNAME}" "${VMID}" "${NODE}"
```

---

### update-os.sh

Updates a VM's operating system based on its type (NixOS or Debian/Ubuntu).

**Usage:**
```bash
update-os.sh <vmname> <vmid> <node>
```

**Parameters:**

| Parameter | Description | Example |
|-----------|-------------|---------|
| `vmname` | Name of the VM | `nextcloud` |
| `vmid` | Proxmox VM ID | `610` |
| `node` | Proxmox node name | `tappaas1` |

**Example:**
```bash
update-os.sh myvm 610 tappaas1
```

**What it does:**
1. Waits for VM to get an IP address (via guest agent or DHCP leases)
2. Updates SSH known_hosts
3. Detects OS type (NixOS or Debian/Ubuntu)
4. For **NixOS**:
   - Runs `nixos-rebuild` using `./<vmname>.nix` in current directory
   - Reboots VM to apply configuration
   - Waits for VM to come back up
5. For **Debian/Ubuntu**:
   - Waits for cloud-init to complete
   - Runs `apt-get update && apt-get upgrade`
   - Installs QEMU guest agent
6. Fixes DHCP hostname registration via NetworkManager

**Requirements:**
- For NixOS VMs: `./<vmname>.nix` must exist in current directory
- SSH access to VM as tappaas user
- QEMU guest agent installed on VM

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

Creates a cron entry to run the TAPPaaS update scheduler every hour.

**Usage:**
```bash
update-cron.sh
```

**What it does:**
- Removes any existing `update-tappaas` cron entries
- Creates a new cron entry for user `tappaas` to run hourly (at minute 0)
- The `update-tappaas` command handles all scheduling logic internally, checking the global `updateSchedule` to determine if updates should run

**Cron entry created:**
```
0 * * * * /home/tappaas/bin/update-tappaas
```

**Why hourly?** Running hourly ensures the scheduled hour will be matched. The `update-tappaas` script only performs updates when the current hour matches the global `updateSchedule` hour.

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
   - Adds VM to HA resources with node-affinity rule
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

### check-disk-threshold.sh

Checks if a VM's disk usage exceeds a threshold and automatically expands the disk by 50% if needed.

**Usage:**
```bash
check-disk-threshold.sh <vmname> <threshold>
```

**Parameters:**

| Parameter | Description | Example |
|-----------|-------------|---------|
| `vmname` | Name of the VM (must have a JSON config) | `nextcloud` |
| `threshold` | Disk usage percentage threshold (1-99) | `80` |

**Example:**
```bash
# Check if nextcloud disk usage exceeds 80%
check-disk-threshold.sh nextcloud 80
```

**What it does:**

1. Connects to the VM via SSH and checks current disk usage with `df`
2. If usage is below threshold, exits with no action
3. If usage exceeds threshold:
   - Retrieves current disk size from Proxmox
   - Calculates new size (50% increase, minimum 5GB)
   - Calls `resize-disk.sh` to perform the resize
   - Logs the resize event to `/home/tappaas/logs/disk-resize.log`

**Cron usage:**
```bash
# Check disk usage every hour
0 * * * * /home/tappaas/bin/check-disk-threshold.sh nextcloud 80
```

**Requirements:**

- SSH access to the VM as tappaas user
- SSH access to the Proxmox node as root
- VM must be running and reachable

---

### resize-disk.sh

Resizes the disk of a VM both in Proxmox and inside the VM filesystem.

**Usage:**
```bash
resize-disk.sh <vmname> <new-size>
```

**Parameters:**

| Parameter | Description | Example |
|-----------|-------------|---------|
| `vmname` | Name of the VM (must have a JSON config) | `nextcloud` |
| `new-size` | New disk size (G, M, T, K suffix) | `50G` |

**Example:**
```bash
# Resize nextcloud disk to 50GB
resize-disk.sh nextcloud 50G
```

**What it does:**

1. Validates that the new size is larger than the current size (shrinking not supported)
2. Resizes the disk in Proxmox using `qm resize`
3. Connects to the VM via SSH and resizes the partition and filesystem:
   - **NixOS**: Uses `sfdisk` to grow the partition, then `resize2fs` for ext4
   - **Debian/Ubuntu**: Uses `growpart` to grow the partition, then `resize2fs` for ext4
4. Verifies the new filesystem size
5. Updates the `diskSize` field in the VM's JSON configuration

**Supported configurations:**

| OS | Filesystem | Status |
|----|------------|--------|
| NixOS | ext4 | Fully supported |
| Debian/Ubuntu | ext4 | Fully supported |
| Other | Any | Proxmox disk resized, manual filesystem resize required |

**Requirements:**

- SSH access to the VM as tappaas user with sudo
- SSH access to the Proxmox node as root
- VM must be running and reachable

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

These scripts are automatically installed by `install2.sh`:
```bash
cp scripts/*.sh /home/tappaas/bin/
chmod +x /home/tappaas/bin/*.sh
```

Or symlinked via NixOS configuration.

## Directory Structure

```
scripts/
├── README.md                    # This file
├── check-disk-threshold.sh      # Auto-expand disks when usage exceeds threshold
├── common-install-routines.sh   # Shared library for install scripts
├── copy-update-json.sh          # Copy and modify module JSON configs
├── create-configuration.sh      # Generate system configuration.json
├── install-vm.sh                # VM creation library (sourced by install.sh)
├── resize-disk.sh               # Resize VM disk in Proxmox and filesystem
├── setup-caddy.sh               # Install Caddy reverse proxy on firewall
├── test-config.sh               # Validate installation
├── update-cron.sh               # Set up hourly update cron job
├── update-HA.sh                 # Manage HA and replication for modules
└── update-os.sh                 # OS-specific update (NixOS/Debian)
```
