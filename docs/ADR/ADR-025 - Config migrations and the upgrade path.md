# ADR-025 — Config migrations and the upgrade path

| | |
|---|---|
| **Status** | **Proposed** (2026-09-16) — v0.1; entry gate for Wave 0 (plan §10.3). Awaiting operator sign-off. |
| **Version** | 0.1 |
| **Date** | 2026-09-16 |
| **Author** | Lars Rossen |
| **Parent** | [ADR-007d Site](<ADR-007d - Site.md>) (`site.json` and the rest of `config/` as the site's own state) |
| **Refines** | [ADR-017 Update scheduling and mothership self-update](<ADR-017 - Update scheduling and mothership self-update.md>) (D3's `ExecStartPre` chain is where the runner hooks in; D4's `--dry-run` is where pending migrations show; this ADR settles two of ADR-017's *Open* items), [ADR-003 Dependency management](<ADR-003 - Dependency management in TAPPaaS.md>) (why `pre-update.sh` cannot be "before any module") |
| **Related** | **#652** (versioned config-migration step — the implementation issue); **#545** / [ADR-012](ADR-012-backup-enhancement.md) §2.7 D20 (`config/` is backed up as `backup:filesystem`, which is what makes `config/.migrations/` recoverable); **#651** (update-failure notice) and [ADR-007e](<ADR-007e - Health.md>) v1.3 (the notification target); **#584** (rollback in install/modify), **#453** (`--force` vs `--reinstall`), **#648** (`--unset`), **#572** (repo-sync auto-stash) — the rest of G0.1; [ADR-020](<ADR-020 - Declared-Field Change Model (validate, drift, modify).md>) (a *declared field* changes through `modify`; a *schema* changes through a migration); [release-2.1-implementation-plan](../design/release-2.1-implementation-plan.md) §3 G0.1, §10.1, §10.2, §10.3, §10.4. **Owner:** `tappaas-cicd` (the runner, the migration directory, the release tooling) |
| **Changelog** | v0.1 — initial draft. Takes the framework decided 2026-09-14 (plan §3 G0.1) and the rollout rules (§10.2) verbatim and binds them; checks each clause against `main` at `dd80d495`; settles the runner's slot in favour of `tappaas-self-prepare.sh` over `pre-update.sh` (D2), answers ADR-017 *Bootstrap*'s "oldest supported upgrade source" (D10), and names ADR-017 D7's `updateSchedule` rewrite as migration `0003` (D12). |

## Context

TAPPaaS sites upgrade by pulling their channel and letting the next sweep reconcile
(`release/README.md`: `main` → `rc/<ver>` → tag → fast-forward `stable`). Code arrives that
way perfectly well. **Configuration does not.** `/home/tappaas/config/` is the site's own
state — `site.json`, one `<module>.json` per installed module, `zones.json`, the caches — and
a release that renames a field or changes a shape has no sanctioned way to bring it forward.

So far each such change has grown its own hand-written block, wherever the author happened to
be standing:

| ad-hoc migration today | where | what it does |
|---|---|---|
| `firewall:proxy` → `network:proxy` in every `dependsOn` | `pre-update.sh:52–66` | one-time idempotent `jq` rewrite over `config/*.json`, written after a production incident on 2026-07-07 rolled the firewall VM back |
| legacy `configuration.json` refresh | `pre-update.sh:38–50` | re-discovers nodes on a site that predates `site.json`, guarded on the file existing |
| backfill a missing `site.json` `.defaultEnvironment` | `main.py:200` (`ensure_default_environment`, called at `main.py:973`) | mints a required field #426 added, because the conversion migration only fired on the `configuration.json` → `site.json` path |
| strip the retired `.variant` field | `scripts/migrate-drop-variant.sh` | dry-run by default, backs up every file it changes — and is **run by hand**, so a site that never ran it still carries the field |

Four different shapes, three different files, two different languages, and no record anywhere
of which of them a given site has actually had applied. Nothing lists them, nothing tests
them against a before/after fixture, nothing can be rolled back, and the one written to the
right contract is the one nothing calls.

Wave 1 of the 2.1 plan is a queue of exactly this kind of change — `tier` → `stack` (#611,
#628), the `src/apps` restructure that rewrites `.location` in every deployed config (#421,
#500), the backup placement state (#602, #600), the VMID scheme (#294). Each is a rename or a
re-schema of `config/`. Wave 0 exists to make those safe, and this framework is its first
item (plan §3 G0.1, decision log #1). The decision itself was taken on 2026-09-14; this ADR is
where it becomes binding on every release and every contributor, which is why the plan lists
it as a new ADR gating Wave 0 (§10.3, §10.4).

**What has changed under it since.** ADR-017 D3 has landed on `main`: the pull, the relink and
the component builds moved out of the sweep into `update-tappaas.service`'s `ExecStartPre`
chain (`tappaas-cicd.nix:273–277`), realized by `scripts/tappaas-self-prepare.sh` and
`scripts/tappaas-self-rebuild.sh`. That moved the ground under the plan's sentence "run in
numeric order by `pre-update.sh`, before the 3-way merge and before any module update", and
ADR-017 records the consequence as an open item of its own ("The G0.1 runner's slot"). D2
below settles it.

## Decision

### D1 — a migration is a numbered script, and the set is ordered

Migrations live in **`src/foundation/tappaas-cicd/migrations/NNNN-<slug>.sh`** — a new
directory; nothing exists there today — and run in ascending numeric order. The number is
allocated when the migration is written, is never reused, and never changes meaning: the
ledger (D4) records numbers, so renumbering would silently re-run or silently skip.

A migration is **a unit of config change, not a unit of release**. One release may carry
none (the common case), one, or several; several are applied in order in a single run.

Each script carries a header block stating: what it changes, which release introduced it,
whether it is reversible by restoring its backup (D8), and the issue or ADR that required it.
`scripts/migrate-drop-variant.sh` is the shape to copy — it is already dry-run-by-default and
already backs up every file it touches; it simply has no runner.

### D2 — the runner hooks into `tappaas-self-prepare.sh`, not `pre-update.sh`

> Settles ADR-017 *Open*: "The G0.1 runner's slot."

The plan says "run in numeric order by `pre-update.sh`, before the 3-way merge and before any
module update." Checked against `main`, the second half of that sentence cannot be true of
`pre-update.sh`:

- `pre-update.sh` is the `tappaas-cicd` **module's** pre-update hook. `tappaas-cicd.json:16–19`
  declares `dependsOn: ["cluster:vm", "cluster:ha"]`, so under ADR-003's derived order the
  `cluster` module has already been updated by the time it runs. "Before any module update"
  is false there by construction, and it cannot be fixed without inverting a dependency that
  exists for a good reason.
- It runs *inside* the sweep, so a failing migration would fail one module among several,
  land in the sweep's per-module accounting, and leave the modules already updated ahead of a
  `config/` the migration had decided was not safe to touch.
- It is also the standalone path for `module-manager module modify tappaas-cicd`
  (`pre-update.sh:13–17`), which is deliberately idempotent and re-runnable on its own. A
  site-wide schema rewrite is not a per-module operation.

**The runner therefore runs in `scripts/tappaas-self-prepare.sh`** — ADR-017 D3's second
`ExecStartPre` line (`tappaas-cicd.nix:275`) — **after the control-plane refresh succeeds
(`tappaas-self-prepare.sh:52–62`) and before the hand-over (`:64–68`)**, i.e. before
`tappaas-self-rebuild.sh` and before `ExecStart` reaches the first module. Four properties
follow, and no other slot has all four:

1. **It is the one place that runs before every module**, cluster included.
2. **The migrations it runs are the ones just pulled.** The refresh immediately above it does
   the hold-aware pull and relinks `~/bin`, so the directory the runner reads is the release
   the site is upgrading *to*, in the same run.
3. **It runs before the `nixos-rebuild switch`.** This is not incidental: `tappaas-self-rebuild.sh`
   starts the D2 schedule renderer after the switch, and the renderer reads
   `.updateSchedule` — the very field migration `0003` rewrites (D12). A migration that must
   be true before the system generation changes has to run here.
4. **Failure already has a home.** `tappaas-self-prepare.sh` is fatal on non-zero, writes
   `config/.update-stage`, and an `ExecStartPre` failure fails the unit so `OnFailure`
   (`tappaas-cicd.nix:261`) runs the #651 notice. D5 needs one new stage name and nothing else.

`pre-update.sh` keeps its existing blocks until they are promoted (D11) and **never calls the
runner**: migrations are a sweep-level step, not a module step, and two callers would mean two
ledgers' worth of doubt.

**The cost, stated.** The runner executes before the rebuild, so a migration may not depend on
the new system generation, and it executes after a refresh that may have returned rc 10
(component bins stale, `tappaas-self-prepare.sh:57`), so it may not depend on a manager binary
either. D3 turns both into a contract clause rather than a hazard.

### D3 — the contract every migration meets

- **Idempotent.** Re-running a migration that has already been applied changes nothing and
  exits 0. The ledger (D4) is an optimisation and an audit trail, not the safety mechanism.
- **`--check` writes nothing.** It reports exactly what the apply would change, file by file,
  and exits 0 if there is work, 0 if there is none (distinguished in the output, not the exit
  code), non-zero only if it cannot tell.
- **Apply backs up first.** Before the first write, every file the migration will touch is
  copied to `config/.migrations/backup/NNNN/`, preserving its path under `config/`. A
  migration that has written without having copied is a defect.
- **Exit non-zero on any doubt.** A migration that meets an input it does not recognise stops;
  it does not guess and it does not skip. Stopping costs one night's sweep (D5); guessing
  costs a site's config.
- **Self-contained.** `bash`, `jq`, coreutils and the files under `config/`. No manager
  binary, no `python` from a flake package, nothing from the not-yet-switched system
  generation (D2's cost, made a rule). A migration that genuinely needs a manager is a sign
  the change belongs in `modify` (ADR-020), not in a migration.
- **Config only.** A migration rewrites `config/`. It does not touch VMs, the firewall, the
  cluster or the repository.

### D4 — the ledger lives in `config/`, and fresh sites are stamped, not migrated

`config/.migrations/applied` records one line per applied migration: **id, date, and the
commit the site was on when it ran**. It lives under `config/`, so it is captured by the #545
backup — verified: `tappaas-cicd.json:19–24` declares `integratesWith: ["backup:filesystem"]`
with `filesystemPaths: ["/home/tappaas/config", "/etc/secrets"]`, and
`backup/services/filesystem/tappaas-fs-backup.sh:53–71` archives each declared path whole as a
`.pxar`, so the dot-directory is included with no extra rule. ADR-012 §2.7 D20 records the
coverage and the rehearsed restore.

**A fresh install is stamped at the current level.** `create-site.sh` writes a `config/` with
today's shapes, so every shipped migration is already true of it. `install.sh` therefore
records every shipped id in `applied` with the reason `baseline` **without running them** —
cheaper than running the whole history, and honest about what happened. (Migrations are
idempotent, so the alternative is merely wasteful, not dangerous; the ledger entry is what
makes the difference visible.)

The ledger is written **after** the migration succeeds. A migration interrupted mid-apply
leaves no ledger entry and is re-run next sweep, which D3's idempotence makes safe.

### D5 — a failed migration stops the run before anything is updated

The runner writes `migrate` into `config/.update-stage` for its duration (the marker
`tappaas-self-prepare.sh:28` and `:67` already maintain), and exits non-zero on the first
migration that fails. The unit's `ExecStartPre` chain aborts: no `nixos-rebuild`, no
`ExecStart`, no module touched.

`scripts/notify-update-failure.sh` gains `migrate` in both of its `case` blocks — the one that
synthesizes a `last-update-result.json` for a failure before the sweep (`:42–48`, today
`prepare|rebuild`) and the one that writes the operator-facing line (`:50–55`). The mail then
reads *"Stopped in: a config migration, before any module was updated"* and names the
migration id, instead of quoting the previous sweep's result. The `.update-stage` marker is
consumed by the notice (`:49`), which is already tested
(`scripts/test/test-notify-update-failure.sh:66–71`).

The site is left on the old code with its `config/` either untouched or restorable from
`config/.migrations/backup/NNNN/` (D8). That is the intended failure mode: **a site that
cannot migrate does not update.**

### D6 — pending migrations are visible before they run, and named in the release notes

- **`site-manager update --dry-run` lists pending migrations.** The verb exists and starts
  nothing (`main.ts:797–805`); its sweep half delegates to `update-tappaas --dry-run`
  (`client.ts:255–256`). The runner grows a `--list` mode, and both the dry run and the
  operator-facing `update --dry-run` print each pending id with the one-line summary from its
  header. (The plan's §3 G0.1 phrasing is `update-tappaas --dry-run`; under ADR-017 D4 the
  operator's verb is `site-manager update --dry-run` and it is the same output.)
- **`release/changelog.sh` lists the migrations added between two refs.** The script exists
  and groups commits by Conventional-Commit type with issue extraction; it has no notion of
  migrations today (verified: no match for "migration" anywhere under `release/`). It gains a
  **Migrations** section derived from `git diff --name-only --diff-filter=A <from>..<to> --
  src/foundation/tappaas-cicd/migrations/`, printing each id and its header summary.
- **Release notes for a wave list its migrations and any operator step**, and go out before
  the candidate is promoted (plan §10.2 rule 6).

### D7 — the review rule: no re-schema without its migration and its fixture test

**A change that renames or re-schemas anything under `config/` ships with its migration and a
fixture test — config before → after — in the `tappaas-cicd` fast tier.** This is a review
rule, not a suggestion: a pull request that changes a field name, a field type or a file
layout under `config/` and carries no `migrations/NNNN-*.sh` is incomplete, and one that
carries a migration with no fixture is untested.

The fast tier needs no new wiring: `test.sh` Test 9z runs **every** executable under
`scripts/test/` (`test.sh:479–536`), so a fixture test dropped there joins the fast tier by
existing. Each fixture test builds a throwaway `config/` in a temp directory, runs the
migration with `--check` (asserting it writes nothing), runs it, compares against the expected
output, and runs it a second time to assert idempotence.

The rule's counterpart: **a change to a declared field's *value* is not a migration.** ADR-020
owns that path (`modify --set`, the differ, the change classes). Migrations are for changes to
the *shape* the site's config is written in.

### D8 — no down-migrations; rollback is the backup

There are no down-migrations by default. Reversing a schema change in code doubles the surface
that must be written, tested and trusted, for a case that is rare and that a file copy already
covers.

**Rollback for one site is restoring `config/.migrations/backup/NNNN/`.** A migration that
cannot be reversed that way — because it has consequences outside `config/`, or because a later
step has already consumed its output — **says so in its header**, and the release notes repeat
it. Rehearsing that restore once is part of the R4 test level (D9).

### D9 — the rollout rules that bind a release (plan §10.2, §10.1)

1. **One release candidate per wave** (Wave 1 may use one per group or pair of groups).
2. **Migrations from different waves never arrive in the same sweep.** A site that skipped a
   release still receives each wave's migrations as its own update.
3. **Wave 0 reaches `stable` before any Wave 1 migration merges to `main`.** A site on
   `stable` must receive the runner in an update *before* the first update that carries a
   migration — which is why the runner's own release carries none (D11).
4. **`stable` never moves backwards.** A bad release is fixed forward. For one affected site:
   pause its update schedule, restore the migration backup (R4) or wait for the revert
   (R ≤ 3), resume after the fix.
5. **Release notes list the migrations** (from D6's `changelog.sh` section) and any operator
   step, and go out before the candidate is promoted.
6. **R4 is the test level for a change that carries a migration** (§10.1): migration `--check`
   and then apply against a **copy** of each canary's `config/`; an upgrade test on the test
   system from the current `stable`; restoring from `config/.migrations/backup/NNNN/`
   rehearsed once. R4 includes every level above it.

### D10 — every release names the oldest upgrade source it supports

> Settles ADR-017 *Open*: "The oldest supported upgrade source."

A site on `stable` pulls the branch tip, so a site that was down, held (#653) or on a monthly
schedule can arrive from several releases back. "One release later" is therefore not a rule
anyone can rely on, and interim and compatibility code accumulates because no one can say when
it is safe to delete.

The rule:

- **Each release's notes name the oldest release it supports upgrading from.** That is a
  statement the release is tested against: the §10.1 R4 upgrade test runs from that source.
- **Compatibility code that exists only to serve an older source is removed in the first
  release whose notes name a source at or after the one that needed it** — not before.
- **A site older than the named source upgrades in steps**, through a named intermediate
  release, and the notes say which.
- Migrations themselves are **not** compatibility code and are never deleted: the ledger makes
  a long chain cheap (already-applied ids are skipped), and a site arriving from far back is
  exactly the case they exist for.

This is the rule ADR-017 *Bootstrap* asks for: its interim path — `tappaas-rebuild@.service`,
`update.sh`'s fallback, and `update-tappaas`'s legacy schedule-gate path — goes in the first
release whose notes name R (the release carrying ADR-017 D3) or later as the oldest supported
source.

### D11 — bootstrap: the runner's own release carries no migrations

The release that introduces the runner ships it **empty**. That is the Wave 0 exit gate
("Runner released with no migrations", plan §10.3) and it follows from D9 rule 3: a site must
have received the runner before it receives anything for the runner to run.

The existing ad-hoc blocks move in **later**, as the first numbered migrations — they are
already idempotent, which is what makes the promotion safe:

| id | from | what |
|---|---|---|
| `0001-dependson-firewall-proxy-to-network-proxy.sh` | `pre-update.sh:52–66` | rewrite `dependsOn: firewall:proxy` → `network:proxy` across `config/*.json` |
| `0002-site-default-environment.sh` | `main.py:200` (`ensure_default_environment`), called at `main.py:973` | backfill `site.json` `.defaultEnvironment` from `.owner`, else `.name` |

Promoting each one **deletes its origin in the same commit**; two copies of a migration is how
a site gets it applied twice under two different ledgers' worth of ignorance.

Two further candidates, deliberately *not* promoted in the same release: the legacy
`configuration.json` refresh (`pre-update.sh:38–50`) is a recurring reconcile rather than a
one-time rewrite and should be retired under D10's rule instead; and
`scripts/migrate-drop-variant.sh` is operator-run and interactive today, so promoting it makes
it run unattended on every site that never ran it — correct, but it is a change of behaviour
that deserves its own release note.

### D12 — the first real migration is ADR-017 D7's `updateSchedule`

ADR-017 D7 is decided and deferred explicitly onto this runner: `updateSchedule` becomes a
named object and the positional triple is rewritten in place. It is `0003`:

```
0003-update-schedule-object.sh
  ["daily",   "Tuesday", 2]  →  {"frequency": "daily",   "hour": 2}     (weekday dropped, reported)
  ["weekly",  "Tuesday", 2]  →  {"frequency": "weekly",  "weekday": "Tuesday", "hour": 2}
  ["monthly", "Tuesday", 2]  →  {"frequency": "monthly", "weekday": "Tuesday", "hour": 2}
  ["none",    *,         *]  →  {"frequency": "none"}
  already an object          →  no-op
```

It touches exactly one file, `config/site.json`, which it copies to
`config/.migrations/backup/0003/site.json` before writing; it is reversible by that restore, so
its header says so. It runs before the rebuild (D2 property 3), which is what lets the schedule
renderer that `tappaas-self-rebuild.sh` starts read the new shape in the same run. The
reference site's `["daily", "Tuesday", 2]` — a weekday that has never been read, on a site that
updates daily — is the case that motivated D7, and the migration **reports the dropped
weekday** rather than discarding it silently.

`site-fields.json:175–183` still types `updateSchedule` as a bare `"type": "array"` with a
`["monthly","Thursday",2]` default; `0003` ships together with the per-frequency object schema
and the validator rules ADR-017 D6 describes.

**Its fixture test** — `scripts/test/test-migration-0003-update-schedule.sh`, picked up by
Test 9z:

| case | input `site.json` | assertion |
|---|---|---|
| daily with an inert weekday | `["daily","Tuesday",2]` | → `{"frequency":"daily","hour":2}`; the dropped weekday appears in the output |
| weekly | `["weekly","Tuesday",2]` | → the three-field object |
| monthly | `["monthly","Thursday",2]` | → the three-field object |
| none | `["none","Monday",2]` | → `{"frequency":"none"}` |
| already migrated | the object form | byte-identical file; no backup written |
| `--check` | any of the above | file unchanged on disk; the plan printed |
| idempotence | apply twice | second run is a no-op and exits 0 |
| backup | any changed case | `config/.migrations/backup/0003/site.json` holds the pre-image |
| unrecognised | `["fortnightly","Tuesday",2]` | exits non-zero; `site.json` unchanged |

## Alternatives considered

| Alternative | Why not |
|---|---|
| **Run the migrations from `pre-update.sh`** (the plan's original wording) | `tappaas-cicd` `dependsOn` `cluster:vm`/`cluster:ha` (`tappaas-cicd.json:16–19`), so `cluster` has already updated: "before any module update" is false there. It also runs inside the sweep's per-module accounting and doubles as the standalone `module modify tappaas-cicd` path. |
| **A fourth `ExecStartPre`, after the rebuild** | Gives a migration the new system generation, at the cost of one more line in ADR-017 D3's chain — and the case that needs it is hypothetical, while `0003` is the concrete case that needs the *opposite* order (before the renderer starts). D3 makes the constraint a contract clause instead. |
| **At the head of `update-tappaas`'s sweep** (`main.py`, before the topological sort) | The natural reading of "before any module update", and it is where `ensure_default_environment` sits today — which is precisely the ad-hoc pattern G0.1 replaces. It runs after the rebuild, inside the process whose result file the failure would have to be written into, and it would not run for `update-tappaas --dry-run` without a second code path. |
| **Down-migrations** | Doubles what must be written and tested for a rare case a file copy already covers (D8). Sites also do not go backwards: `stable` is fixed forward (D9 rule 4). |
| **A single `schemaVersion` integer in `site.json`** | One number cannot describe `config/` — a site's state is one `site.json`, N module configs, `zones.json` and caches, and a partially-applied set is exactly the state a single integer cannot express. The per-id ledger can. |
| **One "migrate everything" script, rewritten each release** | What exists today, spread over four places. It has no order, no record of what ran, no dry run and no rollback, and nothing tests it. |
| **Migrate at read time** (each manager tolerates both shapes) | Cheapest per change and the reason the current mess exists: the old shape never leaves, every reader carries the branch forever, and no release can ever name a cut-off (D10). |
| **Keep `migrate-drop-variant.sh`'s hand-run model** | It is the best-built of the four ad-hoc migrations and the *least* applied, because it depends on an operator knowing it exists. |

## Schema changes

- **`src/foundation/tappaas-cicd/migrations/`** — new directory, empty in the release that
  introduces the runner (D11).
- **`config/.migrations/applied`** — new: one line per applied migration (id, date, commit,
  and `baseline` for a fresh install's stamp). Site state, under `config/`, covered by #545.
- **`config/.migrations/backup/NNNN/`** — new: the pre-image of every file a migration touched,
  at its path under `config/`.
- **`config/.update-stage`** — gains the value `migrate` (existing file, ADR-017 D3).
- **`scripts/notify-update-failure.sh`** — `migrate` added to both `case` blocks (`:42–48`,
  `:50–55`).
- **`release/changelog.sh`** — new *Migrations* section between two refs (D6).
- **Not changed by this ADR:** `site-fields.json` (migration `0003` changes `updateSchedule`
  under ADR-017 D7, and ships with it); `module-fields.json`; `zones.json`; the module contract.

## Consequences

- **A failed migration costs a night's updates, for every site that hits it.** That is the
  intent — the alternative is a half-migrated `config/` and a sweep running against it — but it
  makes migration correctness a release-blocking property, which is what R4 (D9 rule 6) exists
  to establish before `stable` moves.
- **The review rule adds work to every `config/`-shaped change** (D7): a migration and a
  fixture. Wave 1 is a queue of such changes, so this is the cost being accepted deliberately
  and the reason Wave 0 comes first.
- **A migration is written once and kept forever.** The directory only grows. That is cheap
  (the ledger skips applied ids) and it is what lets D10 name an oldest *source* rather than an
  oldest *config shape*.
- **Migrations may not use the managers** (D3), so a change that genuinely needs domain logic
  has to express it in `jq` or move to ADR-020's `modify`. This will be felt first by whichever
  Wave 1 change discovers it.
- **`config/.migrations/backup/` grows with every applied migration.** It is small (the files it
  copies are JSON) and it is exactly what D8's rollback restores, so it is not pruned by the
  sweep. A retention rule is deferred to *Open*.
- **The ledger makes "which migrations has this site had?" answerable** for the first time —
  by reading one file, and from a restored backup.
- **ADR-017 closes two open items** (the runner's slot, the oldest supported upgrade source)
  and its D7 acquires an owner.

## Open (deferred to implementation)

- **Retention for `config/.migrations/backup/`.** Kept forever in v0.1. A rule ("the last N
  migrations", or "prune on a successful sweep two releases later") needs a case first.
- **Whether a migration may be re-run deliberately** once applied (a `--force` on the runner)
  — useful after a hand-edit went wrong, and a footgun if it is the first thing anyone reaches
  for. Not offered in v0.1.
- **Whether `config/` should be snapshotted as a whole before the first migration of a run**,
  in addition to the per-migration backups. #584 covers the neighbouring case for `modify`.
- **Migrations for state that is not in `config/`** — `/etc/secrets`, the firewall's own
  config. Out of scope in v0.1; both have their own restore paths (ADR-012 §2.7, RESTORE.md).
- **Whether the runner should refuse to run when `config/` is not covered by a recent backup.**
  Attractive, and it couples the sweep to backup health (ADR-007e) in a way that needs its own
  argument.

## Acceptance

- [ ] `src/foundation/tappaas-cicd/migrations/` exists and is empty in the release that
      introduces the runner; the Wave 0 exit gate is met (plan §10.3).
- [ ] The runner is invoked from `scripts/tappaas-self-prepare.sh`, after the refresh and
      before the hand-over; nothing invokes it from `pre-update.sh` or from `main.py`.
- [ ] Migrations run in ascending numeric order; an already-applied id is skipped; a
      re-applied migration is a no-op.
- [ ] `--check` on every shipped migration leaves `config/` byte-identical.
- [ ] Applying a migration writes `config/.migrations/backup/NNNN/` before its first write, and
      `config/.migrations/applied` only after it succeeds (id, date, commit).
- [ ] A fresh install stamps every shipped id as `baseline` without running it.
- [ ] A failing migration exits non-zero, stops the unit before `tappaas-self-rebuild.sh`, and
      updates no module; `last-update-result.json` records `stage: "migrate"`; the #651 notice
      names the migration.
- [ ] `site-manager update --dry-run` lists pending migrations and starts nothing.
- [ ] `release/changelog.sh --from <tag> --to <tag>` lists the migrations added in the range.
- [ ] A fixture test exists under `scripts/test/` for every shipped migration and is picked up
      by `test.sh` Test 9z (fast tier), covering before → after, `--check`, idempotence, the
      backup, and an unrecognised input.
- [ ] Restoring `config/.migrations/backup/NNNN/` returns the site to its pre-migration config,
      rehearsed once on the test system (R4).
- [ ] Every migration header states its reversibility; an irreversible one is repeated in the
      release notes.
- [ ] Release notes for each wave name its migrations and the oldest supported upgrade source
      (D10).
- [ ] `0001` and `0002` are promoted only after the runner is on `stable`, each deleting its
      origin block in the same commit.
- [ ] `0003` rewrites `updateSchedule` to ADR-017 D7's object form, reports a dropped weekday,
      and is a no-op on an already-migrated `site.json`.
- [ ] #652 closed against this ADR.
