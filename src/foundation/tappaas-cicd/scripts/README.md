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
- `info()` / `warn()` / `error()` / `debug()` / `die()` — Logging functions
- `get_config_value()` — Extract values from module JSON configuration
- `check_json()` — Validate a module JSON file against module-fields.json schema
- Node lookup helpers (read from `configuration.json`):
  - `get_primary_node_fqdn()` — FQDN of the first node (e.g., `tappaas1.mgmt.internal`)
  - `get_node_hostname [index]` — Actual system hostname of the Nth node
  - `get_node_dns_hostname [index]` — DNS hostname (falls back to system hostname)
  - `get_all_node_hostnames` — All node hostnames, one per line
  - `get_node_fqdn [index]` — Full FQDN of the Nth node
- Loads JSON configuration from `/home/tappaas/config/<vmname>.json`

**Example:**
```bash
. common-install-routines.sh mymodule
vmid=$(get_config_value "vmid")
cores=$(get_config_value "cores" "2")  # with default value
check_json /home/tappaas/config/mymodule.json || exit 1

# Node lookup (no module JSON needed)
primary=$(get_primary_node_fqdn)       # tappaas1.mgmt.internal
first_host=$(get_node_hostname 0)      # tappaas1
all_nodes=$(get_all_node_hostnames)    # tappaas1\ntappaas2\ntappaas3
```

---

### copy-update-json.sh

Copies a module JSON file to the config directory and optionally updates fields. Supports creating module variants with `--variant`.

**Usage:**
```bash
copy-update-json.sh <module-name> [--variant <name>] [--<field> <value>]...
```

**Parameters:**

| Parameter | Description | Example |
|-----------|-------------|---------|
| `module-name` | Name of the module | `identity` |
| `--variant <name>` | Create a variant (output: `<module>-<name>.json`) | `--variant staging` |
| `--<field> <value>` | Set JSON field to value (repeatable) | `--node "tappaas2"` |

**Example:**
```bash
# Copy identity.json with default values
copy-update-json.sh identity

# Copy and modify fields
copy-update-json.sh identity --node "tappaas2" --cores 4
copy-update-json.sh nextcloud --memory 4096 --zone0 "trusted"

# Create a variant of openwebui (auto-derives vmname, vmid, zone0, proxyDomain)
copy-update-json.sh openwebui --variant staging

# Create a variant with explicit overrides
copy-update-json.sh openwebui --variant dev --zone0 srv-dev --vmid 315
```

**What it does:**
1. Copies `./<module>.json` from current directory to `/home/tappaas/config/` (or `<module>-<variant>.json` in variant mode)
2. Automatically sets the `location` field to the module directory
3. Validates field names against `module-fields.json` schema
4. In variant mode, applies automatic field derivation (see below)
5. Applies `--<field> <value>` modifications to the copied JSON
6. Creates a `.orig` backup if modifications are made
7. Validates the resulting JSON is valid

**Variant mode (`--variant <name>`):**

When `--variant` is used, the following fields are derived automatically unless explicitly overridden with `--<field>`:

| Field | Derivation | Example (variant=staging) |
|-------|-----------|--------------------------|
| `vmname` | `<source vmname>-<variant>` | `openwebui-staging` |
| `vmid` | Next available VMID after source | `312` (if 311 is source) |
| `zone0` | `<variant>` if it matches a zone in `zones.json`, else unchanged | `srv` (unchanged) |
| `proxyDomain` | Insert `<variant>` after first segment | `openwebui.staging.test.tapaas.org` |

**Notes:**
- Integer fields (per schema) are stored as JSON numbers
- String fields are stored as JSON strings
- Unknown field names will cause an error
- In variant mode, `EFFECTIVE_MODULE` is exported for scripts that source this file

---

### create-configuration.sh

Creates or updates the `configuration.json` file for the TAPPaaS system by querying the running cluster. Supports two argument styles: positional (backwards compatible) and named arguments with defaults.

**Usage:**
```bash
# Named arguments (all optional — defaults are discovered from the Proxmox node)
create-configuration.sh [--upstream-git URL] [--branch NAME] [--domain DOMAIN]
                        [--email EMAIL] [--schedule FREQ] [--weekday DAY] [--hour H]
                        [--primary-node FQDN] [--update]

# Positional arguments (backwards compatible)
create-configuration.sh <upstreamGit> <branch> <domain> <email> <schedule> [weekday] [hour]
```

**Named Arguments:**

| Argument | Description | Default |
|----------|-------------|---------|
| `--upstream-git` | Git repository URL | `github.com/TAPPaaS/TAPPaaS` |
| `--branch` | Git branch to track | `stable` |
| `--domain` | Primary domain for TAPPaaS | From Proxmox node FQDN, or existing config |
| `--email` | Admin email for SSL and notifications | From Proxmox `root@pam` user, or existing config |
| `--schedule` | Update frequency: `monthly`, `weekly`, `daily`, `none` | `weekly` |
| `--weekday` | Day of week for updates | `Tuesday` |
| `--hour` | Hour of day 0-23 | `2` |
| `--primary-node` | Primary node FQDN for cluster discovery | Auto-detect from config or `tappaas1.mgmt.internal` |
| `--update` | Update mode: preserve existing config, overlay provided args | *(flag)* |

**Default Discovery:**

When `--domain` or `--email` are not explicitly provided, the script SSHs to the primary Proxmox node and discovers:
- **Domain**: from the node's FQDN (`hostname --fqdn`), extracting the domain part (e.g., `node1.mydomain.com` → `mydomain.com`)
- **Email**: from `/etc/pve/user.cfg`, reading the `root@pam` user's email address

If the node is unreachable, falls back to `CHANGE-mytappaas.dev` / `CHANGE-tappaas@mytappaas.dev` (which must be updated before deployment).

**Examples:**
```bash
# Create with all defaults (discovers domain/email from Proxmox node)
create-configuration.sh

# Create with specific domain and email
create-configuration.sh --domain mytappaas.dev --email admin@mytappaas.dev

# Update existing config — only change the domain
create-configuration.sh --update --domain newdomain.com

# Update mode — re-discover nodes and validate
create-configuration.sh --update

# Legacy positional syntax
create-configuration.sh github.com/TAPPaaS/TAPPaaS main my.dev admin@my.dev weekly
```

**What it does:**
1. Discovers domain and email from the primary Proxmox node's installer settings
2. Queries Proxmox cluster for all nodes via `pvecm` or `pvesh`
3. Gets IP addresses for each node via DNS or SSH
4. Creates or updates `/home/tappaas/config/configuration.json`
5. In update mode: preserves existing values, repositories, and `dns-hostname` mappings
6. Runs `validate-configuration.sh` on the result

**Generated configuration includes:**
- `tappaas` section: `version`, `domain`, `email`, `nodeCount`, `repositories[]`, `updateSchedule`
- `tappaas-nodes` array: `hostname`, `dns-hostname` (optional), and `ip` for each node

---

### validate-configuration.sh

Validates `/home/tappaas/config/configuration.json` for correctness and consistency.

**Usage:**
```bash
validate-configuration.sh [OPTIONS]
```

**Options:**

| Option | Description |
|--------|-------------|
| `--config <path>` | Path to configuration.json (default: `/home/tappaas/config/configuration.json`) |
| `--check-connectivity` | Ping each node IP to verify reachability |
| `--check-cluster` | SSH to first node, verify cluster nodes match configuration |
| `--check-repos` | Verify repository URLs are accessible via `git ls-remote` |
| `--quiet` | Only output errors, suppress info messages |

**Checks performed (always):**
- File exists and is valid JSON
- `domain` and `email` not starting with `CHANGE` (placeholder values)
- Email format validation
- `nodeCount` matches length of `tappaas-nodes` array
- No duplicate IPs or hostnames in `tappaas-nodes`
- Valid `updateSchedule` values (frequency, weekday, hour)
- All required fields present (`version`, `domain`, `email`, `nodeCount`, `repositories`, `tappaas-nodes`)
- `dns-hostname` fields are non-empty if set
- IP addresses are valid IPv4 format

**Examples:**
```bash
# Basic validation
validate-configuration.sh

# Full validation with connectivity and cluster checks
validate-configuration.sh --check-connectivity --check-cluster --check-repos

# Validate a specific file quietly
validate-configuration.sh --config /tmp/test-config.json --quiet
```

**Exit codes:**

| Code | Meaning |
|------|---------|
| `0` | All checks passed (may have warnings) |
| `1` | One or more validation errors found |

**Integration:** This script is called automatically by:
- `create-configuration.sh` (after generating config)
- `cluster/update.sh` (Step 0, warn-only)
- `tappaas-cicd/test.sh` (Test 3: Configuration files)

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

Installs a TAPPaaS module with dependency validation and service wiring. Supports installing module variants with `--variant`.

**Usage:**
```bash
install-module.sh <module-name> [--variant <name>] [--force] [--<field> <value>]...
```

**Parameters:**

| Parameter | Description | Example |
|-----------|-------------|---------|
| `module-name` | Name of the module to install | `openwebui` |
| `--variant <name>` | Install a variant of the module | `--variant staging` |
| `--force`, `--reinstall` | Install even if the module already exists (re-runs `install.sh` against the existing deployment) | |
| `--<field> <value>` | Override a JSON field (passed to `copy-update-json.sh`) | `--node tappaas2` |

**What it does:**
1. Checks the module is not already installed — aborts early otherwise (unless `--force`). Detects an existing install by its config in `~/config`; for VM-backed modules (those that `dependsOn cluster:vm`) it also confirms the VM exists on the cluster, so a leftover config whose VM is gone is treated as not-installed.
2. Copies and validates the module JSON config (variant-aware via `copy-update-json.sh`)
3. Checks that every `dependsOn` service is provided by an installed module
4. Validates that the module has service scripts for each service it provides
5. Iterates `dependsOn` and calls each provider's `install-service.sh`
6. Calls the module's own `install.sh` (if present)

**Example:**
```bash
install-module.sh vaultwarden
install-module.sh litellm --node tappaas2

# Install a staging variant of openwebui (auto-derives vmname, vmid, proxyDomain)
install-module.sh openwebui --variant staging

# Install a dev variant with explicit zone and vmid overrides
install-module.sh openwebui --variant dev --zone0 srv-dev --vmid 315

# Re-run the installer against an already-installed module
install-module.sh identity --force
```

**Variant mode:**

When `--variant <name>` is used, the source module's JSON is used as a base, but the output config is named `<module>-<variant>.json`. Fields like `vmname`, `vmid`, `zone0`, and `proxyDomain` are automatically derived unless explicitly overridden. See `copy-update-json.sh` for full variant field derivation rules.

---

### update-module.sh

Updates a TAPPaaS module safely with snapshot, testing, and automatic rollback.

**Usage:**
```bash
update-module.sh [options] <module-name>
```

**Options:**
| Option | Description |
|--------|-------------|
| `--force` | Proceed even if pre-update test fails |
| `--no-snapshot` | Skip pre-update test, snapshot, and rollback on failure |
| `--debug` | Show Debug-level messages |
| `--silent` | Suppress Info-level messages |

**What it does:**
1. Creates a pre-update VM snapshot (rollback safety net) — skipped with `--no-snapshot`
2. Runs `test-module.sh` pre-update — aborts if tests fail (unless `--force`) — skipped with `--no-snapshot`
3. Runs the module's `pre-update.sh` hook (if present)
4. Iterates `dependsOn` and calls each provider's `update-service.sh`
5. Calls the module's own `update.sh`
6. Runs `test-module.sh` post-update — rolls back on fatal failure (warns only with `--no-snapshot`)

**Exit codes:**
| Code | Meaning |
|------|---------|
| `0` | Update succeeded, all tests passed |
| `1` | Update completed but post-update test failed (non-fatal) |
| `2` | Fatal error (rollback attempted if snapshot exists) |

**Example:**
```bash
update-module.sh vaultwarden
update-module.sh --force litellm
update-module.sh --no-snapshot nextcloud
update-module.sh --debug openwebui
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
3. Checks out the specified branch (default: `stable`)
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
1. Discovers reachable Proxmox nodes from `configuration.json` (falls back to scanning tappaas1–9)
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

Deletes a TAPPaaS module with dependency-aware service teardown. Before any VM
is destroyed it resolves and **confirms the exact target VM**, refusing to guess
when multiple instances share a name (issue #195).

**Usage:**
```bash
delete-module.sh <module-name> [--vmid <id>] [--yes] [--force]
```

**Parameters:**

| Parameter | Description | Example |
|-----------|-------------|---------|
| `module-name` | Name of the module to delete | `vaultwarden` |
| `--vmid <id>` | Target a specific VM instance by VMID. **Required** when more than one cluster VM shares the module's name. If it differs from the config VMID, only that VM is destroyed and the module config is left intact (see notes). | `--vmid 313` |
| `--yes`, `-y` | Skip the destroy confirmation prompt (for automation) | |
| `--force` | Delete even if other modules depend on this module's services; **also implies `--yes`** | |

**What it does:**
1. Validates the module JSON config exists in `/home/tappaas/config/`
2. **Resolves and confirms the target VM**: lists every cluster VM sharing the module's name; if more than one exists it aborts and requires `--vmid`; otherwise prompts `Confirm destroy of VM <id>? [y/N]` before proceeding (skipped by `--yes`/`--force`; refuses in a non-interactive shell without them)
3. Checks reverse dependencies — blocks if other modules depend on this module's services (unless `--force`)
4. Calls the module's own `delete.sh` (if present) while the VM still exists
5. Iterates `dependsOn` in **reverse** order and calls each provider's `delete-service.sh` (skips if not found)
6. Removes the module configuration files (`.json` and `.json.orig`)

**Example:**
```bash
# Delete a module (prompts for confirmation before destroying its VM)
delete-module.sh vaultwarden

# Non-interactive delete (CI / scripted)
delete-module.sh litellm --force

# Two VMs named "openwebui" exist — destroy only the stray test instance,
# leaving the configured (prod) VM and its config untouched
delete-module.sh openwebui --vmid 313
```

**Notes:**
- **Confirmation is mandatory by default.** In a non-interactive shell (no TTY) the script refuses unless `--yes` or `--force` is passed, so a buggy script can never silently destroy a VM. The resolved name, VMID and node are shown before the prompt.
- **Multiple instances:** if the cluster has more than one VM with the module's name (e.g. prod + a stray test VM), deletion aborts with the list and requires `--vmid <id>` to pick the instance — preventing the "destroyed the wrong VM" class of incident.
- **VM-only mode:** when `--vmid` names a VM other than the module config's own VMID, *only* that VM is destroyed; the module's `delete.sh`, reverse-dependency check, service teardown and config removal are all skipped (the config still describes a different, live VM).
- The resolved VMID **and node** are handed to `cluster:vm delete-service.sh` (via `TAPPAAS_VMID_OVERRIDE`/`TAPPAAS_NODE_OVERRIDE`), which also corrects a stale `.node` after an HA migration.
- The deletion order is reversed compared to installation: the module's own `delete.sh` runs first (while the VM still exists), then services are torn down in reverse dependency order.
- HA/replication is removed before the VM is destroyed to prevent conflicts.
- Missing `delete-service.sh` scripts are skipped (not an error), allowing incremental rollout.
- Service teardown failures produce warnings but do not abort the overall deletion.

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
├── create-configuration.sh      # Create or update system configuration.json
├── delete-module.sh             # Delete a module with dependency-aware teardown
├── inspect-cluster.sh           # Compare running VMs against module configs
├── inspect-vm.sh                # 3-column config/git/actual VM comparison
├── install-module.sh            # Install a module with dependency validation
├── migrate-node.sh              # Evacuate or return all VMs on a node
├── migrate-vm.sh                # Migrate VMs between nodes (live or offline)
├── repository.sh                # Manage module repositories (add/remove/modify/list)
├── resize-disk.sh               # Resize VM disk in Proxmox and filesystem
├── setup-caddy.sh               # Install Caddy reverse proxy on firewall
├── snapshot-vm.sh               # VM snapshot management (create/list/cleanup/restore)
├── test-module.sh               # Test a module with dependency-recursive service testing
├── update-cron.sh               # Set up hourly update cron job
├── update-module.sh             # Update a module with snapshot, testing, and rollback
├── update-os.sh                 # OS-specific update (NixOS/Debian)
└── validate-configuration.sh    # Validate configuration.json for correctness
```
