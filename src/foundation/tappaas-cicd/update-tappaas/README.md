# update-tappaas

TAPPaaS update scheduler that updates all foundation modules and app modules across all nodes.

## Usage

```bash
update-tappaas [--force] [--dry-run]
```

**Options:**
- `--force` - Force update regardless of schedule
- `--dry-run` - Show what would be updated without actually running updates

**Examples:**
```bash
# See the full update plan (without running)
update-tappaas --force --dry-run

# Force an immediate update of everything
update-tappaas --force
```

## How It Works

When triggered (by schedule or `--force`), `update-tappaas` runs two phases:

### Phase 1: Foundation Modules (Fixed Order)

Foundation modules are updated in this order via `update-module.sh`:

1. **cluster** - Runs `apt update && apt upgrade` on all Proxmox nodes, distributes VM creation scripts and zone definitions
2. **tappaas-cicd** - Updates the mothership VM (pulls latest code, rebuilds tools)
3. **template** - Updates NixOS/Debian VM templates
4. **firewall** - Updates OPNsense firewall configuration
5. **backup** - Updates Proxmox Backup Server
6. **identity** - Updates Authentik identity provider

Modules that are not installed (no JSON in `/home/tappaas/config/`) are skipped.

### Phase 2: App Modules (Dependency Order)

All remaining installed modules (discovered from `/home/tappaas/config/*.json`) are updated in dependency order:

- The `dependsOn` field in each module's JSON config is used to build a dependency graph
- Modules are topologically sorted so that dependencies are updated before their dependents
- Ties are broken alphabetically for deterministic ordering

Each module is updated via: `update-module.sh <module-name>`

## Scheduling

The `updateSchedule` field in the `tappaas` section of the configuration controls when updates run.

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

## Building

```bash
cd /home/tappaas/TAPPaaS/src/foundation/tappaas-cicd/update-tappaas
nix-build -A default default.nix
```

## Development

Enter a development shell:

```bash
nix-shell -A shell
```
