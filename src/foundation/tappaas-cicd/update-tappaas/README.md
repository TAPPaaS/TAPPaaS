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
   - **foundation machines** - then every machine instance whose module is site-scoped (`kind: machine`,
     `stack: foundation`, ADR-022e): the cluster nodes (`pvehost` instances, e.g. `tappaas1`) first, then other machines
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
`moduleSource` — so machine instances (`debianhost`, `pvehost`, a managed satellite) are swept. Out of
the lifecycle, and logged as skipped: a module whose status is `archived` or `external`, one
recorded `management: unmanaged` (ADR-022g) — a locked-down satellite, which patches itself — and
one whose `stack` is `template` (#741): a Proxmox VM template to clone from, or the module
skeleton. A template is discovered like any other config, and `module-manager list` shows it, but
it has no source to reconcile against, so an update of it can never succeed; the skip is
structural rather than a lifecycle choice, and holds whatever its status says.

### A sweep cut short by a planned mothership reboot resumes (#744)

When the control-plane rebuild crosses a nixpkgs release it is staged and the mothership
reboots to take it (#725/#728), which ends the sweep before any module is touched. That part is
deliberate; what used to follow was not. No result was written, so
`config/last-update-result.json` still held the previous run and read as `ok: true` on a site
that had done no module work for 24 hours. The timer, deactivated by the reboot, next elapsed a
full day later. And `OnFailure` could not fire, because the shutdown it would report was
already queued.

So before requesting the reboot, `tappaas-self-rebuild.sh` now writes the result as
`ok: false, complete: false, interrupted: …, resume: "pending"`, and drops a marker in
`config/.update-resume` — in `config/`, not `/run`, because `/run` is cleared by the very
reboot the marker must survive. At the next boot `update-tappaas-schedule.sh` consumes the
marker and starts the sweep.

This is a **resume of an interrupted planned run, not a catch-up of a missed schedule.**
ADR-017 D1 keeps `Persistent=false` on purpose: a tick missed while the host was unexpectedly
down must not fire at boot, because whatever took the host down could be compounded by running
again immediately. Here the reboot was ours, deliberate, and it succeeded — the only unfinished
business is the modules. The marker is consumed *before* the sweep starts, so one interrupted
run earns exactly one resume and a sweep failing for some other reason cannot loop.

- The `dependsOn` field in each module's JSON config is used to build a dependency graph
- Modules are topologically sorted so that dependencies are updated before their dependents
- Ties are broken alphabetically for deterministic ordering

Each module is updated via: `update-module.sh <module-name>`

### Before the phases: memory that does not fit is held (#891)

`health-manager capacity` projects each node after the update (see the
health-manager README). A module whose release raises its memory beyond what its
node holds under 95% is updated with its **current** memory: the converge leaves
that one field alone (`TAPPAAS_HOLD_MEMORY`, reported as "growth held"), the rest
of its update goes ahead, and nothing else waits for it. Config keeps the size the
release asks for, so the next run tries again. Nothing is moved automatically.
`last-update-result.json` lists them as `memory_held`, and the summary warns.
`site-manager update --force` applies the growth anyway.

### Phase 2.5: Suspended modules are patched (#890)

`module-manager suspend` stops a module to free memory; it no longer also stops it
being patched. After the app modules, each suspended module is handled one at a
time: if its guest fits on its node (`health-manager capacity --install`), it is
resumed, updated (its tests included) and suspended again. One that does not fit
is recorded as not patched — unless, in the maintenance window, pausing `pauseOk` modules
on its node makes room (below); the health check warns when a suspended module has not
been patched for 14 days. `suspend --no-update` keeps a module out, for one stopped
because it is broken. A marker (`/var/lib/tappaas/update-suspended-pass`) names the
module being patched; a run that dies mid-pass leaves it, and the next run suspends
that module again first. `last-update-result.json` records the pass as
`suspended_patch` (patched, failed, not_patched); a failed update counts as a failed
module.

### Pausing modules for room (#891)

Twice the run needs memory for a while: to start a suspended module and patch it, and to
move a node's HA guests onto the others before the node reboots (only HA guests move; the
others restart with the node). When it is not there, and only in the maintenance window —
the scheduled run with `automaticReboot`, or `site-manager update --allow-disruption` — the
run suspends modules whose owner set `pauseOk: true`, lowest `pausePriority` first (default
50; equal ones, the largest first), never a foundation module.
`health-manager capacity --room-for <module>` and `--drain <node>` say which.

What it paused is resumed once every module is patched and the nodes are rebooted, right
after Phase 3. The run keeps its own list in `/var/lib/tappaas/update-paused`, so a module
an operator suspended is never resumed by it; a run that dies leaves the list, and the next
run resumes those first. `last-update-result.json` records `paused_for_room` (paused,
resumed, not_resumed). Pausing never makes room for a module that grows — that room ends
when the others resume — so growth is held instead (above). Mark a module pausable with
`module-manager module modify <m> --set pauseOk=true [--set pausePriority=10]`.

### Phase 3: Node Reboot Pass

Governed by `automaticReboot` in `site.json`. See `cluster/reboot-cluster.sh`.

### Phase 4: Postgres Collation Reconciliation

A nixpkgs release move changes glibc, and Postgres then warns on **every connection** that the
collation version its databases were created with no longer matches the one in force. The warning
is usually benign — glibc's version string changes far more often than its ordering does — but left
alone it becomes permanent, and it would be indistinguishable from a future bump that genuinely
reorders text and therefore invalidates every text index.

`tappaas-collation-reconcile.sh --apply` settles it, and **earns** each refresh: for every database
whose recorded version has drifted, it verifies every btree index against the collation in force
with `bt_index_check(heapallindexed => true)` and only then runs
`ALTER DATABASE … REFRESH COLLATION VERSION`. A database whose indexes do not verify is reported
and **left warning** — a `REINDEX` is a data decision for a person, and silencing the warning is
precisely what must not happen there. The phase is cheap when there is nothing to do: one query per
Postgres guest.

Run it by hand any time; without `--apply` it reports and changes nothing:

```
tappaas-collation-reconcile.sh                  # report
tappaas-collation-reconcile.sh --apply          # verify, then refresh what passes
tappaas-collation-reconcile.sh --guest <fqdn>   # one guest
```

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
journald → Alloy → Loki for Grafana.

```bash
systemctl list-timers update-tappaas.timer     # what site.json currently asks for
journalctl -u update-tappaas.service
site-manager validate                          # checks the schedule, prints the OnCalendar
```

## What a run leaves behind

- **`config/last-update-result.json`** — the sweep's own record: `ok`, per-module tallies,
  `control_plane`, `path` (`unit` or `legacy`), the operator `request`, `deferred_changes`
  (disruptive changes held back for want of `rebootOk`, ADR-020 D8 — including a NixOS guest
  whose reboot `update-os.sh` did not take: `automaticReboot` off, a backup lock, or the
  controller itself, #730; `health-manager validate` shows which are still waiting) and `test_warnings`
  (checks that were already failing before a module's update, #635), and `backup_keys`:
  whether the last USB key stick holds the backup keys as they are now (#874; the summary
  warns on every run until it does). A run that stopped in
  `ExecStartPre` records the `stage` instead.
- **An exit code and a `result`** that tell a broken run from one that did its job:

  | `result` | Exit | When |
  |---|---|---|
  | `ok` | 0 | every module updated |
  | `degraded` | 3 | the run completed, but app modules failed (the unit counts it as success) |
  | `broken` | 1 | a foundation module failed, a shared service went down, the control plane is stale, or the reboot pass failed |

  `failed_foundation` lists the foundation modules that failed. `site-manager update` exits
  with the same 3 for a degraded run.
- **`config/update-tappaas.failures`** — one line per failed or degraded run, and per
  failure notice sent or not sent.
- **A notice to the site owner** for both: a broken run through `update-tappaas-failure.service`
  (the unit's `OnFailure`), naming the step that failed, and a degraded one from the unit's
  `ExecStopPost`, naming the modules. Both go to `site.json` `email` through a Proxmox
  node's mail system.
- **A security scan of what the run left running**: `tappaas-security-scan.service`, started
  on success and on failure, writes `config/sbom/site.cdx.json` and `cve-status.json` and
  mails the owner when a fixable CVE or a failed scan is new (ADR-011;
  `health-manager report security`). Only a run that wrote a result triggers a scan.
- **A read of the switches**: `tappaas-switch-read.service`, started the same way, runs
  `switch-manager interrogate --no-park` (it reads every controller and auto switch, and
  never parks or applies anything), then the `switch-ports` gate over what it read, and mails
  the owner when the gate has a finding it did not have after the last read (#860). The
  findings are kept in `config/switch-read.json`.

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
