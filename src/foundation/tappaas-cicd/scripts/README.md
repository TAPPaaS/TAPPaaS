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
- `repositories` array (initialized with the upstream repo and branch from arguments), `domain`, `email`, `updateSchedule` (in the `tappaas` section)
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

### install-module.sh

Installs a TAPPaaS module with dependency validation and service wiring.

**Usage:**
```bash
install-module.sh <module-name> [--<field> <value>]...
```

**What it does:**
1. Copies and validates the module JSON config
2. Checks that every `dependsOn` service is provided by an installed module
3. Validates that the module has service scripts for each service it provides
4. Iterates `dependsOn` and calls each provider's `install-service.sh`
5. Calls the module's own `install.sh` (if present)

**Example:**
```bash
install-module.sh vaultwarden
install-module.sh litellm --node tappaas2
```

---

### update-module.sh

Updates a TAPPaaS module with dependency-aware service wiring.

**Usage:**
```bash
update-module.sh <module-name>
```

**What it does:**
1. Validates the module JSON config exists
2. Checks that every `dependsOn` service is still available
3. Runs the module's `pre-update.sh` (if present)
4. Iterates `dependsOn` and calls each provider's `update-service.sh`
5. Calls the module's own `update.sh`

**Example:**
```bash
update-module.sh vaultwarden
update-module.sh litellm
```

---

### repository.sh

Manages module repositories for the TAPPaaS platform. Supports adding, removing, modifying, and listing external module repositories alongside the main TAPPaaS repository.

**Usage:**
```bash
repository.sh <command> [options]
```

**Commands:**

| Command | Description |
|---------|-------------|
| `add <url> [--branch <branch>]` | Add a new module repository |
| `remove <name> [--force]` | Remove a module repository |
| `modify <name> [--url <url>] [--branch <branch>]` | Modify a repository |
| `list` | List all tracked repositories |

**Examples:**
```bash
# Add a community module repository
repository.sh add github.com/someone/tappaas-community

# Add with a specific branch
repository.sh add github.com/someone/tappaas-community --branch develop

# List all repositories
repository.sh list

# Switch a repository to a different branch
repository.sh modify tappaas-community --branch stable

# Change a repository's URL
repository.sh modify tappaas-community --url github.com/other/repo --branch main

# Remove a repository
repository.sh remove tappaas-community

# Force remove even if modules are installed from it
repository.sh remove tappaas-community --force
```

**What `add` does:**
1. Validates the repository URL is reachable via `git ls-remote`
2. Clones the repository to `/home/tappaas/<name>/`
3. Checks out the specified branch (default: `main`)
4. Verifies the repo contains `src/modules.json`
5. Warns on VMID or module name conflicts with existing repos
6. Updates `configuration.json` with the new repository entry

**What `remove` does:**
1. Checks that no installed modules have their `location` pointing into the repository
2. Removes the repository directory
3. Updates `configuration.json` to remove the repository entry

**What `modify` does:**
- **Branch-only change**: Fetches and checks out the new branch in place
- **URL change**: Validates new repo has all currently-installed modules, re-clones, and updates module `location` fields

**Notes:**
- Repository URLs use the same format as `upstreamGit` (without `https://` prefix)
- The main TAPPaaS repository is the first entry in the `repositories` array
- All repositories are treated equally — no special handling for the main repo
- VMID and module name conflicts are warnings, not errors

---

### snapshot-vm.sh

Manages VM snapshots on the Proxmox cluster for an installed module.

**Usage:**
```bash
snapshot-vm.sh <module-name> [--list | --cleanup <N> | --restore <N>]
```

**Parameters:**

| Parameter | Description | Example |
|-----------|-------------|---------|
| `module-name` | Name of the module (must have config in ~/config) | `vaultwarden` |
| `--list` | List all snapshots on the VM | |
| `--cleanup <N>` | Delete all snapshots except the last N | `--cleanup 3` |
| `--restore <N>` | Restore snapshot N steps back (1 = most recent) | `--restore 1` |

**Example:**
```bash
# Create a new snapshot
snapshot-vm.sh vaultwarden

# List all snapshots
snapshot-vm.sh vaultwarden --list

# Keep only the last 3 snapshots
snapshot-vm.sh vaultwarden --cleanup 3

# Restore to the most recent snapshot
snapshot-vm.sh vaultwarden --restore 1
```

**What it does:**
1. Validates the module has a config in `~/config` with a `vmid`
2. Verifies the VM exists on the configured Proxmox node
3. Performs the requested snapshot operation via `qm snapshot`/`qm rollback`/`qm delsnapshot`

**Notes:**
- Snapshot names follow the format `tappaas-YYYYMMDD-HHMMSS`
- Restore stops the VM, rolls back, then starts it again
- Cleanup deletes oldest snapshots first

---

### inspect-cluster.sh

Compares actual running VMs across the Proxmox cluster against module configurations.

**Usage:**
```bash
inspect-cluster.sh
```

**What it does:**
1. Discovers all reachable Proxmox nodes (tappaas1–tappaas9)
2. Queries cluster-wide VM list via `pvesh get /cluster/resources`
3. Reads all `~/config/*.json` files that define a `vmid`
4. Displays a table of all running VMs with their config status
5. Lists configured modules whose VMs are not running

**Output:**
- VMs with a matching config show green "yes"
- VMs not in any config show yellow "NOT IN CONFIG"
- Configured modules with no running VM show red "NOT RUNNING"

---

### inspect-vm.sh

Generates a 3-column comparison table for a module's VM showing config, git, and actual values.

**Usage:**
```bash
inspect-vm.sh <module-name>
```

**Parameters:**

| Parameter | Description | Example |
|-----------|-------------|---------|
| `module-name` | Name of the module to inspect | `openwebui` |

**Example:**
```bash
inspect-vm.sh openwebui
inspect-vm.sh vaultwarden
```

**What it does:**
1. Reads deployed config from `~/config/<module>.json`
2. Reads git source JSON from the module's `location` directory
3. Queries actual VM config from Proxmox via `qm config`
4. Displays a comparison table with color-coded differences

**Color coding:**
- **Yellow** — config value differs from git value (config drift from source)
- **Red** — actual VM value differs from config value (VM out of sync)

**Fields compared:** vmname, vmid, node, cores, memory, diskSize, storage, bios, cputype, bridge0, zone0 (with VLAN resolution), mac0, HANode, description, vmtag

---

### migrate-vm.sh

Migrates VMs between Proxmox cluster nodes. Attempts live migration first; if it fails, automatically falls back to offline migration (shutdown → migrate → start).

**Usage:**
```bash
migrate-vm.sh <module-name>
migrate-vm.sh --node <node-name>
```

**Parameters:**

| Parameter | Description | Example |
|-----------|-------------|---------|
| `module-name` | Name of the module to migrate | `identity` |
| `--node <name>` | Target node — migrate all its VMs back | `--node tappaas1` |
| `--offline` | Skip live migration attempt | |

**Modes:**

1. **Single module** (`migrate-vm.sh identity`):
   - If the VM is on its primary node (`node`), migrates to the HA node (`HANode`)
   - If the VM is on its HA node, migrates back to the primary node
   - If the VM is on any other node, migrates to the primary node

2. **Node mode** (`migrate-vm.sh --node tappaas1`):
   - Finds all modules whose configured `node` is `tappaas1`
   - For each VM not currently on that node, migrates it there
   - Useful for returning VMs after maintenance or failover

**Example:**
```bash
# Migrate identity to its HA node
migrate-vm.sh identity

# Force offline migration (no live attempt)
migrate-vm.sh --offline identity

# Return all VMs to tappaas1 after maintenance
migrate-vm.sh --node tappaas1
```

**What it does:**
1. Reads module config to determine VMID, primary node, and HA node
2. Queries the cluster to find where the VM is currently running
3. Saves HA state (resource + affinity rule) before migration
4. Attempts live migration (unless `--offline`)
5. Falls back to offline migration if live fails
6. Restores HA resource and affinity rule after migration
7. Replication direction is automatically updated by Proxmox

**Notes:**
- Live migration may fail on clusters with different CPU architectures (e.g., Intel + AMD). The script handles this gracefully by falling back to offline migration
- HA affinity rules are saved and restored automatically
- The `--node` mode shows a summary of migrated/skipped/failed VMs

---

### migrate-node.sh

Evacuates all VMs from a Proxmox node (for maintenance) or returns them afterwards. Uses `migrate-vm.sh` for each individual migration.

**Usage:**
```bash
migrate-node.sh <node-name>
migrate-node.sh --return <node-name>
migrate-node.sh --list <node-name>
```

**Parameters:**

| Parameter | Description | Example |
|-----------|-------------|---------|
| `node-name` | Proxmox node to evacuate | `tappaas1` |
| `--return <name>` | Return VMs that belong on this node | `--return tappaas1` |
| `--list <name>` | Dry run — show what would happen | `--list tappaas1` |
| `--offline` | Skip live migration attempts | |

**Modes:**

1. **Evacuate** (`migrate-node.sh tappaas1`):
   - Finds all VMs currently running on the node
   - Migrates each to its configured HANode
   - VMs without an HANode are skipped with a warning

2. **Return** (`migrate-node.sh --return tappaas1`):
   - Finds all modules whose configured `node` is `tappaas1`
   - For each VM currently running elsewhere, migrates it back
   - VMs already on the correct node are skipped

3. **List** (`migrate-node.sh --list tappaas1`):
   - Shows both evacuate and return views without migrating
   - Color-coded: green = would migrate, yellow = no target/skipped

**Example workflow — planned maintenance:**
```bash
# 1. Check what would happen
migrate-node.sh --list tappaas1

# 2. Evacuate the node
migrate-node.sh --offline tappaas1

# 3. Perform maintenance on tappaas1
# ...

# 4. Return all VMs
migrate-node.sh --return --offline tappaas1
```

**Notes:**
- Each VM migration is delegated to `migrate-vm.sh`, which handles HA save/restore
- VMs without an HANode cannot be evacuated (requires manual migration)
- The summary shows migrated/skipped/failed counts

---

### test-module.sh

Tests a TAPPaaS module with dependency-recursive service testing.

**Usage:**
```bash
test-module.sh [options] <module-name>
```

**Parameters:**

| Parameter | Description | Example |
|-----------|-------------|---------|
| `module-name` | Name of the module to test | `openwebui` |
| `--deep` | Run extended/heavy tests | |
| `--debug` | Show Debug-level messages | |
| `--silent` | Suppress Info-level messages | |

**What it does:**
1. Validates the module JSON config exists and is valid
2. Checks that dependency services have `test-service.sh` scripts
3. Iterates `dependsOn` and calls each provider's `test-service.sh`
4. Calls the module's own `test.sh` (if present)
5. Reports structured results with pass/fail/skip counts

**Exit codes:**

| Code | Meaning |
|------|---------|
| `0` | All tests passed |
| `1` | One or more tests failed |
| `2` | Fatal error (requires rollback/reinstall) |

**Service tests included:**

| Service | Tests (standard) | Tests (--deep) |
|---------|-----------------|----------------|
| `cluster:vm` | VM running, ping, SSH | Disk usage, memory |
| `cluster:ha` | HA resource status, affinity rule | Replication job, replication health |
| `firewall:proxy` | Caddy domain, handler, HTTPS | TLS certificate, upstream reachability |

**Structured output:** Each message is prepended with `[Info]`, `[Debug]`, `[Warning]`, `[Error]`, or `[Fatal]`.

**Environment variables:**
- `TAPPAAS_TEST_DEEP=1` — same as `--deep`
- `TAPPAAS_DEBUG=1` — same as `--debug`

**Example:**
```bash
# Quick sanity check
test-module.sh openwebui

# Full regression test
test-module.sh --deep openwebui

# Silent mode for CI
test-module.sh --silent openwebui
```

---

### delete-module.sh

Deletes a TAPPaaS module with dependency-aware service teardown.

**Usage:**
```bash
delete-module.sh <module-name> [--force]
```

**Parameters:**

| Parameter | Description | Example |
|-----------|-------------|---------|
| `module-name` | Name of the module to delete | `vaultwarden` |
| `--force` | Delete even if other modules depend on this module's services | |

**What it does:**
1. Validates the module JSON config exists in `/home/tappaas/config/`
2. Checks reverse dependencies — blocks if other modules depend on this module's services (unless `--force`)
3. Calls the module's own `delete.sh` (if present) while the VM still exists
4. Iterates `dependsOn` in **reverse** order and calls each provider's `delete-service.sh` (skips if not found)
5. Removes the module configuration files (`.json` and `.json.orig`)

**Example:**
```bash
delete-module.sh vaultwarden
delete-module.sh litellm --force
```

**Notes:**
- The deletion order is reversed compared to installation: the module's own `delete.sh` runs first (while the VM still exists), then services are torn down in reverse dependency order
- HA/replication is removed before the VM is destroyed to prevent conflicts
- Missing `delete-service.sh` scripts are skipped (not an error), allowing incremental rollout
- Service teardown failures produce warnings but do not abort the overall deletion

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
├── delete-module.sh             # Delete a module with dependency-aware teardown
├── inspect-cluster.sh           # Compare running VMs against module configs
├── inspect-vm.sh                # 3-column config/git/actual VM comparison
├── install-module.sh            # Install a module with dependency validation
├── install-vm.sh                # VM creation library (sourced by install.sh)
├── migrate-node.sh              # Evacuate or return all VMs on a node
├── migrate-vm.sh                # Migrate VMs between nodes (live or offline)
├── repository.sh                # Manage module repositories (add/remove/modify/list)
├── resize-disk.sh               # Resize VM disk in Proxmox and filesystem
├── setup-caddy.sh               # Install Caddy reverse proxy on firewall
├── snapshot-vm.sh               # VM snapshot management (create/list/cleanup/restore)
├── test-config.sh               # Validate installation
├── test-module.sh               # Test a module with dependency-recursive service testing
├── update-cron.sh               # Set up hourly update cron job
├── update-HA.sh                 # Manage HA and replication for modules
├── update-module.sh             # Update a module with dependency-aware service wiring
└── update-os.sh                 # OS-specific update (NixOS/Debian)
```
