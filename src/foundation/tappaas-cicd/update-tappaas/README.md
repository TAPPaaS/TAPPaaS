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

When triggered (by schedule or `--force`), `update-tappaas` runs a control-plane refresh
and then two module phases:

### Phase 0: Control-Plane Refresh

`scripts/refresh-control-plane.sh` pulls the tracked repositories, relinks `~/bin`, and
rebuilds every compiled component — before any module is touched.

This is the mothership updating **itself**, and it is a prerequisite of the sweep rather
than a step inside it. The work used to run inside tappaas-cicd's own module update, behind
its pre-update test, so one failing check aborted the module update before the `git pull`
ran — and the pull that would carry the fix was itself behind a test of the broken code.
Three consecutive nightly sweeps stalled that way (#595).

It is placed after the schedule gate, never before: the unit fires hourly and exits there
on a not-due run, so an earlier placement would pull from the forge every hour.

The outcome is reported as `control_plane=refreshed|stale|failed|skipped` in the summary
line and in `last-update-result.json`. `stale` means the components did not rebuild and the
shared manager binaries are the previous build — the sweep continues, but does not report
success.

### Phase 1: Foundation Modules (Fixed Order)

Foundation modules are updated in this order via `update-module.sh`:

1. **cluster** - Runs `apt update && apt upgrade` on all Proxmox nodes, distributes VM creation scripts and zone definitions
2. **tappaas-cicd** - Rebuilds the mothership VM's NixOS system (the code pull and tool rebuild moved to Phase 0)
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

## Scheduling

`update-tappaas` is scheduled by a **systemd timer** declared in
`tappaas-cicd.nix` (`systemd.timers.update-tappaas`, `OnCalendar=hourly`).
cron was retired in issue #150. The timer fires hourly; `update-tappaas` then
checks the global `updateSchedule` to decide whether to actually run at that
hour. Output flows through journald → Promtail → Loki for Grafana.

```bash
systemctl status update-tappaas.timer
journalctl -u update-tappaas.service
```

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
