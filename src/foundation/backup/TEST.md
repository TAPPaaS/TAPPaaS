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

## ADR-012 unit tests (fast; no cluster)
Aggregated by `./test.sh` (all pure helpers):
- `lib/test-pbs-placement.sh` (20) — placement policy parse, `node:` pin, `tankc`
  selection from `pvesm status`, node-list parse, shim/remote-only discovery
  branches, placement-state write/read round-trip.
- `lib/test-pbs-client.sh` (4) — the client reconcile loop visits every current
  node and continues past a failing node (rc semantics).
- `lib/test-pbs-push.sh` (3) — `offsite-<name>` push storage-name derivation.
- `lib/test-pbs-immutable.sh` (7) — datastore-dataset derivation + OnCalendar mapping.
- TS `backup-manager` `test/unit/cascade.test.ts` (60, run via nix `tsc` on cicd) —
  incl. `readPlacement`/`listPeers` (placement + pull/receive/push peers).

## ADR-012 compromise-isolation suite (#389) — run on the 3-node cluster (live)
The headline §389 invariant ("a compromised local system cannot compromise the
remote backup") is inherently a **two-PBS, live** test. Run on the cluster:

1. **Pull (Class A):** with the remote's read-only sync token, attempt to
   delete/prune the *local* source datastore → **must be denied**.
2. **Push (P4):** with the local push credential (`offsite-<n>` storage), attempt
   to delete/prune the *remote* namespace → **must be refused** (write-no-delete).
3. **Immutability:** with `.immutableSnapshots.enabled`, attempt to delete a
   retention-locked `@immutable-*` snapshot as the sync/push user or via PBS
   prune → **refused** (only node-local root can, and Object Lock on a satellite
   refuses even that).
4. **Subset:** a `remote-<n>.json` `.groupFilter` pull replicates only the
   selected groups; verify the off-site namespace holds the subset with its own
   (longer) retention.
5. **remote-only restore:** a single node with `remote-only` + `add-push` backs
   up off-site and restores from the remote **with** the encryption key, **fails
   without** it.
6. **Simulated cluster compromise:** confirm no local credential can delete the
   off-site copy or the immutable history.

## Coverage notes
- A module `test.sh` now aggregates the `lib/test-pbs-*.sh` unit suites (they were
  previously orphaned) + a deep live-PBS reachability check.
- The per-VM service-test deep checks 3 and 4 only WARN on failure (age stale, no covering job), so a "pass" exit can still hide a stale or uncovered backup. Likewise fast Check 2 only warns when zero backups exist.
- No test exercises actual restore (no restore verification), backup encryption, prune/GC execution, or remote/external namespace sync — only configuration presence and recency are checked.
