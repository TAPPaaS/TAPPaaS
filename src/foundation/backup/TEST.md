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
  - Check 1: asserts PBS storage (`backup.json` `pbsStorageName`, default `tappaas_backup`) is configured AND `active` via `pvesm status`. Fatal (exit 2) when the storage is missing, or reads `inactive` with no error. A probe that times out or returns a 500 — which is what a *running* backup does to it — is reported as **unknown**, a warning, not a failure (#636).
  - Check 2: counts backups for the VMID via `pvesh …/content`; ≥1 passes, 0 is a WARNING (not a failure) — first backup may not have run.

## Deep tests (live; TAPPAAS_TEST_DEEP=1)
- `services/vm/test-service.sh` deep tier (live Proxmox via SSH to `root@<node>.mgmt.internal`):
  - Check 3 — backup age: asserts the most recent backup's `ctime` is < 48h old; older-than-48h or unknown age is a WARNING, not a failure.
  - Check 4 — job coverage: asserts a cluster backup job (`pvesh get /cluster/backup`) covers this VMID (either `all==1` or VMID in its `vmid` list); none found is a WARNING, not a failure.
- The unit tests (`lib/test-pbs-*.sh`) have no deep tier and need no cluster.
- `lib/test-pbs-dns.sh` (15) — the PBS's DNS name (#612): the name is the instance's; a legacy
  A record is deleted before the alias is added; a machine Host gets a DNS entry first; an
  unknown Host is refused with nothing changed; a dns-manager with no alias verb never touches the A
  record, and a failed alias puts it back (`dns-manager` stubbed, calls asserted in order).
- `lib/test-pbs-host.sh` (11) — who patches the PBS's Host (#603): a cluster node → the
  cluster module; a registered machine → its instance; an unregistered one is adopted
  (`--wait 0`); a failed adopt is `none`, warned with the command; an unreachable cluster is
  `unknown` and nothing is adopted on a guess.
- `lib/test-pbs-reset.sh` (19) — `placement reset` (#607): names, the `backup.json` rewrite,
  the `pvesm add` argv, and the order of the node-side storage rename.

## ADR-012 unit tests (fast; no cluster)
Aggregated by `./test.sh` — 229 asserts across eleven pure-helper suites:
- `lib/test-pbs-placement.sh` (63) — the full state-resolution matrix (empty /
  `shim` / `node` (+ `.node`) / `external` × forced × storage found or not); #602: an
  empty state adopts a PBS already serving — on a machine that is not a cluster
  member, found through `pbsUrl` (an alias such as `backup` is recorded as the Host's
  own name, e.g. `tappaas3`), or on a cluster node with its own pool — ahead of
  any discovery, stops as `unmanaged` when only an unmanaged host answers, and never
  probes a concrete state; `pbsUrl`
  defaulting, `tankc` selection and exact-storage probing from `pvesm status`,
  node-list parse, and the state write/read round-trip (including that `.node`,
  the operator's discovery constraint, is never overwritten).
- `lib/test-pbs-migrate.sh` (33) — the §4.1 legacy backfill: `local` →
  `node` (+ `.node`) (datastore untouched), `remote-only` → `external` with `pbsUrl`
  seeded from the old push target, `.placement` always dropped, idempotence, and
  a missing config file being a no-op rather than an error.
- `lib/test-pbs-legacy-guard.sh` (14) — `update.sh`'s legacy-placement guard,
  extracted from the real file and run in a child **`bash -e`** with stubbed
  helpers: member → `node` (+ `.node`), non-member → adopt `external`, unreachable →
  stop, failed adopt → stop rather than fall through to the `node` (+ `.node`) write.
  The sibling suites run without `-e` and call predicates inside `$( )`, where
  the abort of #625 cannot happen — this suite is the one that reproduces it.
- `lib/test-pbs-schedule.sh` (38) — the schedule vocabulary, **every sub-daily
  form refused** (the §3.2 ceiling), calendar events and bucket markers, the
  Site → Environment → Module cascade, and the loud failure on a bad spec.
- `lib/test-pbs-membership.sh` (16) — job membership is `dependsOn` ∪
  `integratesWith`; opting out is honoured; and the `alwaysBackup` regression
  that a stale entry must not truncate the list **under `set -e`** — the only
  condition the original bug appeared under.
- `lib/test-pbs-fs.sh` (31) — `backup:filesystem`: namespace/archive/authid
  derivation, the guest-OS gate, the capture manifest (and that it carries no
  credential and is not module-shaped).
- `lib/test-pbs-external.sh` (20) — consuming a PBS by URL: URL parsing
  (scheme/port/tunnel forms), the permanence guard from every state, datastore
  choice, and refusal of an unparseable URL.
- `lib/test-pbs-client.sh` (4) — the client reconcile visits every current node
  and continues past a failing one.
- `lib/test-pbs-push.sh` (3) / `lib/test-pbs-immutable.sh` (7) /
  `lib/test-pbs-job.sh` (13) / `lib/test-pbs-namespace.sh` (9) — push storage
  naming, dataset + OnCalendar derivation, CSV vmid-list helpers, ACL paths.

Elsewhere (run by their own components' `test.sh`):
- TS `backup-manager` `test/unit/cascade.test.ts` (116) — the cascade incl.
  schedules and the ceiling, placement classification with legacy values folded
  in, shape-based module discovery (#544) against the exact files that used to
  be misclassified, membership by either relationship, and numeric-vs-string
  `vmid`.
- `backup-controller/test.sh` (18) — incl. the key-escrow export/import round
  trip against a throwaway escrow.
- `site-manager/test.sh` — node-add wires the backup reconcile (§2.4), and the
  orphan-field check honours `integratesWith`.

## Live rehearsals (mutating; run deliberately, not by `test.sh`)

These are the checks that only a real cluster can answer. Run them as described
in [RESTORE.md](./RESTORE.md);
the transcript of the first run is in the ADR-012 implementation tracker.

1. **`config/` restore** — restore `fs/<module>` into a scratch dir, `diff -r`
   against the live tree. Then repeat **without** `--keyfile`: it must fail.
2. **VM restore alongside the original** — `restore.sh --vmid <id>
   --target-vmid <unused>`: stopped, fresh MACs, partition table intact,
   then destroy. Never start a copy on the original's network.
3. **Write-no-delete** — with a capture credential, `snapshot forget` must be
   refused (`missing Datastore.Modify|Datastore.Prune`) and the snapshot must
   survive.
4. **Bucket moves** — place a throwaway VMID in `weekly`, then `monthly`: the
   emptied bucket's job is deleted, and the production daily job is untouched.
5. **Key round trip** — `key export` to media, `key import` onto a throwaway
   escrow, `cmp` the result; re-import must not overwrite.

## ADR-012 compromise-isolation suite (#389) — `./test-compromise-isolation.sh`

**Run deliberately, not by `test.sh`** — it creates a datastore, a credential, a
remote and a sync job on the live PBS, and removes all of them again. Run it
after any change to the credential model, and at least once per release.

```bash
./test-compromise-isolation.sh      # 12 assertions, self-tearing-down
```

It proves on real infrastructure, rather than by assertion:

1. **Pull is a real movement** — a destination pulls a **subset** (group filter)
   of the source into its own namespace with a **read-only** credential, the
   only credential a puller ever holds (§1.4).
2. **The invariant** — that same credential, which is what an attacker holding
   the off-site system would have, **cannot delete or prune the source**. Both
   attacks are attempted; both must be refused
   (`missing Datastore.Modify|Datastore.Prune`), and the source snapshot must
   still be there afterwards.
3. **Retention is owned by the destination**, so the off-site copy runs its own
   (typically longer) policy, independent of the source.

The production datastore is only ever a pull **source** and is never written to.

**Still not covered by it:** a genuinely *separate* PBS host. The suite pulls
between two datastores on one server, which exercises the credential scoping,
the sync path and the subset filter faithfully, but not network isolation or a
satellite over a tunnel. Those need a second machine.

**Proven separately, live** (see the ADR-012 tracker): a client's
write-no-delete credential cannot erase its own history; a restore succeeds with
the encryption key and is refused without it; the key survives an
export → media → import round trip byte-identically.

## Coverage notes
- A module `test.sh` now aggregates the `lib/test-pbs-*.sh` unit suites (they were
  previously orphaned) + a deep live-PBS reachability check.
- The per-VM service-test deep checks 3 and 4 only WARN on failure (age stale, no covering job), so a "pass" exit can still hide a stale or uncovered backup. Likewise fast Check 2 only warns when zero backups exist.
- No test exercises actual restore (no restore verification), backup encryption, prune/GC execution, or remote/external namespace sync — only configuration presence and recency are checked.
