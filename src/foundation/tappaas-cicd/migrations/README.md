# Config migrations

One-time rewrites of the **shape** a site's `config/` is written in — a renamed field, a
changed type, a moved file (ADR-025). Changing a declared field's *value* is not a migration:
that is `module-manager module modify --set` (ADR-020).

This directory is **empty on purpose** in the release that introduces the runner: a site must
receive the runner in one update before it receives anything for the runner to run
(ADR-025 D9 rule 3, D11).

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
