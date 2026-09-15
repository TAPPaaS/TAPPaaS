# ADR-017 — Update scheduling and the mothership's own update

| | |
|---|---|
| **Status** | **Accepted** (2026-09-15) — v0.2; implementation in G0.3 (#471). D7 is decided but ships with the G0.1 migration runner. |
| **Version** | 0.2 |
| **Date** | 2026-09-15 |
| **Author** | Lars Rossen |
| **Parent** | [ADR-009 Composition Meta-Model](<ADR-009 - Composition Meta-Model.md>) (`<module>:<service>` coordinates) |
| **Refines** | [ADR-007d Site](<ADR-007d - Site.md>) (`site.json` as the site's single source of truth), [ADR-003 Dependency management](<ADR-003 - Dependency management in TAPPaaS.md>) (`dependsOn` ordering of the update loop) |
| **Related** | **#471** (implementation reminder for this ADR), **#357** (update window / channel — settled by D8), **#447** (schedule editing and listing), **#588** (`site-manager update`), **#595** (Phase 0 control-plane refresh), **#533** (ownership repair `ExecStartPre`), **#653** (pull hold), **#651** (failure notice), **#635** / **#633** (`--force` semantics), **#150** (cron retired in favour of the systemd timer), **#467** (ambient `<nixpkgs>` — closed by `a65c6c61`), **#515** (wheel polkit rule); [ADR-020](<ADR-020 - Declared-Field Change Model (validate, drift, modify).md>) D8 owns the `--force` / `rebootOk` rule; [ADR-007e](<ADR-007e - Health.md>) v1.3 owns the notification target. **Owner:** `tappaas-cicd` (unit definitions, self-update), `site-manager` (schedule rendering, `update`) |
| **Changelog** | v0.1 — initial draft: hoist the mothership self-update into the unit via `ExecStartPre=+`, render `OnCalendar` from `site.json`, delete the in-process schedule gate, deprecate `--force`, introduce `site-manager site update` (with progress/completeness reporting), restate `updateSchedule` as a named object in which `daily` carries no weekday. v0.2 — Erik Daniel's review on #471 (2026-08-19, 2026-09-01) and the operator's decisions of 2026-09-15, checked against `main`: D3 has three `ExecStartPre` lines (the #533 repair stays first), takes over Phase 0 (#595) and the hold-aware pull (#653), makes a failed pull or rebuild abort the run, and relies on the #651 notice; D1 pairs the gate deletion with `Persistent=false`; the operator path is the existing `site-manager update` (#588), which starts the unit and hands per-run options over in a one-shot request file; `update-tappaas --force` is deprecated and `site-manager update --force` adds `--ignore-test-failure` under ADR-020 D8's `rebootOk` rule; D6 targets `validate-site.sh`/`site-fields.json`, not the legacy validator; D7 keeps accepting the legacy triple and leaves the in-place rewrite to a G0.1 migration; new D8 settles #357; new *Bootstrap* section for the first activation; #467 recorded as closed by `a65c6c61`; counts and line references brought up to date. Accepted 2026-09-15 with two operator rulings: D7's object form and its rewrite are deferred to the G0.1 migration runner (this release keeps the triple); the disruption window opens only for the scheduled run or an operator run with `--force` (D8, ADR-020 D8). |

## Context

`update-tappaas` is triggered by `update-tappaas.timer`, which fires **hourly**
(`tappaas-cicd.nix:325–333`). The script then reads `.updateSchedule` from `site.json` and
decides whether this particular tick is the one that should do work
(`main.py:236–318`). Two schedulers in series: systemd decides *when to ask*, Python decides
*whether to act*.

That indirection is the backdrop for a failure that ran undetected for at least a month.

### The failure

The `tappaas-cicd` module updates the mothership itself, and its `update.sh` ended in:

```bash
sudo nixos-rebuild switch --flake ".#${VMNAME}" --impure
```

`update-tappaas.service` sets `NoNewPrivileges = true`. The kernel's `no_new_privs` latch is
inherited by every descendant and **cannot be cleared**, so setuid binaries stop conferring
privilege and `sudo` aborts before doing anything:

```
sudo: The "no new privileges" flag is set, which prevents sudo from running as root.
```

The scheduled run therefore failed structurally, every time, while the identical command run
by hand from an operator shell succeeded — a login process carries no such latch. Every
scheduled run recorded in the journal failed on `tappaas-cicd` (2026-08-04, 08-11, 08-17,
08-18); every manual run passed. The repair reflex — run `update-tappaas --force` by hand —
is exactly the path that cannot reproduce the fault.

The message itself only became visible on 2026-08-17, when `3c6379a` began tee-ing
`nixos-rebuild` output. Before that the same failure reported as a bare `exit 1`. The
interim fix (*Interim state*, below) has since unblocked the nightly without changing the
shape of the problem.

### Measured, not assumed

Probed on the reference cluster (2026-08-18) using transient units carrying the production
hardening:

| Probe | Result |
|---|---|
| `sudo` under `NoNewPrivileges=true` | refused, as above |
| `ExecStartPre=+…` under the same hardening | ran as **root** and wrote to `/etc` (read-only for the main process); `ExecStart` still ran as `tappaas`, still sandboxed |
| `ProtectSystem=strict` — `/etc`, `/nix/store`, `/var/lib`, `/root` | read-only |
| `ProtectSystem=strict` — **`/home/tappaas`, `/home/tappaas/bin`** | **writable** |
| `systemctl start` over D-Bus, inside vs outside the sandbox | byte-identical polkit response; authorization is decided on the caller's uid and `NoNewPrivileges` plays no part |

Since then the mechanism has left the probe stage: #533 gave the production unit its own
`ExecStartPre = "+-/home/tappaas/bin/tappaas-repair-ownership.sh"` (`tappaas-cicd.nix:272`),
on the exact unit D3 targets, under the same hardening.

Three things follow. First, `ExecStartPre=+` is a proven mechanism for granting exactly one
step full privilege while the rest of the unit keeps its sandbox. Second, the sandbox
protects less than its comment claims: `/home/tappaas` holds the repo, every script, `.ssh`
and four credential files, and the service holds operator SSH to all three Proxmox nodes.
Third, since #515 polkit grants `wheel` every unit verb (`tappaas-cicd.nix:225–231`) and
`tappaas` is in `wheel` (`:115`), so the sandboxed sweep can `systemctl start` any unit. The
hardening's practical effect is to block `nixos-rebuild` and very little else.

### Three further defects the same investigation surfaced

1. **The schedule is unvalidated.** Neither validator checks it.
   `validate-configuration.sh` validates the retired `configuration.json`
   (`validate-configuration.sh:37`) at its nested `.tappaas.updateSchedule` (`:246`); pointed
   at `site.json` it finds nothing and logs *"No updateSchedule configured (optional field)"*.
   `validate-site.sh`, behind `site-manager validate`, checks `site.json` against
   `site-fields.json`, where `updateSchedule` is only `"type": "array"`
   (`site-fields.json:175–183`). The reference site's `["daily", "Tuesday", 2]`, in which
   `"Tuesday"` is inert under `daily`, was therefore never flagged.
2. **A partial update reports as a clean failure.** The control-plane refresh relinks
   `/home/tappaas/bin` *before* the rebuild and succeeds; the rebuild then fails. The
   mothership is left with `bin` ahead of its system generation, and the remaining modules
   are updated by half-updated tooling. On 2026-08-18 the bin symlinks were stamped 02:06
   while the system generation was still #4 from 08-16 15:16. (Since #595 the relink runs
   even earlier, as the sweep's Phase 0.)
3. **Manual and scheduled are different code paths**, which is *why* this could hide.

### Why `--force` is the wrong shape

`update-tappaas --force` skips the schedule gate and nothing else (the
`if not args.force and not should_update_now(…)` test in `main()`; the artefact records it as
`forced`). It has no bearing on privilege, yet it is the documented "reconcile now" entry
point in 22 operator-facing lines, and the two callers that run it — `rest-of-foundation.sh`
and `site-manager update` (#588) — run the *script*, not the *unit* (D5 lists them all).
`site-manager update` passes its own options as environment variables to that script
(`client.ts:192–203`). The official operator path is therefore still structurally
incapable of reproducing a scheduled failure.

## Decision

### D1 — systemd owns the calendar; the in-process gate is deleted

`should_update_now`, `parse_schedule` and `WEEKDAYS` (`main.py:102–110`, `236–318`) leave
the unit's path. The timer fires when — and only when — an update is due.

| `site.json` `updateSchedule` (D7 shape) | `OnCalendar` |
|---|---|
| `{"frequency": "none"}` | no timer installed |
| `{"frequency": "daily", "hour": 2}` | `*-*-* 02:00:00` |
| `{"frequency": "weekly", "weekday": "Tuesday", "hour": 2}` | `Tue *-*-* 02:00:00` |
| `{"frequency": "monthly", "weekday": "Tuesday", "hour": 2}` | `Tue *-*-01..07 02:00:00` |

systemd's calendar syntax expresses every case the old 3-tuple did, including "first
`<weekday>` of the month" (`main.py`'s `day_of_month > 7` rule), which becomes
`*-*-01..07` natively.

**Two edits, one change: the gate goes and `Persistent=false` comes with it.** Today's timer
sets `Persistent = true` (`tappaas-cicd.nix:330`): a tick missed while the host was down
fires at boot, and the gate rejects it unless the boot falls in the scheduled hour. Delete
the gate alone and that catch-up tick becomes a full sweep on every boot after downtime. The
rendered timer (D2) therefore sets `Persistent=false`: a missed run is *skipped*, not caught
up — a catch-up firing moments after boot risks compounding whatever caused the downtime —
and the next due time runs normally.

The gate's code is not deleted in the same release: it survives, unreachable from the new
unit, as the old unit's fallback during the first activation, and goes with the interim path
(see *Bootstrap*).

### D2 — the timer is rendered from `site.json`, not declared in nix

`systemd.timers.update-tappaas` is **removed from `tappaas-cicd.nix`** (`:325–333`). It is
today the sole creator of the schedule: the legacy crontab installer was retired in #150 and
`update-cron.sh` no longer exists anywhere in the tree.

A new root oneshot `update-tappaas-schedule.service` (`WantedBy = [ "timers.target" ]`) reads
`.updateSchedule` (D7 object, or the legacy triple with a deprecation warning), validates the
mapped expression with `systemd-analyze calendar`, writes
`/run/systemd/system/update-tappaas.timer` (with `Persistent=false`), reloads and starts it.
`none` renders no timer and stops any running one. It runs at boot, after every
self-rebuild (D3), and whenever `site-manager site modify` changes the schedule — a plain
`systemctl start` by `tappaas`, authorised by the #515 wheel rule.

Rendering into `/run` rather than `/etc` means the schedule is re-derived from `site.json` at
every boot and on demand, so `site.json` cannot drift out of agreement with the running
timer and nothing persistent is left behind to reconcile. Runtime-written units are not new
ground: `backup/lib/pbs-immutable.sh:62–78` writes a service and timer at run time on the
PBS host — into `/etc`, which is the difference chosen against here.

### D3 — the mothership's self-update leaves the module loop

The privileged step moves into the unit itself. The #533 line stays first:

```nix
ExecStartPre = [
  "+-/home/tappaas/bin/tappaas-repair-ownership.sh"  # root, non-fatal: heal ownership (#533)
  "/home/tappaas/bin/tappaas-self-prepare.sh"        # tappaas, sandboxed: pull + relink + builds
  "+/home/tappaas/bin/tappaas-self-rebuild.sh"       # root, outside the sandbox: nixos-rebuild switch
];
ExecStart = "/home/tappaas/bin/update-tappaas";
RuntimeDirectory = "update-tappaas";                 # per-run state; removed when the unit stops
```

The prefixes differ on purpose:

| line | prefix | why |
|---|---|---|
| repair | `+-` | root, to `chown` outside `ReadWritePaths`; `-` because a failed repair must not block the sweep — it heals drift, it is not a precondition. First, because it heals the checkout the next line pulls into. |
| prepare | none | needs no privilege: the checkout, `~/bin` and the gcroots belong to `tappaas` and are writable in the sandbox (Phase 0 has run inside this unit since #595). No `-`: a failure aborts the unit. |
| rebuild | `+` | the only step needing root; `+` escapes `User=`, `ProtectSystem=` and `PrivateTmp=` for this line only. No `-`. |

No `sudo`, no polkit rule, no second unit. The scripts carry `.sh` because
`refresh-control-plane.sh:146` links `scripts/*.sh` into `~/bin` under their own names.

`tappaas-self-rebuild.sh` runs `nixos-rebuild switch --flake .#<vm> --impure` from the
`tappaas-cicd` directory with `HOME=/var/lib/tappaas-rebuild`: root still needs the
`safe.directory` grant to open the operator's checkout, which nix's libgit2 reads only from
`$HOME/.gitconfig` (`tappaas-cicd.nix:172–196`, and the note at `:187–188`). That HOME and
its tmpfiles lines (`:520–524`) outlive the interim helper. After the switch it starts the D2
renderer and writes `/run/update-tappaas/rebuilt`.

**What moves where.** The `tappaas-cicd` update is spread over three places today:

| step | today | under D3 | why |
|---|---|---|---|
| pull (hold-aware), relink `~/bin`, 11 flake builds — `refresh-control-plane.sh` | update-tappaas Phase 0 (`refresh_control_plane()` in `main.py`, #595); again in `pre-update.sh:21–33` | `tappaas-self-prepare.sh` runs it; Phase 0 leaves `main.py` | the toolchain is current *before* it is used |
| `nixos-rebuild switch` | `update.sh:33–72`, through `tappaas-rebuild@` | `tappaas-self-rebuild.sh` (`+`) | the only step needing privilege |
| second component refresh after the rebuild | `update.sh:94–105` (every component's `update.sh` execs its `install.sh`) | deleted | repeats the prepare step's builds |
| `module-fields.json` compose, `opnsense-ensure-patches`, zones merge and check (`pre-update.sh:35–173`); the `cluster:vm` / `cluster:ha` converge | module loop | **stays in the loop** | `tappaas-cicd.json` declares `dependsOn: [cluster:vm, cluster:ha]`; it must run after `cluster` |

`pre-update.sh` keeps its refresh call, so `module-manager module modify tappaas-cicd` still
stands alone (idempotent; `pre-update.sh:13–17`). Phase 0.5 (node reconcile) and
`ensure_default_environment` stay in `main.py`: they are sweep steps, not self-update.
`tappaas-cicd.json` declares `provides: []`, so no module depends on it and hoisting violates
no ordering. Pulling in `ExecStartPre` is acceptable only because D1 makes the timer fire
when a run is due; under the hourly timer it would pull and rebuild every hour, which is why
Phase 0 sits after the gate today (see its comment in `main()`).

**The pull, and what is fatal.** `refresh-control-plane.sh` keeps its exit-code contract
(`:17–24`); the prepare step maps it:

| outcome | today (Phase 0) | under D3 |
|---|---|---|
| a repository fails to sync (`:115`), or unpushed commits block it (rc 2, `:114`, #433) | warning; sweep continues | **fatal** — the unit fails before the rebuild and the sweep — unless that repository has an active hold |
| repository held (#653, `:88–96`) | pull skipped, warned | same: skipped, never a failure; an expired hold warns and pulls again |
| a component group fails to build (rc 10) | `stale`, sweep continues loudly | same: recorded as `control_plane=stale`; the run ends not-ok |
| checkout unusable (rc 1) | `failed`, sweep continues | fatal |

The fatal pull needs a distinct exit code for a failed sync; today the subshell's result
ends in a warning. `--no-git-pull` (D4) skips the pull as a whole (`TAPPAAS_NO_GIT_PULL=1`,
`:76`). A site that runs on local commits holds its repository (#653) rather than relying
on a warning.

**Two defects close.** An `ExecStartPre` failure aborts the unit and `ExecStart` never runs,
so a failed pull or rebuild can no longer be followed by a sweep on half-updated tooling
(a component build failure stays non-fatal by the #595 contract, and is reported). And
`ExecStart` launches the *newly linked* `update-tappaas`, instead of old code relinking its
own binary mid-flight.

**Not silent.** An `ExecStartPre` failure fails the unit exactly as a failed sweep does, so
`OnFailure` (`tappaas-cicd.nix:261`) runs `update-tappaas-failure.service`, which mails
`site.json` `email` through a Proxmox node's mail system (`notify-update-failure.sh`, #651;
ADR-007e v1.3 owns the target). The prepare and rebuild steps write their stage and outcome
into `last-update-result.json` before exiting non-zero, so the notice names the failing
stage instead of quoting the previous sweep's result.

**#467 is already closed** — by `a65c6c61` (2026-08-17), not by v0.1's `pinned-pkgs.nix`.
The 11 components are built as flake packages against `flake.lock`
(`flake.nix:15–39`, `component-install-lib.sh:51–65`), so the build D3 hoists no longer reads
the ambient `<nixpkgs>`. The `pkgs ? import <nixpkgs> { }` default survives in 12
`default.nix` files: `tappaas-cicd/manager/{backup,environment,health,module,network,people,site}-manager/`,
`tappaas-cicd/controller/{identity-controller,node-provisioner,opnsense-controller}/`,
`tappaas-cicd/update-tappaas/`, and `network/scripts/switch-controller/`. It is evaluated only
by a standalone `nix-build`: the fast tests of three controllers
(`identity-controller/test.sh:10`, `node-provisioner/test.sh:20`,
`opnsense-controller/test.sh:24`), and `switch-controller`, which nothing builds
automatically (`tappaas-cicd/controller/switch-controller` is a bash component).
`lib/nix/pinned-pkgs.nix` does not exist and is no longer a D3 prerequisite (see *Open*).

### D4 — `site-manager update` starts the unit

The operator path is the existing verb (#588,
`site-manager update [--dry-run] [--force] [--no-git-pull]`), not a new one. It stops running
the script and starts the **unit**:

```
site-manager update                 # start update-tappaas.service now, follow it, report
site-manager update --dry-run       # repository drift + the sweep plan; starts nothing
site-manager update --force         # D5
site-manager update --no-git-pull   # run on whatever is checked out
```

`systemctl start` runs as `tappaas` without `sudo`: the #515 rule authorises it, and
site-manager refuses root anyway (#533). Under D3 the self-update lives in the unit, so a bare
`update-tappaas` no longer updates the mothership; it warns when started outside the unit
(`UNDER_SYSTEMD`, `main.py:115`). There is one code path, and the operator exercises the one
the timer does.

**Per-run options.** A unit takes no arguments and `systemctl start` does not carry the
caller's environment, so today's `TAPPAAS_MODULE_FORCE` / `TAPPAAS_NO_GIT_PULL`
(`client.ts:192–203`) stop at the unit boundary. Nothing existing fits: the #653 hold marker
(`config/.repo-hold/<repo>.json`) is per repository and lasts until it expires. site-manager
therefore writes a one-shot request:

```jsonc
// ~/config/.update-request.json — written by site-manager update, claimed by the unit
{ "force": false, "noGitPull": true, "requestedBy": "lars", "at": "2026-09-15T14:02:11+02:00" }
```

- **Claim.** The prepare step first moves it to `/run/update-tappaas/request.json`. The
  runtime directory is removed when the unit stops, so a request is consumed by exactly one
  run — a failing one included — and can never turn the next timer run into an operator run.
- **Use.** The prepare step applies `noGitPull`; `update-tappaas` applies `force` (D5) and
  records the request in `last-update-result.json` in place of `forced`. A timer run has no
  request, which is also how `update-tappaas` tells a scheduled pass from an operator run (D8).
- **Guards.** site-manager refuses while the unit is active (a start would only join the
  running run, and its request would wait for the next timer), and deletes the request if the
  start fails. The prepare step discards a request older than ten minutes, with a warning.

**Following the run.** Driving a unit rather than a script breaks two things the operator got
for free: output no longer belongs to the terminal, and `Ctrl-C` no longer stops the work.
Both are stated at the point of use. site-manager streams this invocation's journal
(`journalctl -f _SYSTEMD_INVOCATION_ID=<id>`); on start it prints:

```
started update-tappaas.service (this run continues if you detach)
  follow:   journalctl -fu update-tappaas.service
  status:   systemctl status update-tappaas.service
```

and on exit the run's own summary line with the checks that establish completeness:

```
update-tappaas completed: <ts> | control_plane=refreshed total=10 succeeded=10 failed=0 not_attempted=0 skipped=0 reboot=ok
  verify:   jq .ok ~/config/last-update-result.json     → true
  verify:   site-manager update --dry-run               → no repository drift remains
```

`site-manager update` returning 0 only means the unit exited 0. "Complete" means the artefact
reports `ok: true` **and** a dry run reports no drift — a run can exit non-zero with nine of
ten modules correctly updated, which is exactly the state the 2026-08-18 nightly was in.

**Dry run.** Starts nothing. It probes each repository against its origin tip (commits behind
`origin/<branch>`; a held repository shows as held), then prints `update-tappaas --dry-run`'s
plan. The repository-reconcile planner checks only clone and branch today (`clone-repo`,
`checkout-repo` in `reconcile.ts`), so the behind-origin probe is new.

### D5 — `update-tappaas --force` is deprecated; `site-manager update --force` keeps a meaning

`update-tappaas --force` remains in `argparse`, logs a deprecation warning and has no effect:
the gate it skipped is gone (D1). The flag is removed in a later release.

`site-manager update --force` (carried by the request, D4) means, for that run:

- every `module-manager module modify` gets `--ignore-test-failure`: a module updates even
  when its pre-update test fails fatally (#635; `update-module.sh:547–551`);
- the disruption window opens for `rebootOk: true` modules only; `rebootOk: false` keeps its
  disruptive changes deferred (#633). The sweep never forwards `module modify --force`.

**ADR-020 owns this rule** (D8; v0.9, `5c77a7ca`, adds the `--ignore-test-failure` half,
which `bb3f07b6` implements in `update_module()`). ADR-017 only carries the flag to the unit.

**Call sites.** `update-tappaas.*--force` matches 55 lines in 31 files across `src/`, `docs/`
and `release/` (this ADR excluded; `release/` has none):

| kind | lines | where they are | where they move |
|---|---|---|---|
| runs it | 2 | `rest-of-foundation.sh:134`; site-manager `client.ts` (`runUpdate`) | `site-manager update`; `client.ts` becomes D4's unit start |
| tells the operator to run it | 22 | `install.sh:196,243`; `provision.ts:394`; the `--dry-run` hint in `main.py`; `INSTALL.md:352`; `cluster/INSTALL.md:48`; `backup/RESTORE.md:362,394,461`; site-manager `README.md` (node add); `update-tappaas/README.md:8,18,21`; runbooks in `docs/design/` (`438-variant-retirement-runbook.md:155`, `ADR-007-migration-runbook.md:135,250,262,263`, `ADR-014-migration-runbook.md:53,163`, `node-provisioning.md:15,255`) | `site-manager update` |
| explains the flag (ADR-020 D8's "run now" vs "authorize disruption") | 23 | ADR-020 (6), ADR index row, `ADR-020-field-change-realization.md`, `schemas/README.md`, `module-fields.json` and its test fixture, module-manager `README.md` and `types.ts`, `cluster/services/vm/update-service.sh`, `main.py` (2), `update-tappaas/test.sh` (2), site-manager `DESIGN.md`, `README.md` (update) and `main.ts`, `tappaas-cicd.nix:134`, `update.sh:20` | reworded: `site-manager update` is the run-now lever; ADR-020's text through its v0.9; `module-fields.json` feeds generated README blocks, so regenerate |
| history | 8 | `ADR-007-implementation-tracker.md` (2), `ADR-consolidation-outstanding.md`, `ADR007-post-implement-refactor.md` (5) | unchanged — they record what was run |

**Install time starts the unit.** `rest-of-foundation.sh` runs `site-manager update`, not a
bare `update-tappaas`. It runs on the cicd after the platform is up, when the unit already
exists (the cicd is built from `tappaas-cicd.nix`), and its final sweep is the first chance to
see the scheduled path fail — the failure this ADR starts from sat for a month because
install and repair used the other path. The cost is small: the pull finds the tip it just
cloned and the switch finds its own generation. A bare `update-tappaas` would skip the
self-update anyway (D3). An install from an unpushed tree passes `--no-git-pull`.

### D6 — the schedule is validated against what actually runs

`validate-site.sh` (behind `site-manager validate`) and `site-fields.json` enforce D7's
per-frequency field rules, warn on the legacy triple, and validate the *rendered* expression
with `systemd-analyze calendar` rather than reimplementing calendar rules in bash. The
renderer (D2) uses the same mapping. Validation and mechanism cannot then drift — and unlike
today, a schedule that means nothing is refused rather than ignored.
`validate-configuration.sh` validates the retired `configuration.json` and is not changed.

### D7 — `updateSchedule` becomes a named object; `daily` carries no weekday

> **Decided, deferred (2026-09-15).** The object form below is the target, but it ships with
> the G0.1 migration runner, together with the rewrite of existing sites. The release that
> implements D1–D6 keeps the `[frequency, weekday, hour]` triple: the renderer (D2) and the
> validator (D6) read it, a weekday under `daily`/`none` is reported as inert and never
> honoured, and `site show` stops printing it (#447). No config re-schema ships without its
> migration (plan §3 G0.1).

The present shape is a positional triple, `[frequency, weekday, hour]`, in which `weekday` is
meaningless under `daily` and `none` but must still be occupied. The reference site holds
`["daily", "Tuesday", 2]` — a value that has never been read, on a site that updates every
day. Combined with the unchecked schema (D6) nothing could report it, and it read as a weekly
schedule to anyone glancing at `site.json` — or at `site-manager site show`, which prints
any stored weekday (`main.ts:256–261`, #447).

`updateSchedule` therefore becomes an object, and `weekday` is **refused** where it has no
meaning rather than merely ignored:

```jsonc
"updateSchedule": { "frequency": "none" }
"updateSchedule": { "frequency": "daily",   "hour": 2 }
"updateSchedule": { "frequency": "weekly",  "weekday": "Tuesday", "hour": 2 }
"updateSchedule": { "frequency": "monthly", "weekday": "Tuesday", "hour": 2 }
```

| field | `none` | `daily` | `weekly` | `monthly` |
|---|---|---|---|---|
| `frequency` | required | required | required | required |
| `weekday` | **refused** | **refused** | required | required |
| `hour` | refused | required | required | required |

`hour` is required rather than defaulted to 2, so the schedule a site runs on is always
written down.

Named fields are what make the rule enforceable. A shortened positional array (`["daily", 2]`
vs `["weekly", "Tuesday", 2]`) would express the same intent in a smaller diff, but element 1
would change meaning with the frequency — reintroducing exactly the ambiguity that let
`["daily", "Tuesday", 2]` sit unnoticed. Under D7 a weekday under `daily` is a schema
violation, caught by `validate`, not a value nobody reads.

**Editing and listing (#447).** `site modify --updateFrequency / --updateWeekday /
--updateHour` already exist (`main.ts:63–65`, `328–359`, since `f1f73fbc`): they edit by
component and already null the weekday under `daily`/`none`. They keep their names — the
camelCase field-flag style of `site modify` (`--email`, `--automaticReboot`) — and write the
D7 object; no combined flag is added. `site show` prints the D7 meaning: no weekday under
`daily`, including for a legacy triple that stores one.

**Migration.** With the runner: new writes use the object (`site modify`, `create-site.sh`),
the triple is rewritten by a numbered migration, and the renderer and validator accept the
triple only until that migration has run. Until the runner exists nothing changes shape. Rewriting
`site.json` is a config migration, and the 2.1 plan ships re-schemas through the G0.1
migration runner (`release-2.1-implementation-plan.md` §3 G0.1, *Migration framework*),
which does not exist yet; its first release carries no migrations (the Wave 0 exit gate is
"Runner released with no migrations", §10.3). The rewrite — `["daily", "Tuesday", 2]` →
`{"frequency": "daily", "hour": 2}`, with the dropped weekday reported — becomes a numbered
migration once the runner exists, and the triple is accepted until then. v0.1's precedent,
`ensure_default_environment` (`main.py:192`), is itself the kind of ad-hoc backfill G0.1
(#652) replaces.

### D8 — update window and channel (#357)

- **Window.** The update window is the site's `updateSchedule` (D7), rendered by D2: one per
  site. No per-Environment or per-App override for now; ADR-007c keeps `updateWindow` out of
  the Environment schema. A later override would be a new field that falls back to this one.
- **Channel.** Stays per repository: `site.json` `repositories[].branch`
  (`site-fields.json:214–217`), as #357 itself records; changed with
  `site-manager repository modify <name> --branch`. No `updateChannel` field.
- **Scheduled pass.** A run without a request (D4) is ADR-020 D8's scheduled pass: with
  `automaticReboot` it opens the disruption window for `rebootOk` modules; an operator run
  opens it only with `--force`. Today `disruption_window_open()` opens it whenever
  `automaticReboot` is true, for operator runs too, because the script cannot tell the two
  apart; the request makes the distinction available. **Decided (2026-09-15):** only the
  scheduled run with `automaticReboot`, or an operator run with `--force`, opens the window;
  a plain `site-manager update` never disrupts a guest. ADR-020 D8 owns the rule.

#357 closes against this ADR, design only.

## Bootstrap — the first activation

The first activation of a generation that introduces a privileged mechanism cannot go
through that mechanism (Erik Daniel, #471, 2026-08-19). The interim fix proved it: on a host
that had never run that generation, `update.sh` asked for `tappaas-rebuild@<vm>`, which
existed only in the built-but-not-switched closure, and polkit refused. The site needed one
manual switch.

D3 has the same shape. Let R be the release that carries it:

| run | unit | what runs | result |
|---|---|---|---|
| 1 — the first due tick after R reaches the site | **old**: `+-` repair, then `update-tappaas` | R−1's `update-tappaas`, loaded before the pull: schedule gate; Phase 0 pulls R, relinks `~/bin`, builds R's components; Phase 1 reaches `tappaas-cicd`, whose R `update.sh` finds no `/run/update-tappaas/rebuilt` and rebuilds through the interim `tappaas-rebuild@<vm>`, authorised by the *running* generation's polkit rules; it then starts the D2 renderer. The switch installs the new unit and drops the nix timer; the sweep finishes under R−1's process. | mothership on R; the new `ExecStartPre` has **not** run |
| 2 onwards | **new**: repair → prepare → rebuild → `update-tappaas` | D3 as specified; `update.sh` sees `rebuilt` and skips its rebuild | D3 in effect |

What this requires of R:

1. **R keeps the interim path**: `tappaas-rebuild@.service` and `update.sh`'s fallback
   (rebuild through it when `/run/update-tappaas/rebuilt` is absent). Removing the unit in R
   would have run 1's switch delete the unit the switch is running under.
2. **R's `update-tappaas` keeps a legacy path** for the old unit (started by systemd, no
   `/run/update-tappaas/prepared` marker): the schedule gate and Phase 0, exactly R−1's
   behaviour, and it claims a request file itself. Without it, a failed rebuild in run 1
   leaves the old hourly `Persistent=true` timer starting R's gateless binary: a full sweep
   every hour and after every boot, with no pull (Phase 0 moved), so no fix could arrive.
3. **`refresh-control-plane.sh` keeps its path and exit codes**: R−1's `update-tappaas` calls
   it by repository path in run 1 (`REFRESH_CONTROL_PLANE_CMD`, `main.py:45–48`).
4. **The scoped polkit rule can go in R** (`tappaas-cicd.nix:204–213`): run 1 is authorised
   by the running generation, and afterwards the #515 wheel rule covers the fallback.

**When the interim path can go.** Not "one release later" by itself. A site on `stable`
pulls the branch tip, so a site that was down, held (#653) or on a monthly schedule can jump
from R−1 straight to R+1. The helper unit, the `update.sh` fallback and the legacy path in
`update-tappaas` are removed together, in the first release whose notes name R or later as
the oldest supported upgrade source — a rule for the *Config migrations & upgrade path* ADR
(plan §10.4). Until then D1's gate code stays, reachable only from the old unit.

**A stuck site.** Symptoms: run 1 fails in `tappaas-cicd` at the rebuild (the #651 notice
names it), or after a due run `systemctl cat update-tappaas.service` still shows only the
repair line. Causes: the running generation predates the interim fix (2026-08-18, no
`tappaas-rebuild@`), or the rebuild itself failed. Remedy, on the cicd as `tappaas`, from a
login shell (no `NoNewPrivileges` latch, so `sudo` works — the procedure used on 2026-08-19):

```bash
cd ~/TAPPaaS/src/foundation/tappaas-cicd
sudo nixos-rebuild switch --flake .#tappaas-cicd --impure
site-manager update
```

If the rebuild itself fails, the legacy path keeps the site on its old schedule; fix forward
(plan §10.2 rule 5), holding the repository meanwhile if the site must not pull.

## Alternatives considered

| Alternative | Why not |
|---|---|
| **Root helper unit + polkit rule** — `update.sh` calls `systemctl start --wait tappaas-rebuild@<vm>.service`; polkit authorises the caller's uid | Verified to work, and adopted as the **interim fix** ahead of this ADR (see *Interim state*). Not the target: it leaves the self-update inside the module loop and keeps the manual and scheduled paths distinct. Its scoped rule is already redundant with #515's wheel rule. |
| **Drop `NoNewPrivileges` + `ProtectSystem` from the unit** | One line, and the measurements above show the sandbox buys less than it appears to. Still rejected: it surrenders the `/etc`, `/nix`, `/var` protection for all module updates to obtain privilege for one step of one. |
| **Run the whole service as root** | No `sudo` needed anywhere — but the repo, `~/.ssh`, the operator key and all git ownership are `tappaas`'s. Running the loop as root breaks `repo-sync` and inverts the ownership model; the managers refuse root since #533. |
| **nix reads `site.json` at rebuild time** (`builtins.fromJSON`; `--impure` is already in use) | Most consistent with the declarative model and needs no new machinery, but a schedule change then takes effect only after a rebuild, so `site.json` can silently lie in between — and it makes the schedule depend on the very rebuild that has been failing. |
| **`site-manager` writes an `/etc` drop-in directly** | Simplest and immediate, but leaves persistent state that a `nixos-rebuild` will not reconcile, so `/etc` and `site.json` can diverge with nothing to detect it. |
| **Keep the hourly timer + gate and fix only `sudo`** | Smallest diff, but preserves both root causes: the double scheduler, and manual/scheduled being different code paths. |
| **A new `site-manager site update [--apply]`** (v0.1) | `site-manager update` already exists (#588) with `--dry-run`, `--force` and `--no-git-pull`; a second verb would split the operator path again. |
| **Per-run options via `systemctl set-environment`** | Manager-wide and persistent until unset: it outlives the run and leaks into the next timer run. |
| **Per-run options via a template `update-tappaas@<opts>.service` or `systemd-run`** | A second unit name or a transient unit: timer and operator runs diverge again, with separate `Result` and `OnFailure` — the split D4 removes. |

## Schema changes

- **`site.json` `updateSchedule`** — unchanged in this release (the triple). D7's object form
  and its rewrite ship with the G0.1 migration runner.
- **`validate-site.sh`** — reports a weekday under `daily`/`none` as inert, and runs
  `systemd-analyze calendar` on the mapped expression.
- **`site-manager`** — `site modify`'s three schedule flags start the D2 renderer after they
  write; `site show` prints no weekday under `daily`/`none` (#447).
- **`~/config/.update-request.json`** — new, transient, one run's options (D4). Not site
  configuration.
- **Not changed:** `validate-configuration.sh`; no `module-catalog` change; no `zones.json`
  change.

## Consequences

- **Operator output moves to journald.** `site-manager update` drives a unit, so the live
  output of today's sweep must be reproduced by streaming that invocation's journal. Losing
  that stream would be a real regression in operability.
- **A failed self-update now blocks the whole run.** That is the intent — today it does not,
  and the remaining modules proceed on half-updated tooling — but a transient forge outage
  can stop a night's updates. The #651 notice tells the operator; a hold (#653) is the lever.
- **A site with local commits and no hold now fails its run** instead of warning (#433,
  rc 2). The hold is how such a site keeps sweeping.
- **Schedule changes take effect immediately**, without a rebuild, and survive reboot.
- **The unit's `Result` becomes meaningful.** With no hourly no-op runs, nothing overwrites
  a failed sweep's result (the reason #506 needed a breadcrumb file).
- **`update-tappaas` invoked bare no longer updates the mothership.** Anyone with the muscle
  memory must move to `site-manager update`; D5's warning is the migration aid.
- **`test.sh` Test 6** keeps its timer-active and cron-guard assertions (`test.sh:217–234`),
  accepts no timer under `none`, repoints the failure hint from `tappaas-cicd.nix` to the
  renderer, and checks that the rendered `OnCalendar` matches `site.json`.
- **`--impure` is not widened.** It remains needed only for
  `/etc/nixos/hardware-configuration.nix`, because the schedule is not read by nix.

## Interim state (to be reverted by this ADR)

Ahead of D3 the scheduled run is unblocked by the polkit alternative (`9e1523cc`, `ed735c5a`,
2026-08-18), all on `main`: a root `tappaas-rebuild@.service` (`tappaas-cicd.nix:147–170`), a
polkit rule letting `tappaas` start it (`:204–213`), and `update.sh` calling
`systemctl start --wait` in place of `sudo nixos-rebuild` (`update.sh:33–72`). Since #515
(`3649dfc6`) a second rule grants `wheel` every unit verb (`:225–231`), which already covers
the first.

Implementing D3 removes the scoped polkit rule. The helper unit and `update.sh`'s call become
the fallback the first activation needs, and are removed as *Bootstrap* describes. The
`safe.directory` HOME (`:172–196`, `:520–524`) stays: D3's rebuild needs it too.

## Open (deferred to implementation)

- **`switch-to-configuration` restarting its own invoker.** A rebuild that changes
  `update-tappaas.service` may restart the unit the rebuild runs under. The same exposure
  exists today (#533 and #651 both changed the unit), run 1 of *Bootstrap* is exactly this
  case, and D3's rebuild runs inside the unit. `restartIfChanged = false` on
  `update-tappaas.service` is the obvious candidate; to be tested deliberately before R ships.
- **The 12 ambient `default.nix` defaults.** Off the unit's path since `a65c6c61`, but
  ADR-011 counts on v0.1's `lib/nix/pinned-pkgs.nix` for `sbomnix` provenance. Replace them,
  point ADR-011 at the flake packages, or leave both.
- **The G0.1 runner's slot.** The plan runs migrations from `pre-update.sh`, which runs in
  `tappaas-cicd`'s slot after `cluster`; the prepare step is the one place before every
  module.
- **The oldest supported upgrade source** that lets the interim path go (*Bootstrap*).
- **Whether `site-manager update --dry-run` should also report module drift**, not just
  repository drift.

## Acceptance

- [ ] A scheduled run completes `tappaas-cicd` with no `sudo` in the path.
- [ ] `update-tappaas.service` declares D3's three `ExecStartPre` lines in order, prefixed `+-`, none, `+`, and `RuntimeDirectory=update-tappaas`.
- [ ] A failed pull (no hold) or a failed rebuild fails the unit before `ExecStart`; no module update runs; the #651 notice names the stage.
- [ ] A held repository is skipped by the prepare step and does not fail the run; unpushed commits without a hold do.
- [ ] Phase 0 no longer runs from `update-tappaas` under the new unit; `update.sh`'s post-rebuild component refresh is gone.
- [ ] `systemd.timers.update-tappaas` no longer exists in `tappaas-cicd.nix`.
- [ ] `update-tappaas-schedule.service` renders `/run/systemd/system/update-tappaas.timer`, and `systemctl show update-tappaas.timer` reports the `OnCalendar` implied by `site.json` for all four frequencies, with `Persistent=false`.
- [ ] `{"frequency": "none"}` (or a legacy `["none", …]`) results in no active timer.
- [ ] The new unit reaches no schedule decision in Python; the gate code is deleted together with the interim path.
- [ ] A missed run does **not** fire at next boot.
- [ ] `site-manager update` starts the unit, streams this invocation's journal, prints the follow command on start and the summary plus the two completeness checks on exit; `Ctrl-C` detaches and says so; it refuses while a run is active.
- [ ] `site-manager update --dry-run` starts nothing and reports commits behind origin per repository (holds shown) and the sweep plan.
- [ ] `--force` and `--no-git-pull` reach the unit only through the request file; a timer run has none; a request never outlives its run; a stale request is discarded with a warning.
- [ ] `site-manager update --force` adds `--ignore-test-failure` to every `module modify` and leaves `rebootOk: false` modules deferred (ADR-020 D8).
- [ ] `update-tappaas --force` warns and has no effect; no caller or operator document still passes it; `rest-of-foundation.sh` runs `site-manager update`.
- [ ] The renderer and `site-manager validate` read the triple; a weekday under `daily`/`none` is reported as inert and never honoured. (D7's object form: with the G0.1 runner.)
- [ ] A plain `site-manager update` opens no disruption window; the scheduled run (`automaticReboot`) and `--force` do.
- [ ] `site show` prints no weekday under `daily` (#447).
- [ ] `validate-site.sh` rejects an invalid `updateSchedule` via `systemd-analyze calendar`.
- [ ] On a test system at release R−1: run 1 rebuilds through the interim path under the old unit, run 2 runs the three `ExecStartPre` lines; with run 1's rebuild forced to fail, the old timer does not produce hourly sweeps.
- [ ] The scoped polkit rule is removed; the helper unit, the `update.sh` fallback and the legacy path are removed only in the release *Bootstrap* names; the `safe.directory` HOME stays.
- [ ] `test.sh` Test 6 passes against the rendered timer.
- [ ] #357 closed against D8; #447 closed.
