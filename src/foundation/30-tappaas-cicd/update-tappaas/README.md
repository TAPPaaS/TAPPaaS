# update-tappaas

TAPPaaS node update utilities for managing system updates across Proxmox nodes.

## Components

### update-tappaas

Scheduler that determines which nodes to update based on configuration and scheduling rules.

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

## Scheduling Logic

The update schedule is determined by the `branch` setting in `/home/tappaas/config/configuration.json`:

### Stable branches (main, stable)
Updates run only during the **first week of each month** (days 1-7):
- **Even numbered nodes** (tappaas2, tappaas4, ...): Tuesday
- **Odd numbered nodes** (tappaas1, tappaas3, ...): Thursday

### Development branches (all other branch names)
Updates run **daily**.

## Configuration

Reads from `/home/tappaas/config/configuration.json`:

```json
{
    "tappaas": {
        "branch": "main"
    },
    "tappaas-nodes": [
        { "hostname": "tappaas1", "ip": "192.168.1.10" },
        { "hostname": "tappaas2", "ip": "192.168.1.11" },
        { "hostname": "tappaas3", "ip": "192.168.1.12" }
    ]
}
```

## Cron Setup

Use `update-cron.sh` to install the daily cron job:

```bash
/home/tappaas/bin/update-cron.sh
```

This creates a cron entry that runs `update-tappaas` daily at 2:00 AM. The scheduling logic within `update-tappaas` determines which nodes actually get updated.

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
