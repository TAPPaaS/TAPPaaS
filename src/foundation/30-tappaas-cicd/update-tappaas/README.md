# update-tappaas

TAPPaaS node update utilities for managing system updates across Proxmox nodes.

## Components

### update-tappaas

Scheduler that determines which nodes to update based on per-node scheduling configuration.

```bash
update-tappaas [--force] [--node NODE]
```

**Options:**
- `--force` - Force update of all nodes regardless of schedule
- `--node NODE` - Update only a specific node (still respects schedule unless `--force` is used)

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

Each node has an `updateSchedule` field in the configuration that controls when updates run.

### updateSchedule Format

```json
"updateSchedule": ["frequency", "weekday", hour]
```

**Fields:**
1. **frequency** - One of:
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
        "domain": "mytappaas.dev"
    },
    "tappaas-nodes": [
        {
            "hostname": "tappaas1",
            "ip": "192.168.1.10",
            "updateSchedule": ["monthly", "Thursday", 2]
        },
        {
            "hostname": "tappaas2",
            "ip": "192.168.1.11",
            "updateSchedule": ["monthly", "Tuesday", 2]
        },
        {
            "hostname": "tappaas3",
            "ip": "192.168.1.12",
            "updateSchedule": ["monthly", "Thursday", 2]
        }
    ]
}
```

## Cron Setup

Use `update-cron.sh` to install the daily cron job:

```bash
/home/tappaas/bin/update-cron.sh
```

This creates a cron entry that runs `update-tappaas` daily at 2:00 AM. The `update-tappaas` command checks each node's `updateSchedule` to determine if it should be updated at that time.

## What Gets Updated

Each node update performs:
1. SSH connectivity check
2. `apt update`
3. `apt upgrade --assume-yes`

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
