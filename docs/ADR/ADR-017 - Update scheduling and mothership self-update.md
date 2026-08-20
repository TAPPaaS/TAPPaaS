# ADR-017 — Update scheduling and the mothership's own update

| | |
|---|---|
| **Status** | **Proposed** — draft (not implemented; scheduled for the next release, see #471) |
| **Version** | 0.1 |
| **Date** | 2026-08-18 |
| **Author** | Lars Rossen |
| **Parent** | [ADR-009 Composition Meta-Model](<ADR-009 - Composition Meta-Model.md>) (`<module>:<service>` coordinates) |
| **Refines** | [ADR-007d Site](<ADR-007d - Site.md>) (`site.json` as the site's single source of truth), [ADR-003 Dependency management](<ADR-003 - Dependency management in TAPPaaS.md>) (`dependsOn` ordering of the update loop) |
| **Related** | **#471** (implementation reminder for this ADR), **#150** (cron retired in favour of the systemd timer), **#467** (ambient `<nixpkgs>` unset under systemd — same failure class), **#468** (module readiness wait); **owner:** `tappaas-cicd` (unit definitions, self-update), `site-manager` (schedule rendering, `site update`) |
| **Changelog** | v0.1 — initial draft: hoist the mothership self-update into the unit via `ExecStartPre=+`, render `OnCalendar` from `site.json`, delete the in-process schedule gate, deprecate `--force`, introduce `site-manager site update` (with progress/completeness reporting), restate `updateSchedule` as a named object in which `daily` carries no weekday. |

## Context

`update-tappaas` is triggered by `update-tappaas.timer`, which fires **hourly**. The script
then reads `.updateSchedule` from `site.json` and decides whether this particular tick is the
one that should do work. Two schedulers in series: systemd decides *when to ask*, Python
decides *whether to act*.

That indirection is the backdrop for a failure that ran undetected for at least a month.

### The failure

The `tappaas-cicd` module updates the mothership itself, and its `update.sh` ends in:

```bash
sudo nixos-rebuild switch --flake ".#${VMNAME}" --impure
```

`update-tappaas.service` sets `NoNewPrivileges = true`. The kernel's `no_new_privs` latch is
inherited by every descendant and **cannot be cleared**, so setuid binaries stop conferring
privilege and `sudo` aborts before doing anything:

```
sudo: The "no new privileges" flag is set, which prevents sudo from running as root.
```

The scheduled run therefore fails structurally, every time, while the identical command run
by hand from an operator shell succeeds — a login process carries no such latch. Every
scheduled run recorded in the journal failed on `tappaas-cicd` (2026-08-04, 08-11, 08-17,
08-18); every manual run passed. The repair reflex — run `update-tappaas --force` by hand —
is exactly the path that cannot reproduce the fault.

The message itself only became visible on 2026-08-17, when `3c6379a` began tee-ing
`nixos-rebuild` output. Before that the same failure reported as a bare `exit 1`.

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

Two things follow. First, `ExecStartPre=+` is a verified mechanism for granting exactly one
step full privilege while the rest of the unit keeps its sandbox. Second, the sandbox
protects less than its comment claims: `/home/tappaas` holds the repo, every script, `.ssh`
and four credential files, and the service holds operator SSH to all three Proxmox nodes.
The hardening's practical effect is to block `nixos-rebuild` and very little else.

### Three further defects the same investigation surfaced

1. **The schedule is unvalidated.** `validate-configuration.sh` reads
   `.tappaas.updateSchedule` — the pre-ADR-007 nested path — while `main.py` reads flat
   `.updateSchedule`. The validator finds nothing, logs *"No updateSchedule configured
   (optional field)"* and returns. The reference site's `["daily", "Tuesday", 2]`, in which
   `"Tuesday"` is inert under `daily`, was therefore never flagged.
2. **A partial update reports as a clean failure.** `pre-update.sh` relinks
   `/home/tappaas/bin` *before* the rebuild and succeeds; the rebuild then fails. The
   mothership is left with `bin` ahead of its system generation, and the remaining nine
   modules are updated by half-updated tooling. On 2026-08-18 the bin symlinks were stamped
   02:06 while the system generation was still #4 from 08-16 15:16.
3. **Manual and scheduled are different code paths**, which is *why* this could hide.

### Why `--force` is the wrong shape

`--force` skips the hour gate and nothing else (`main.py:592`). It has no bearing on
privilege, yet it has become the documented "reconcile now" entry point in 14 places across
`install.sh`, `rest-of-foundation.sh`, `migrate-bootstrap.sh`, `provision.ts`, two
`INSTALL.md`s and the runbooks. Because it runs the *script* rather than the *unit*, the
officially documented operator path is structurally incapable of reproducing a scheduled
failure.

## Decision

### D1 — systemd owns the calendar; the in-process gate is deleted

`should_update_now`, `parse_schedule` and `WEEKDAYS` are removed (~80 lines). The timer fires
when — and only when — an update is due.

| `site.json` `updateSchedule` (D7 shape) | `OnCalendar` |
|---|---|
| `{"frequency": "none"}` | no timer installed |
| `{"frequency": "daily", "hour": 2}` | `*-*-* 02:00:00` |
| `{"frequency": "weekly", "weekday": "Tuesday", "hour": 2}` | `Tue *-*-* 02:00:00` |
| `{"frequency": "monthly", "weekday": "Tuesday", "hour": 2}` | `Tue *-*-01..07 02:00:00` |

systemd's calendar syntax expresses every case the old 3-tuple did, including "first
`<weekday>` of the month" (`main.py`'s `day_of_month > 7` rule), which becomes
`*-*-01..07` natively.

**`Persistent=false`.** A run missed because the host was down is *skipped*, not caught up: a
catch-up firing moments after boot risks compounding whatever caused the downtime. This
matches today's effective behaviour, where the catch-up tick was rejected by the hour gate
anyway.

### D2 — the timer is rendered from `site.json`, not declared in nix

`systemd.timers.update-tappaas` is **removed from `tappaas-cicd.nix`**. It is today the sole
creator of the schedule: the legacy crontab installer was retired in #150 and
`update-cron.sh` no longer exists anywhere in the tree.

A new root oneshot `update-tappaas-schedule.service` (`WantedBy = [ "timers.target" ]`) reads
`.updateSchedule`, validates the mapped expression with `systemd-analyze calendar`, writes
`/run/systemd/system/update-tappaas.timer`, reloads and starts it. `none` renders no timer
and stops any running one.

Rendering into `/run` rather than `/etc` means the schedule is re-derived from `site.json` at
every boot and on demand, so `site.json` cannot drift out of agreement with the running
timer and nothing persistent is left behind to reconcile. Runtime-written units are not new
ground here — `backup/lib/pbs-immutable.sh` already does it.

### D3 — the mothership's self-update leaves the module loop

The privileged step moves into the unit itself:

```nix
ExecStartPre = [
  "/home/tappaas/bin/tappaas-self-prepare"    # tappaas, sandboxed: repo pull + component builds
  "+/home/tappaas/bin/tappaas-self-rebuild"   # root, outside the sandbox: nixos-rebuild switch
];
ExecStart = "/home/tappaas/bin/update-tappaas";
```

The `+` prefix escapes `User=`, `ProtectSystem=` and `PrivateTmp=` for that one line while
every other line keeps the sandbox. No `sudo`, no polkit rule, no second unit.

This is a split along a real seam, not a relocation of the whole module. The `tappaas-cicd`
module update is three things:

| step | moves to | why |
|---|---|---|
| repo pull + 11 component builds | `ExecStartPre` (tappaas) | makes the toolchain current *before* it is used |
| `nixos-rebuild switch` | `ExecStartPre=+` (root) | the only step needing privilege |
| `cluster:vm` / `cluster:ha` reconciliation | **stays in the loop** | `tappaas-cicd.json` declares `dependsOn: [cluster:vm, cluster:ha]`; it must run after `cluster` |

`tappaas-cicd.json` declares `provides: []`, so no module depends on it and hoisting violates
no ordering.

Two defects close as a consequence. An `ExecStartPre` failure aborts the unit and `ExecStart`
never runs, so nine modules can no longer be updated by half-updated tooling. And `ExecStart`
launches the *newly linked* `update-tappaas`, instead of old code relinking its own binary
mid-flight.

**A third defect closes here too, not separately: `#467`.** `tappaas-self-prepare` is exactly
the "repo pull + 11 component builds" step above — the same step whose `default.nix` files
currently resolve `pkgs` from the ambient `<nixpkgs>` (via `NIX_PATH`), which a systemd unit
never sets. `#467`'s own thread already names the preferred fix — pin `pkgs` to a locked
`nixpkgs` instead of an ambient lookup — but it was not implemented before that issue closed;
`default.nix` still reads `pkgs ? import <nixpkgs> { }` as of this writing. Since D3 is already
restructuring this exact step, closing `#467` here avoids implementing `ExecStartPre` on top
of a build step that still ambiently depends on who last ran `nix-channel --update`:

```nix
# lib/nix/pinned-pkgs.nix — new, single source of truth
import (
  let lock = (builtins.fromJSON (builtins.readFile ../../flake.lock)).nodes.nixpkgs.locked;
  in fetchTarball {
    url = "https://github.com/${lock.owner}/${lock.repo}/archive/${lock.rev}.tar.gz";
    sha256 = lock.narHash;
  }
) { }
```

`../../flake.lock` reaches `tappaas-cicd/flake.lock` — the repo's own baseline pin, checked in
and version-controlled, not `/etc/nixos/flake.lock` (host-local, not git-tracked, resolves
`nixpkgs` independently per install). Pinning to the repo's own lock is what makes this
portable across sites rather than trading one ambient dependency for a different host-local
one. Each of the 11 `default.nix` files changes one line — `pkgs ? import <nixpkgs> { }`
becomes `pkgs ? import ../../lib/nix/pinned-pkgs.nix`. Deterministic regardless of caller
(systemd or interactive), no new dependency (`flake-compat` was considered and is unnecessary
here — it solves the harder problem of a flake-unaware *consumer* needing full flake outputs;
this only needs the *pinned nixpkgs revision itself*, which `flake.lock` already states
directly). `#467` should be reopened, or closed again against this ADR's implementation once
D3 lands.

### D4 — `site-manager site update` becomes the official operator path

```
site-manager site update            # report whether the installed repositories are current
site-manager site update --apply    # run the update regardless (it is idempotent)
```

Without `--apply` it probes each repository in `site.json` against its origin tip — reusing
the existing repository-reconcile planner — reports drift and recommends `--apply`. With
`--apply` it runs unconditionally.

Critically, `--apply` starts the **unit**, not the script:

```bash
sudo systemctl start --wait update-tappaas.service
```

Under D3 the self-update lives in the unit, so a bare interactive `update-tappaas` would no
longer update the mothership at all. Routing the official path through the unit makes the
manual/scheduled divergence that hid this bug structurally impossible: there is one code
path, and the operator exercises the same one the timer does.

**`--apply` must say how to follow the run and how to confirm it finished.** Driving a unit
rather than a script breaks two things the operator previously got for free: output no longer
belongs to the terminal, and `Ctrl-C` no longer stops the work. Both have to be stated at the
point of use, not left to the runbook. On start it prints:

```
started update-tappaas.service (this run continues if you detach)
  follow:   journalctl -fu update-tappaas.service
  status:   systemctl status update-tappaas.service
```

and on exit, the run's own summary line together with the checks that establish completeness:

```
update-tappaas completed: <ts> | total=10 succeeded=10 failed=0 skipped=0 reboot=ok
  verify:   systemctl is-failed update-tappaas.service     → "inactive" when the run succeeded
  verify:   site-manager site update                       → no repository drift remains
```

The distinction matters: `--apply` returning 0 only means the unit exited 0. "Complete" means
the summary reports `failed=0` **and** a subsequent `site update` reports no drift — a run can
exit non-zero with nine of ten modules correctly updated, which is exactly the state the
2026-08-18 nightly was in.

### D5 — `--force` is deprecated, then removed

`--force` remains in `argparse`, logs a deprecation warning and has no effect. All 14 call
sites move to `site-manager site update --apply` in the same change, so the documentation
and the scripts stay honest. The flag is removed outright in a later release.

### D6 — the schedule is validated against what actually runs

`validate-configuration.sh` is corrected to read flat `.updateSchedule`, enforces D7's
per-frequency field rules, and validates the *rendered* expression with
`systemd-analyze calendar` rather than reimplementing calendar rules in bash. Validation and
mechanism cannot then drift — and unlike today, a schedule that means nothing is refused
rather than ignored.

### D7 — `updateSchedule` becomes a named object; `daily` carries no weekday

The present shape is a positional triple, `[frequency, weekday, hour]`, in which `weekday` is
meaningless under `daily` and `none` but must still be occupied. The reference site holds
`["daily", "Tuesday", 2]` — a value that has never been read, on a site that updates every
day. Combined with the dead validator (D6) nothing could report it, and it read as a weekly
schedule to anyone glancing at `site.json`.

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

**Migration.** The legacy triple is accepted for one release, with a deprecation warning that
names the replacement, and is rewritten in place by `site-manager validate` / `site update` —
dropping the inert `weekday` for `daily` and `none`. In-place backfill of `site.json` has
precedent in `ensure_default_environment` (ADR-007d, #426). Sites carrying
`["daily", "Tuesday", 2]` therefore converge on `{"frequency": "daily", "hour": 2}` without
operator action, and the dropped weekday is reported rather than silently discarded.

## Alternatives considered

| Alternative | Why not |
|---|---|
| **Root helper unit + polkit rule** — `update.sh` calls `systemctl start --wait tappaas-rebuild@<vm>.service`; polkit authorises the caller's uid | Verified to work, and adopted as the **interim fix** ahead of this ADR (see *Interim state* below). Not the target: it leaves the self-update inside the module loop, keeps the manual and scheduled paths distinct, and adds a polkit rule that D3 makes unnecessary. |
| **Drop `NoNewPrivileges` + `ProtectSystem` from the unit** | One line, and the measurements above show the sandbox buys less than it appears to. Still rejected: it surrenders the `/etc`, `/nix`, `/var` protection for all ten module updates to obtain privilege for one step of one. |
| **Run the whole service as root** | No `sudo` needed anywhere — but the repo, `~/.ssh`, the operator key and all git ownership are `tappaas`'s. Running the loop as root breaks `repo-sync` and inverts the ownership model. |
| **nix reads `site.json` at rebuild time** (`builtins.fromJSON`; `--impure` is already in use) | Most consistent with the declarative model and needs no new machinery, but a schedule change then takes effect only after a rebuild, so `site.json` can silently lie in between — and it makes the schedule depend on the very rebuild that has been failing. |
| **`site-manager` writes an `/etc` drop-in directly** | Simplest and immediate, but leaves persistent state that a `nixos-rebuild` will not reconcile, so `/etc` and `site.json` can diverge with nothing to detect it. |
| **Keep the hourly timer + gate and fix only `sudo`** | Smallest diff, but preserves both root causes: the double scheduler, and manual/scheduled being different code paths. |

## Schema changes

- **`site.json` — `updateSchedule` becomes an object** (D7): `frequency` always, `weekday`
  only for `weekly`/`monthly`, `hour` for every frequency but `none`. The legacy
  `[frequency, weekday, hour]` triple is accepted for one release and rewritten in place.
- **`validate-configuration.sh`** — read `.updateSchedule`, not `.tappaas.updateSchedule`;
  enforce D7's per-frequency field rules; validate the mapped expression via
  `systemd-analyze calendar`.
- **`site-manager site modify`** — gains `--updateSchedule <freq>[:<weekday>]:<hour>`, which
  writes the D7 object and refuses a weekday under `daily`/`none`. The existing
  `setStr`/`setBool`/`setInt` helpers cannot express it, so this needs its own parser.
  Writing it triggers the D2 renderer.
- **No `module-catalog` change. No `zones.json` change.**

## Consequences

- **Operator output moves to journald.** `site update --apply` drives a unit, so the live
  coloured output of today's `update-tappaas --force` must be reproduced by streaming
  `journalctl -fu update-tappaas.service`. Losing that stream would be a real regression in
  operability.
- **A failed self-update now blocks the whole run.** That is the intent — today it does not,
  and the remaining nine modules proceed on half-updated tooling — but it means a transient
  Codeberg outage can stop an entire night's updates. See *Open* below.
- **Schedule changes take effect immediately**, without a rebuild, and survive reboot.
- **`update-tappaas` invoked bare no longer updates the mothership.** Anyone with the muscle
  memory must move to `site update --apply`; D5's deprecation warning is the migration aid.
- **`test.sh` Test 6** keeps its timer-active and cron-guard assertions but repoints the
  failure hint from `tappaas-cicd.nix` to the renderer, and gains a check that the rendered
  `OnCalendar` matches `site.json`.
- **`--impure` is not widened.** It remains needed only for
  `/etc/nixos/hardware-configuration.nix`, because the schedule is not read by nix.

## Interim state (to be reverted by this ADR)

Ahead of implementation, the scheduled run is unblocked by the polkit alternative above: a
root `tappaas-rebuild@.service`, a polkit rule authorising `tappaas` to start it, and
`update.sh` calling `systemctl start --wait` in place of `sudo nixos-rebuild`. It restores
the nightly without restructuring anything, and takes effect only once committed and applied
by a rebuild.

Implementing D3 **removes all three**: the helper unit, the polkit rule, and the indirection
in `update.sh`.

## Open (deferred to implementation)

- **Should a failed repo pull abort the run?** Proposed default: yes, fatal — updating from a
  stale tree while reporting success is the failure mode this ADR exists to remove. Today it
  only warns, so this is a behaviour change worth confirming.
- **How long to accept the legacy triple.** D7 settles the reference site's
  `["daily", "Tuesday", 2]` — the weekday is dropped on rewrite, not honoured — but the
  deprecation window ("one release") is a guess until the fleet's site.json shapes are known.
- **`switch-to-configuration` restarting its own invoker.** A rebuild that changes
  `update-tappaas.service` may attempt to restart the unit the rebuild is running under. The
  same exposure exists today; hoisting into `ExecStartPre` does not obviously change it, but
  it has not been tested deliberately.
- **Whether `site update` (no `--apply`) should also report module drift**, not just
  repository drift.

## Acceptance (draft — becomes a checklist on Accepted)

- [ ] A scheduled run completes `tappaas-cicd` with no `sudo` in the path.
- [ ] All 11 manager/controller `default.nix` files resolve `pkgs` from `lib/nix/pinned-pkgs.nix`
      (flake-locked), not ambient `<nixpkgs>`; a scheduled run under systemd builds all 11
      cleanly (`#467` closed against this, not the "fail loudly" fix alone).
- [ ] `systemd.timers.update-tappaas` no longer exists in `tappaas-cicd.nix`.
- [ ] `update-tappaas-schedule.service` renders `/run/systemd/system/update-tappaas.timer`, and `systemctl show update-tappaas.timer` reports the `OnCalendar` implied by `site.json` for all four frequencies.
- [ ] `updateSchedule: ["none", …]` results in no active timer.
- [ ] `should_update_now` / `parse_schedule` / `WEEKDAYS` are deleted; no schedule decision remains in Python.
- [ ] A missed run does **not** fire at next boot (`Persistent=false`).
- [ ] `ExecStartPre` failure aborts the unit; no module update runs.
- [ ] `site-manager site update` reports repository drift and recommends `--apply`; `--apply` runs regardless and streams live output.
- [ ] `--apply` prints the follow command on start and, on exit, the run summary plus the two completeness checks; detaching with `Ctrl-C` leaves the run going and says so.
- [ ] `updateSchedule` accepts the D7 object; `weekday` under `daily` or `none` is refused by `validate` with a named error.
- [ ] `hour` is required for `daily`/`weekly`/`monthly` and refused for `none`.
- [ ] A legacy `[frequency, weekday, hour]` triple is accepted once, warned about, and rewritten in place — `["daily", "Tuesday", 2]` becoming `{"frequency": "daily", "hour": 2}` with the dropped weekday reported.
- [ ] `update-tappaas --force` warns and proceeds; no call site in the tree still passes it.
- [ ] `validate-configuration.sh` rejects an invalid `updateSchedule` on the flat path, via `systemd-analyze calendar`.
- [ ] The interim `tappaas-rebuild@.service` and its polkit rule are removed.
- [ ] `test.sh` Test 6 passes against the rendered timer.
