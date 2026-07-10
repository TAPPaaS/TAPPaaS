# backup — Design notes

Implementation detail for the backup module (created during the Diataxis restructure,
issue #247). Catalog info: [README.md](./README.md); install: [INSTALL.md](./INSTALL.md);
operations: [QUICKREF.md](./QUICKREF.md); test coverage: [TEST.md](./TEST.md). Design
rationale: [ADR-012](../../../docs/ADR/ADR-012-backup-enhancement.md).

## Not a VM

Unlike most foundation modules, PBS is installed **via apt directly on a Proxmox node**
(`imageType: "apt"`), not as a VM — the datastore needs direct access to a `tankc` ZFS
pool. The `backup.mgmt.internal` DNS name points at that node.

## Placement (ADR-012 P1/P2)

`backup.json .placement` decides where (or whether) PBS is realized; the resolved
outcome is recorded as `.placementState`:

| Policy | Meaning |
|--------|---------|
| `auto` (default) | discover a `tankc` pool (preferred `.node` first, then any node); falls back to a `shim` if none is found |
| `node:<name>` | pin PBS to that node's `tankc` |
| `shim` | no datastore — a marker that still satisfies `dependsOn: backup`; dependents install and their `backup:vm` hooks skip gracefully; promoted by `update.sh` once storage exists (unless the policy is an explicit `shim`) |
| `remote-only` | no local PBS; VMs back up off-site by push (`add-push`, ADR-012 P4) |

Legacy deployments (pre-ADR-012, no placementState) are treated as `local` and the
marker is backfilled by `update.sh` — never routed through promotion.

## Managed backup job (issue #200)

No `--all` job is created. The cluster backup job is owned by the `backup:vm` service:
each module that declares `dependsOn: ["backup:vm"]` adds its VMID to a single shared,
marker-tagged job via `services/vm/install-service.sh` (and removes it on delete). Only
data-bearing modules opt in; foundation VMs reproducible from git are intentionally not
auto-backed-up. The `alwaysBackup` VMs in `backup.json` (network/firewall, tappaas-cicd)
bootstrap before the backup server, so they can't declare `backup:vm` — `install.sh`/
`update.sh` register them directly (`pbs_ensure_always`). A pre-existing legacy `--all`
job is migrated in place to the vmid-list model (`lib/pbs-job.sh::pbs_migrate_all_job`).

## Automated schedule

Configured by `install.sh`, kept current by `update.sh`; ordered so each step runs
against a settled datastore:

| Time  | Job    | Purpose |
|-------|--------|---------|
| 21:00 | Backup | Snapshot the managed VM list to the PBS datastore |
| 02:00 | Prune  | Apply the retention policy (4/14d/8w/12m/6y defaults) |
| 03:00 | GC     | Garbage-collect unreferenced chunks |
| 04:00 | Verify | Integrity-check backups (re-verify if older than 30 days) |

## Data integrity / bit-rot protection (issue #228)

The datastore lives on ZFS, so silent bit-rot is a real risk. Two safeguards run
automatically: the daily `verify-<datastore>` verify-job (`--ignore-verified true
--outdated-after 30`, spreading load across the month) and `verify-new` (every backup
verified on arrival). `update.sh` retrofits both on already-deployed servers.

## Boot ordering (issue #230)

PBS services get `After=/Requires=zfs-mount.service` drop-ins so they never open the
chunk store before the ZFS datastore mounts; `update.sh` re-creates them if missing.

## Multi-source namespaces (issue #227)

The single datastore is partitioned so it can safely hold more than local VM backups:

    <datastore>/                 root      local TAPPaaS VM backups
    <datastore>/remote/<name>    Class A   a TAPPaaS buddy's PBS, PULLED here
    <datastore>/external/<name>  Class B   a third-party client, PUSHED here

- **Class A (pull):** `--remove-vanished false` so a source compromise can't erase our
  copy; encryption preserved end-to-end; admin-owned sync + prune.
- **Class B (push):** the client authenticates as `<name>@pbs` with the
  **DatastoreBackup** role on its namespace only (write, no delete); an admin prune-job
  controls retention; the client encrypts with its **own** key — the operator cannot
  read the data.

Parent namespaces are created at install; per-source children on demand by
`backup-manage.sh add-remote / add-external` (config from `services/remote/remote.json`
/ `services/external/external.json` copied to `~/config/`). Operations detail in
[QUICKREF.md](./QUICKREF.md).

## Off-site symmetry, subset, immutability (ADR-012)

One PBS is simultaneously a **pull replicator**, a **push receiver** and a **push
sender**:

| Role | Command | Namespace | Direction |
|------|---------|-----------|-----------|
| pull (Class A) | `backup-manage.sh add-remote <n>` | `remote/<n>` | this PBS pulls a buddy |
| receive (Class B) | `backup-manage.sh add-external <n>` | `external/<n>` | a client pushes in |
| send (P4) | `backup-manage.sh add-push <n> [--make-default]` | remote's `external/<us>` | we push out (remote-only) |

`add-push` registers the remote PBS as Proxmox storage `offsite-<n>`; `--make-default`
routes the managed job there. We hold **write-no-delete** and the **remote owns
prune/retention/immutability** — a local compromise cannot erase the off-site copy
(compromise-isolation suite in [TEST.md](./TEST.md), #389).

- **Subset (pull):** `.groupFilter` in `remote-<n>.json` (string or array, e.g.
  `"type:vm"` or `["group:vm/101","group:vm/102"]`) replicates only part of the source.
- **Independent retention:** each `remote-`/`external-<n>.json` carries its own
  `retention` → a namespace-scoped, destination-owned prune-job.
- **Immutability (opt-in WORM):** `backup.json .immutableSnapshots` takes read-only ZFS
  snapshots of the datastore that no sync/push credential or PBS prune/GC can rewrite
  (only node-local root can):

      "immutableSnapshots": { "enabled": true, "schedule": "daily", "keep": 30 }

  The stronger tier — S3 Object Lock — is provided by an ADR-010 satellite.

- **Endpoint-agnostic tooling (P7):** `backup-manager --pbs <host> <verb>` targets a
  non-local PBS (e.g. a satellite) with the same controller ops.

## Credential handling

The `tappaas@pbs` password resolution order (so installs can run unattended):
`$TAPPAAS_PBS_PASSWORD` → interactive prompt (TTY) → generated from `/dev/urandom` and
saved to `~/.pbs-credentials.txt` (mode 600). An empty/short password is rejected
(PBS requires ≥8 chars). Off-site credentials are prompt-not-store: `add-remote` /
`add-external` / `add-push` prompt at onboarding and never persist the secret in config.
