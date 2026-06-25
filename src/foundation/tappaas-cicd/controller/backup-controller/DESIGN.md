# backup-controller — design

## Language / build

**Bash, by reuse.** The design's component list names a *Python* controller
(`backup-controller.py` + `pbs-api.py` + `schedule-backup.py` +
`verify-backup.py`). For P9 we instead **reuse the existing, tested foundation
PBS bash logic** (`backup/lib/pbs-job.sh`, `backup/lib/pbs-namespace.sh`) by
sourcing it — these already implement the PBS job, namespace, sync-job,
prune-job, ACL, remote and verify operations against the local privileged PBS
API socket (no stored credentials). Reimplementing that in Python would
duplicate working, security-reviewed code for no functional gain.

Bash component: nothing to compile; `install.sh`/`update.sh` link the
`backup-controller` entry onto `PATH` (idempotent).

## Shape

- Sources `common-install-routines.sh` (logging, `get_node_hostname`) then the
  two PBS libs. Sourced with **no** `$1`, so no module JSON is auto-loaded.
- `pbs_reachable` is a cheap ssh probe gating every live command; on failure the
  command degrades to a skip + exit 0.
- Pure helpers reused from the libs (`_pbs_ns_acl_path`, `_pbs_ns_parents`,
  `_pbs_retention_args`, `_pbs_csv_add/remove`) are exercised by `--selftest`.

## Pending / aspiration

- **Python rewrite (design aspiration, NOT done in P9).** The ADR-007 design
  envisions a Python `pbs-api.py` client plus `schedule-backup.py` /
  `verify-backup.py`. If/when the PBS interaction grows beyond what the bash
  libs cover (e.g. richer scheduling, structured error handling, a typed API
  client), port these to a Python package under this directory and switch
  `install.sh` to the compiled-component pattern (nix build + relink). Until
  then, the bash reuse is intentional and sufficient.
- **`schedule` / `verify` depth.** `verify <module>` currently delegates to the
  datastore-wide `pbs_ensure_verify`; a per-snapshot verify trigger is a natural
  next step. `apply-schedule <spec>` now sets the *shared* managed job's start
  time (driven by `backup-manager reconcile`), but a true *per-environment*
  schedule (multiple PBS jobs) is the remaining follow-up.
- **`add-to-job` retention.** `add-to-job --retention SPEC` accepts + echoes the
  resolved retention for the manager, but per-job prune wiring is a follow-up;
  the shared job + the foundation prune-job own retention today.

## Verbs added for ADR-007 verb-alignment (#3)

The query verbs (`job-status` / `list` / `namespaces`) gained `--json` so the
TypeScript `backup-manager` parses structured output (no human-line scraping; an
offline run emits `{"reachable": false}`). Two **mutation** verbs were added so
the manager's `reconcile` can push the resolved cascade into PBS while the
controller owns the PBS write: `add-to-job <vmid> [--retention]` (reuses
`pbs_ensure_vmid`) and `apply-schedule <spec>` (sets the shared job's start time
via `pvesh set`). All degrade gracefully when PBS is unreachable.
