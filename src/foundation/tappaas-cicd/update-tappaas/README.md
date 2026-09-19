# update-tappaas

TAPPaaS update scheduler that updates all foundation modules and app modules across all nodes.

## Usage

`update-tappaas` is `ExecStart` of `update-tappaas.service`. The unit first
updates the mothership itself (pull, relink, builds, `nixos-rebuild`; ADR-017
D3), then runs this sweep. It is started by the timer that
`update-tappaas-schedule` renders from `site.json` `updateSchedule`, or now:

```bash
site-manager update             # start the unit and follow it
site-manager update --dry-run    # repository drift + this sweep's plan (update-tappaas --dry-run)
```

`--force` of `update-tappaas` itself is deprecated (ADR-017 D5): it warns and has
no effect under the unit. A bare `update-tappaas` outside the unit does not
update the mothership.

## How It Works

`update-tappaas` is the **sweep**: the two module phases below. The mothership's own
update happens before it, in the unit's `ExecStartPre` steps (ADR-017 D3), so the sweep
always runs on current tooling and a failed self-update stops the run before any module
is touched:

| step | as | does |
|---|---|---|
| `tappaas-repair-ownership.sh` | root, non-fatal | heals root-owned config/repo files (#533) |
| `tappaas-self-prepare.sh` | tappaas | claims the operator's request, then `refresh-control-plane.sh`: pull (a held repository is skipped, #653), relink `~/bin`, rebuild every component |
| `tappaas-self-rebuild.sh` | root | `nixos-rebuild switch` for the mothership, then re-renders the update timer |

This work used to run inside tappaas-cicd's own module update, behind its pre-update test,
so one failing check aborted the module update before the `git pull` ran — and the pull that
would carry the fix was itself behind a test of the broken code. Three consecutive nightly
sweeps stalled that way (#595).

The outcome is reported as `control_plane=refreshed|stale|failed|skipped` in the summary
line and in `last-update-result.json`. `stale` means the components did not rebuild and the
shared manager binaries are the previous build — the sweep continues, but does not report
success.

### Phase 1: Foundation Modules (Fixed Order)

Foundation modules are updated in this order via `update-module.sh`:

1. **cluster** - Runs `apt update && apt upgrade` on all Proxmox nodes, distributes VM creation scripts and zone definitions
   - **foundation machines** - then every machine instance whose module is foundation-tier (`kind: machine`,
     `tier: foundation`): the cluster nodes (`pvehost` instances, e.g. `tappaas1`) first, then other machines
     (e.g. a `debianhost`, which may carry the PBS and so must precede `backup`), each group by name.
     An instance is named after its host, never its module, so it can never match a name in this list (#665).
2. **tappaas-cicd** - Converges the mothership's own module config (the pull, the component builds and the NixOS rebuild happen in `ExecStartPre`, before the sweep)
3. **template** - Updates NixOS/Debian VM templates
4. **firewall** - Updates OPNsense firewall configuration
5. **backup** - Updates Proxmox Backup Server
6. **identity** - Updates Authentik identity provider

Modules that are not installed (no JSON in `/home/tappaas/config/`) are skipped.

### Phase 2: App Modules (Dependency Order)

All remaining installed modules (discovered from `/home/tappaas/config/*.json`) are updated in dependency order;
foundation machines are not among them (Phase 1).
A config is a module by the same shape rule as `module-manager`'s discovery: a workload `kind`
(`vm`, `lxc`, `machine`, `application`, `device`), `dependsOn` / `integratesWith` / `provides`, or a
`moduleSource` — so machine instances (`debianhost`, `pvehost`) are swept. Two exceptions: a module
whose status is `archived` or `external`, and a satellite (`satellite-<name>`), which satellite-manager
drives.

- The `dependsOn` field in each module's JSON config is used to build a dependency graph
- Modules are topologically sorted so that dependencies are updated before their dependents
- Ties are broken alphabetically for deterministic ordering

Each module is updated via: `update-module.sh <module-name>`

## Scheduling

The `updateSchedule` field in the `tappaas` section of the configuration controls when updates run.

### updateSchedule Format

```json
"updateSchedule": { "frequency": "weekly", "weekday": "Tuesday", "hour": 2 }
```

**Fields:**

- **frequency** — `"none"` (never update automatically), `"daily"` (every day at `hour`),
  `"weekly"` (once a week on `weekday`), `"monthly"` (the first `weekday` of the month, days 1-7).
- **weekday** — `"Monday"` … `"Sunday"`. Read only for `weekly` and `monthly`; under `daily`
  and `none` it means nothing, so it is not stored.
- **hour** — 0-23, default 2.

### Examples

```json
// Daily at 2am
"updateSchedule": { "frequency": "daily", "hour": 2 }

// Weekly on Wednesday at 3am
"updateSchedule": { "frequency": "weekly", "weekday": "Wednesday", "hour": 3 }

// Monthly on the first Tuesday at 2am
"updateSchedule": { "frequency": "monthly", "weekday": "Tuesday", "hour": 2 }

// Never
"updateSchedule": { "frequency": "none" }
```

> **The legacy triple.** `["weekly", "Tuesday", 2]` is still read, and migration `0003`
> rewrites it in place the first time a site updates. It was retired because its second slot
> was honoured only for `weekly` and `monthly`: a site holding `["daily", "Tuesday", 2]` was
> stating a weekly update it was never getting, and nothing said so (ADR-017 D7).

## Configuration

Reads `/home/tappaas/config/site.json` — `.updateSchedule` (above), `.automaticReboot`
(whether the scheduled run may reboot a guest that declares `rebootOk`), `.email` (where a
failed sweep is reported, #651) and `.repositories`.

## Scheduling

The timer is **rendered from `site.json`**, not declared in nix (ADR-017 D2):
`update-tappaas-schedule.service` maps `.updateSchedule` to an `OnCalendar` expression and
writes `/run/systemd/system/update-tappaas.timer` with `Persistent=false` — at boot, after
every self-rebuild, and whenever `site-manager site modify` changes the schedule. A
`"none"` schedule renders no timer. There is no schedule decision left in Python: the timer
fires when a run is due, and only then. cron was retired in issue #150. Output flows through
journald → Promtail → Loki for Grafana.

```bash
systemctl list-timers update-tappaas.timer     # what site.json currently asks for
journalctl -u update-tappaas.service
site-manager validate                          # checks the schedule, prints the OnCalendar
```

## What a run leaves behind

- **`config/last-update-result.json`** — the sweep's own record: `ok`, per-module tallies,
  `control_plane`, `path` (`unit` or `legacy`), the operator `request`, `deferred_changes`
  (disruptive changes held back for want of `rebootOk`, ADR-020 D8) and `test_warnings`
  (checks that were already failing before a module's update, #635). A run that stopped in
  `ExecStartPre` records the `stage` instead.
- **`config/update-tappaas.failures`** — one line per failed run, and per failure notice
  sent or not sent.
- **A notice to the site owner** when the unit fails: `update-tappaas-failure.service` mails
  `site.json` `email` through a Proxmox node's mail system, naming the step that failed
  (#651, ADR-007e v1.3).

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
