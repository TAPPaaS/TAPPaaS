# Config migrations

One-time rewrites of the **shape** a site's `config/` is written in — a renamed field, a
changed type, a moved file (ADR-025). Changing a declared field's *value* is not a migration:
that is `module-manager module modify --set` (ADR-020).

> **Ordering (ADR-025 D9 rule 3).** A site receives the runner in one update before it receives
> anything for the runner to run: the runner reached `stable` with this directory empty, and only
> then did `0003` land. A Wave 1 migration (`0004` on) does not merge to `main` until Wave 0 is on
> `stable`. The gate is the release process — from inside a checkout the two cases look identical.

The directory is **empty in the release that introduces the runner** (ADR-025 D11), which is
the Wave 0 exit gate.

## What ships here now

| id | what it does | reversible |
|---|---|---|
| `0003-update-schedule-object.sh` | `site.json` `updateSchedule` becomes `{frequency, weekday, hour}` (ADR-017 D7). A weekday under `daily`/`none` was never read, so it is dropped — and **reported**, because it is the only trace of what the operator believed they had asked for. | yes — restore `.migrations/backup/0003/site.json` |
| `0004-kind-names-the-workload.sh` | `kind` names the workload (ADR-022f: vm, lxc, machine, application, device), authored in each module's source; the ADR-007 marker `"kind": "module"` is removed from deployed configs so the next update's merge can adopt the authored value — except where it is a config's **only** module signal, where it is kept and named, since removing it would hide the module. `"external-host"` → `"machine"`. (#611) | yes — restore `.migrations/backup/0004/<file>` |
| `0005-people-becomes-identities.sh` | `config/people/` becomes `config/identities/` (#628); `people` is left as a symlink to it for one stable cycle, the path's twin of the `people-manager` alias. Refuses when both are real directories — two copies of the domain are a person's to reconcile. | yes — remove the symlink, restore `.migrations/backup/0005/people/` |

Its readers accept both shapes: `lib/update-schedule.sh` (the timer renderer and
`site-manager validate` share it) and `site-manager site show` / `site modify`. That is
deliberate — a restored backup or a site on an older release can still hold the triple, and a
reader that refused one would take that site's updates away. `site modify` always *writes* the
object, so a modify cannot undo a migration the ledger says is done.

## Writing one

A migration is `NNNN-<slug>.sh`. The number is allocated when the migration is written, is
never reused and never changes meaning — the ledger records numbers, so renumbering would
silently re-run or silently skip. Line 2 is the summary the runner prints in
`--list`; the rest of the header states what it changes, which release introduced it, whether
restoring its backup reverses it, and the issue or ADR that required it.

```bash
#!/usr/bin/env bash
# 0003-update-schedule-object.sh — updateSchedule becomes a named object
#
# Introduced: 2.1 (Wave 0, G0.1).  Required by: ADR-017 D7.
# Touches: config/site.json.  Reversible: yes — restore .migrations/backup/0003/.
```

The contract (ADR-025 D3), all of it enforced by review and by the migration's own fixture
test:

| Rule | Why |
|---|---|
| **Idempotent** — a second run changes nothing and exits 0 | the ledger is an audit trail, not the safety mechanism |
| **`--check` writes nothing** and reports what an apply would change | `site-manager update --dry-run` shows an operator what is coming |
| **Back up before the first write**, into `${TAPPAAS_MIGRATION_BACKUP_DIR}` | that copy *is* the rollback (D8); there are no down-migrations |
| **Exit non-zero on any doubt** | stopping costs one night's sweep; guessing costs a site's config |
| **`bash`, `jq`, coreutils and `config/` only** | it runs before the `nixos-rebuild`, so the new system generation and the manager bins may not exist yet |
| **`config/` only** | VMs, the firewall, the cluster and the repository belong to other paths |

The runner exports `CONFIG_DIR`, `TAPPAAS_CONFIG_DIR` and `TAPPAAS_MIGRATION_BACKUP_DIR`
(`config/.migrations/backup/NNNN`); a migration creates that directory itself if it writes.

## Its test ships with it

A change under `config/` with no migration is incomplete; a migration with no fixture test is
untested (ADR-025 D7). Drop `scripts/test/test-migration-NNNN-<slug>.sh` next to the others —
`tappaas-cicd/test.sh` Test 9z sweeps that directory, so it joins the fast tier by existing.
Each fixture builds a throwaway `config/` in a temp dir, runs `--check` (asserting nothing was
written), applies, compares against the expected output, and applies again to prove
idempotence.

## How they run

`scripts/run-migrations.sh`, from `tappaas-self-prepare.sh` — after the control-plane refresh,
before the `nixos-rebuild` and before the sweep's first module (ADR-025 D2). A failure stops
the unit: no rebuild, no sweep, and the #651 notice names the stage `migrate`.

```bash
site-manager update --dry-run        # what is pending, without running anything
run-migrations.sh --list             # the same list, on the cicd
run-migrations.sh --check            # each pending migration's own --check
run-migrations.sh --rerun 0003       # apply one again, deliberately
```
