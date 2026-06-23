# backup-controller

Controls the **runtime backup plane**: the Proxmox Backup Server (PBS). It is a
*controller* — it owns no config (the `backup-manager` does); it queries and
triggers PBS on behalf of the manager and the operator. No `validate` verb
(controllers don't ship one).

## Commands

```
backup-controller job-status         Query the shared TAPPaaS PBS backup job
                                     (vmid list, datastore, schedule).
backup-controller list <module>      List snapshots for a module's VM (by vmid).
backup-controller verify <module>    Trigger/report a PBS verify for a module's VM.
backup-controller namespaces         List the datastore's namespaces.
backup-controller --selftest         Pure-function self-test (no cluster).
```

A module name is resolved to its VMID via `CONFIG_DIR/<module>.json`.

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
+ unroutable node. It never contacts a real PBS.
