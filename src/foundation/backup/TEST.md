# backup — tests

## How to run
- **`./test.sh`** (fast) — the module test.sh; aggregates the pure unit suites
  `lib/test-pbs-job.sh` + `lib/test-pbs-namespace.sh` (no cluster access).
- **`TAPPAAS_TEST_DEEP=1 ./test.sh`** — adds a read-only live-PBS reachability check
  (`backup-controller list`).
- Per-VM backup verification is a SERVICE test owned by the *consumer* modules
  (`dependsOn backup:vm`), invoked by `test-module.sh`:
  `./services/vm/test-service.sh <module-name>` (fast) /
  `TAPPAAS_TEST_DEEP=1 ./services/vm/test-service.sh <module-name>` (deep).

## Standard (fast) tests
- `lib/test-pbs-job.sh` (CSV vmid-list helpers in `pbs-job.sh`, no cluster):
  - `_pbs_csv_has`: present/absent membership, no-substring match (14 must not match 140), empty list, single element.
  - `_pbs_csv_add`: add to empty, dedup, numeric-sorted insertion.
  - `_pbs_csv_remove`: remove middle, remove last→empty, remove-absent no-op, no-substring removal (14 must not remove 140).
- `lib/test-pbs-namespace.sh` (pure helpers in `pbs-namespace.sh`, no cluster):
  - `_pbs_ns_acl_path`: root, nested (`remote/lars`), and external namespace ACL paths.
  - `_pbs_ns_parents`: outermost-first parent chain for single/nested/deep namespaces.
  - `_pbs_retention_args`: full retention flags, partial set, and empty `{}` → empty string.
- `services/vm/test-service.sh <module>` (live, queries a reachable Proxmox node by SSH):
  - Check 1: asserts PBS storage (`backup.json` `pbsStorageName`, default `tappaas_backup`) is configured AND `active` via `pvesm status`; fatal exit 2 if missing/inactive.
  - Check 2: counts backups for the VMID via `pvesh …/content`; ≥1 passes, 0 is a WARNING (not a failure) — first backup may not have run.

## Deep tests (live; TAPPAAS_TEST_DEEP=1)
- `services/vm/test-service.sh` deep tier (live Proxmox via SSH to `root@<node>.mgmt.internal`):
  - Check 3 — backup age: asserts the most recent backup's `ctime` is < 48h old; older-than-48h or unknown age is a WARNING, not a failure.
  - Check 4 — job coverage: asserts a cluster backup job (`pvesh get /cluster/backup`) covers this VMID (either `all==1` or VMID in its `vmid` list); none found is a WARNING, not a failure.
- The unit tests (`lib/test-pbs-*.sh`) have no deep tier and need no cluster.

## Coverage notes
- A module `test.sh` now aggregates the `lib/test-pbs-*.sh` unit suites (they were
  previously orphaned) + a deep live-PBS reachability check.
- The per-VM service-test deep checks 3 and 4 only WARN on failure (age stale, no covering job), so a "pass" exit can still hide a stale or uncovered backup. Likewise fast Check 2 only warns when zero backups exist.
- No test exercises actual restore (no restore verification), backup encryption, prune/GC execution, or remote/external namespace sync — only configuration presence and recency are checked.
