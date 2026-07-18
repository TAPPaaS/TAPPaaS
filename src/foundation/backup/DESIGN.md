# backup — Design notes

Implementation detail for the backup module (created during the Diataxis restructure,
issue #247). Catalog info: [README.md](./README.md); install: [INSTALL.md](./INSTALL.md);
operations: [QUICKREF.md](./QUICKREF.md); test coverage: [TEST.md](./TEST.md). Design
rationale: [ADR-012](../../../docs/ADR/ADR-012-backup-enhancement.md).

## Backup strategy & disaster recovery

TAPPaaS follows the **3-2-1 principle**: 3 copies of data, in 2 different formats, with 1 copy
off-site. It rests on one design choice — **all configuration and user data lives inside the module
VMs** (and the instance's own config lives in the `tappaas-cicd` VM) — so backing up the VMs backs up
everything that matters. Three layers deliver it:

1. **Local snapshots (primary).** PBS snapshots the managed VM list on a schedule (default daily),
   with compression + deduplication and the retention defaults below (4/14d/8w/12m/6y) — enough
   history to recover from a slow-burn compromise or a late-noticed deletion. A local PBS is **not
   mandatory**: the placement policy (§Placement) lets small or single-node sites run `remote-only`
   and push straight off-site.
2. **Off-site copy.** A remote PBS — a TAPPaaS *buddy* (any TAPPaaS system can be another's PBS;
   backups are encrypted, so you need not trust the remote operator), your own cloud PBS, or an
   ADR-010 satellite with S3 Object-Lock. The pull/push/subset/immutability model is in §"Off-site
   symmetry".
3. **Personal export.** A user can back up their own data to detachable media (e.g. USB) in each
   application's native format — which also lets them leave a TAPPaaS system without losing data.

### Disaster recovery

Four disaster classes are in scope: hardware/environmental loss (fire, power), a bad software
update, a hostile intrusion, and accidental deletion by a user or admin. High availability (owned by
the **cluster** module) blunts some of these; when it can't, TAPPaaS recovers by one of three
methods:

1. **Rebuild from backup** — restore the VMs onto TAPPaaS hardware (the implemented, tested path).
2. **Borrow a peer** — re-establish the services from backup on another TAPPaaS system, in isolated
   zones.
3. **Rent cloud** — re-establish the VMs on cloud VPCs.

(Plus the personal export above, to re-home an individual account on another TAPPaaS.)

## Not a VM

Unlike most foundation modules, PBS is installed **via apt directly on a Proxmox node**
(`imageType: "apt"`), not as a VM — the datastore needs direct access to a `tankc` ZFS
pool. The `backup.mgmt.internal` DNS name points at that node.

## Why native apt, not a VM

Four PBS deployment methods were weighed; TAPPaaS chose **native**:

| Option | Verdict | Rationale |
|--------|---------|-----------|
| **Dedicated** physical PBS host | rejected | fullest separation + native disk access (can double as a cluster quorum node), but a second machine per site — too costly/complex for small systems |
| **Native** — apt on a PVE node | **chosen** | direct native disk access, shares the PVE kernel (resource-light), runs on a single-node system, trivial to keep current (`apt`) |
| **LXC** on a node | rejected | shares the kernel, but disk passthrough is still not truly native and is fiddlier than apt-on-host |
| **VM** on a node | rejected | disk access is very indirect, restore-after-hardware-failure is complex, and Proxmox advises against it |

Native's trade-offs are accepted: PBS and PVE share a kernel (fine — TAPPaaS tracks conservative
Proxmox releases), and a running backup loads the node (mitigated by keeping backup nodes to
HA-failover / low-priority roles). The datastore is the `tankc` ZFS pool the **cluster** module
creates — reserved for backup data only, so a production-disk failure never touches backups. Local
ZFS is favoured over NFS/iSCSI/S3 for the on-site datastore; the off-site **S3 Object-Lock** tier is
an ADR-010 satellite's role, not the local PBS's.

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
