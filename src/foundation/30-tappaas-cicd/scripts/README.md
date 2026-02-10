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
| NixOS | ext4 | ✓ Fully supported |
| Debian/Ubuntu | ext4 | ✓ Fully supported |
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

### rebuild-nixos.sh

Handles the complete NixOS rebuild workflow for a VM, including IP detection, nixos-rebuild, reboot, and DHCP hostname fix.

**Usage:**
```bash
rebuild-nixos.sh <vmname> <vmid> <node> <nix-config-path>
```

**Parameters:**

| Parameter | Description | Example |
|-----------|-------------|---------|
| `vmname` | Name of the VM | `nextcloud` |
| `vmid` | Proxmox VM ID | `610` |
| `node` | Proxmox node name | `tappaas1` |
| `nix-config-path` | Path to the .nix configuration file | `./nextcloud.nix` |

**Example:**
```bash
# Rebuild a VM from the module directory
rebuild-nixos.sh myvm 610 tappaas1 ./myvm.nix
```

**What it does:**

1. **Waits for VM IP** - Polls the Proxmox guest agent for up to 3 minutes until the VM has an IPv4 address
2. **Updates SSH known_hosts** - Removes old host keys and adds the new one
3. **Runs nixos-rebuild** - Deploys the NixOS configuration to the VM
4. **Reboots VM** - Applies the new configuration with a full reboot
5. **Waits for reboot** - Polls guest agent again until VM is back online
6. **Fixes DHCP hostname** - Updates NetworkManager's dhcp-hostname setting and triggers a DHCP renewal so the DHCP server registers the correct hostname

**DHCP Hostname Fix:**
NixOS VMs cloned from the `tappaas-nixos` template initially register with the template's hostname in DHCP. This script automatically fixes this by:

- Finding the ethernet connection via `nmcli connection show`
- Finding the ethernet device via `nmcli device status`
- Setting `ipv4.dhcp-hostname` to the VM's actual hostname
- Running `nmcli device reapply` to trigger a DHCP renewal

See `src/foundation/20-tappaas-nixos/DHCP-README.md` for more details on this known issue.

**Requirements:**

- SSH access to the Proxmox node as root
- SSH access to the VM as tappaas user with sudo
- QEMU guest agent running on the VM
- `jq` installed on tappaas-cicd

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
├── check-disk-threshold.sh      # Auto-expand disks when usage exceeds threshold
├── common-install-routines.sh   # Shared library for install scripts
├── copy-jsons.sh                # Distribute configs to nodes
├── rebuild-nixos.sh             # NixOS rebuild workflow with DHCP fix
├── resize-disk.sh               # Resize VM disk in Proxmox and filesystem
├── setup-caddy.sh               # Install Caddy reverse proxy on firewall
├── test-config.sh               # Validate installation
├── update-cron.sh               # Set up daily update cron job
├── update-HA.sh                 # Manage HA and replication for modules
└── update-json.sh               # Check if JSON configs need updating
```
