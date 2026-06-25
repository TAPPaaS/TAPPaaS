# backup-controller

Controls the **runtime backup plane**: the Proxmox Backup Server (PBS). It is a
*controller* — it owns no config (the `backup-manager` does); it queries and
triggers PBS on behalf of the manager and the operator. No `validate` verb
(controllers don't ship one).

## Commands

```
backup-controller job-status [--json]   Query the shared TAPPaaS PBS backup job
                                        (vmid list, datastore, schedule).
backup-controller list <module> [--json]
                                        List snapshots for a module's VM (by vmid).
backup-controller verify <module>       Trigger/report a PBS verify for a module's VM.
backup-controller namespaces [--json]   List the datastore's namespaces.
backup-controller add-to-job <vmid> [--retention SPEC]
                                        Add <vmid> to the shared managed PBS
                                        backup job (PBS mutation; reuses
                                        pbs_ensure_vmid). --retention is recorded/
                                        echoed; per-job prune wiring is a follow-up.
backup-controller apply-schedule <spec> Set the shared managed job's start time
                                        (PBS mutation; e.g. "21:00").
backup-controller --selftest            Pure-function self-test (no cluster).
```

A module name is resolved to its VMID via `CONFIG_DIR/<module>.json`.

### Query / mutate split

`job-status` / `list` / `namespaces` are **read-only queries**; with `--json`
they emit a single machine-readable JSON object (including `{"reachable":
false}` when PBS is offline) so the TypeScript `backup-manager` (`CliClient`)
parses structured output instead of scraping human lines.

`add-to-job` / `apply-schedule` are the **PBS mutations** that `backup-manager
reconcile` drives: the *manager* resolves the Site→Environment→Module cascade and
calls these; the *controller* owns the PBS write. They reuse the foundation
`pbs-job.sh` (`pbs_ensure_vmid`, the shared managed job) — no PBS API is
reimplemented.

## Reuse — it does NOT reimplement PBS

The controller **sources the tested foundation PBS bash libraries** rather than
talking to the PBS API itself:

- [`backup/lib/pbs-job.sh`](../../../backup/lib/pbs-job.sh) — the shared
  `dependsOn backup:vm` job: `pbs_managed_job_id`, `pbs_job_vmids`,
  `pbs_storage_name`, `pbs_node`, `pbs_ensure_verify`, and the pure CSV helpers.
- [`backup/lib/pbs-namespace.sh`](../../../backup/lib/pbs-namespace.sh) — the
  multi-source datastore namespaces: `pbs_ns_list` and the pure path/retention
  helpers (`_pbs_ns_acl_path`, `_pbs_ns_parents`, `_pbs_retention_args`).

`PBS_LIB_DIR` / `COMMON_ROUTINES` can point these at alternate locations (tests
use fakes). When the libs aren't found, the CLI still loads (`help`, `--selftest`).

## Graceful degradation

Every live command first probes a reachable mgmt node. If PBS / the cluster is
unreachable, the command prints a skip notice and **exits 0** — so offline runs
and the test suite never fail on a missing cluster. The actual restore is done by
the foundation [`backup/restore.sh`](../../../backup/restore.sh) (driven via
`backup-manager restore` → `backup-restore.sh`).

## Testing

`test.sh` is fully offline: syntax, `help`, the pure-function `--selftest`, and
graceful degradation of `job-status` / `namespaces` / `list` against a fake lib
+ unroutable node. It never contacts a real PBS. The `--json` query output and
the `add-to-job` / `apply-schedule` mutations likewise degrade gracefully when
PBS is unreachable (`--json` emits `{"reachable": false}`; mutations skip + exit
0), so offline runs and the manager's `reconcile --apply` are safe to attempt.
