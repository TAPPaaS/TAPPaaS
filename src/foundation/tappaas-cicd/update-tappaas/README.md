# update-tappaas

TAPPaaS node update utilities for managing system updates across Proxmox nodes.

## Components

### update-tappaas

Scheduler that determines which nodes to update based on per-node scheduling configuration.

```bash
update-tappaas [--force] [--node NODE] [--dry-run]
```

**Options:**
- `--force` - Force update of all nodes regardless of schedule
- `--node NODE` - Update only a specific node (still respects schedule unless `--force` is used)
- `--dry-run` - Show what would be updated without actually running updates

**Testing a node update:**
```bash
# See what would be updated on a specific node (without running)
update-tappaas --force --node tappaas1 --dry-run

# Actually run the update on a specific node (bypasses schedule)
update-tappaas --force --node tappaas1
```

### update-node

Performs the actual update of a single node via SSH.

```bash
update-node <node-name>
```

**Example:**
```bash
update-node tappaas1
```

## Scheduling

The `updateSchedule` field in the `tappaas` section of the configuration controls when updates run for all nodes.

### updateSchedule Format

```json
"updateSchedule": ["frequency", "weekday", "hour"]
```

**Fields:**
1. **frequency** - One of:
   - `"none"` - Never update automatically
   - `"daily"` - Run every day at the specified hour
   - `"weekly"` - Run once per week on the specified weekday
   - `"monthly"` - Run once per month on the first occurrence of the specified weekday (days 1-7)

2. **weekday** - Day of week (ignored for daily):
   - `"Monday"`, `"Tuesday"`, `"Wednesday"`, `"Thursday"`, `"Friday"`, `"Saturday"`, `"Sunday"`

3. **hour** - Hour of day (0-23) when the update should run

### Examples

```json
// Daily at 2am
"updateSchedule": ["daily", null, 2]

// Weekly on Wednesday at 3am
"updateSchedule": ["weekly", "Wednesday", 3]

// Monthly on first Tuesday at 2am
"updateSchedule": ["monthly", "Tuesday", 2]

// Monthly on first Thursday at 2am
"updateSchedule": ["monthly", "Thursday", 2]
```

## Configuration

Reads from `/home/tappaas/config/configuration.json`:

```json
{
    "tappaas": {
        "version": "0.5",
        "domain": "mytappaas.dev",
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

## Cron Setup

Use `update-cron.sh` to install the daily cron job:

```bash
/home/tappaas/bin/update-cron.sh
```

This creates a cron entry that runs `update-tappaas` every hour (at minute 0). The `update-tappaas` command checks the global `updateSchedule` to determine if updates should run at that time. Running hourly ensures the scheduled hour will be matched.

## What Gets Updated

When a node is updated, the following steps are performed:

### 1. Proxmox Node System Update

First, the Proxmox node itself is updated:
- SSH connectivity check to `<node>.mgmt.internal`
- `apt update` - refresh package lists
- `apt upgrade --assume-yes` - upgrade all packages

### 2. TAPPaaS-CICD Module Update (Always First)

The `tappaas-cicd` module is always updated first, regardless of which node is being updated. This ensures the update infrastructure itself is current before updating other modules.

Runs: `/home/tappaas/TAPPaaS/src/foundation/30-tappaas-cicd/update.sh`

### 3. Firewall Module Update

The `firewall` module is updated second to ensure network configuration is current.

Runs: `/home/tappaas/TAPPaaS/src/foundation/10-firewall/update.sh`

### 4. Node-Specific Module Updates

Finally, all modules installed on the target node are updated in **alphabetical order**.

**How modules are discovered:**
- Scans all JSON files in `/home/tappaas/config/` (excluding `configuration.json` and `zones.json`)
- For each JSON, checks if the `node` field matches the target node (defaults to `tappaas1` if not specified)
- Collects matching module names (JSON filename without `.json` extension)
- Sorts alphabetically and updates each module

**How module updates are run:**
- Finds the module directory using the `location` field from the module's JSON config
- Runs `chmod +x` on `update.sh` if needed
- Executes: `bash <location>/update.sh`
- Working directory is set to the module directory

**Example:** If updating `tappaas2` with modules `backup`, `identity`, and `nextcloud`:
```
1. tappaas-cicd (always first)
2. firewall (always second)
3. backup (alphabetical)
4. identity (alphabetical)
5. nextcloud (alphabetical)
```

### Module Update Script Requirements

Each module's `update.sh` should:
- Be executable (`chmod +x update.sh`)
- Accept being run from its own directory
- Handle idempotent updates (safe to run multiple times)
- Exit with code 0 on success, non-zero on failure

## Building

```bash
cd /home/tappaas/TAPPaaS/src/foundation/30-tappaas-cicd/update-tappaas
nix-build -A default default.nix
```

## Development

Enter a development shell:

```bash
nix-shell -A shell
```
