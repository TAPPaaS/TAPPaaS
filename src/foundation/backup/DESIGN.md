# backup — Design notes

Implementation detail for the backup module (created during the Diataxis restructure).
Catalog info: [README.md](./README.md); install: [INSTALL.md](./INSTALL.md);
operations: [README.md](./README.md); recovery: [RESTORE.md](./RESTORE.md); test coverage: [TEST.md](./TEST.md). Design
rationale: [ADR-012](../../../docs/ADR/ADR-012-backup-enhancement.md).

## Backup strategy & disaster recovery

TAPPaaS follows the **3-2-1 principle**: 3 copies of data, in 2 different formats, with 1 copy
off-site. It rests on one design choice — **all configuration and user data lives inside the module
VMs** (and the instance's own config lives in the `tappaas-cicd` VM) — so backing up the VMs backs up
everything that matters. Three layers deliver it:

1. **Local snapshots (primary).** PBS snapshots the managed VM list on a schedule (default daily),
   with compression + deduplication and the retention defaults below (4/14d/8w/12m/6y) — enough
   history to recover from a slow-burn compromise or a late-noticed deletion. A local PBS is **not
   mandatory** (§Placement): a small or single-node site can consume an **external** PBS by URL and
   have its clients push straight there, and a site with no datastore at all still installs — as a
   shim, so the dependency graph stays satisfiable until storage appears.
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

1. **Rebuild from backup** — restore the VMs onto TAPPaaS hardware (the implemented path; the
   firewall, the mothership and `config/` restores are **rehearsed**, see
   [RESTORE.md](./RESTORE.md)).
2. **Borrow a peer** — re-establish the services from backup on another TAPPaaS system, in isolated
   zones.
3. **Rent cloud** — re-establish the VMs on cloud VPCs.

(Plus the personal export above, to re-home an individual account on another TAPPaaS.)

Two ordering facts decide whether a rebuild works at all, and both are easy to discover too
late: the **encryption key must be imported before any restore that has to decrypt**, and
`config/` — the declared state everything else is rebuilt from — is captured as a file backup
precisely so it can be restored *before* there is a VM to restore into.

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

## Placement (ADR-012 §2.1/§2.2)

Where PBS lives is a **resolved state, not a policy**. There is no `placement` field to
author: `placementState` ships empty, `install.sh` resolves it once, and the outcome is
written back so it is inspectable and idempotent.

| `placementState` | How it gets there | Meaning |
|---|---|---|
| *(empty)* | the released default | unresolved — install derives it |
| `node:<name>` | a `tankc` pool was found there | PBS software + datastore on that node's Proxmox OS (not a VM) |
| `shim` | no `tankc` anywhere | marker only. Still satisfies `dependsOn: backup:vm`, so dependents install and their `backup:vm` hooks skip gracefully; re-derived on every update, so it promotes in place the moment storage appears |
| `external` | forced at install, with a `pbsUrl` | a PBS this site does not provision, consumed by URL (#456). **Permanent** |

Two operator inputs shape resolution, both on `backup.json`: **`.node`** restricts
discovery to one named node (empty searches every node), and **`.pbsUrl`** is the PBS
clients push to (default `backup.mgmt.internal`).

The resolved *node* lives in the state itself (`node:<name>`), not in `.node` — `.node`
is an operator input that the 3-way merge may legitimately reset to the release default,
so a resolved value written there could not survive an update.

Legacy states are migrated in place by `update.sh`, never by a promotion-reinstall:
`local` → `node:<name>` (**the datastore is left exactly where it is**) and
`remote-only` → `external`, seeding `pbsUrl` from the old push target. A pre-ADR-012
install with no state at all is backfilled the same way.

## Managed backup job

No `--all` job is created. The cluster backup job is owned by the `backup:vm` service:
each module that opts into `backup:vm` adds its VMID to a marker-tagged cluster job via
`services/vm/install-service.sh` (and removes it on delete). Backup is **opt-in**: only
modules that ask are backed up, and hardware or test modules deliberately ask for
nothing.

There are **two ways to ask**, because a module that boots *before* the backup server
cannot depend on it:

- `dependsOn: ["backup:vm"]` — a hard dependency, with install ordering.
- `integratesWith: ["backup:vm"]` — the optional integration (#501), used by the
  foundation VMs (`network`'s firewall, `tappaas-cicd`) whose state is not reproducible
  from git. It wires the same service without imposing the ordering.

Membership is the union of the two (`pbs_optin_vmids`), reconciled by the module's own
install/update (`pbs_ensure_declared`) so a module that declared the integration before
the backup server existed is picked up once it does. The old `alwaysBackup` list is
deprecated and read for one release only.

**Per-module schedules mean more than one job.** Proxmox schedules a *job*, not a guest,
so each distinct resolved frequency gets its own marker-tagged cluster job — a
**bucket** (ADR-012 §3.2). `daily` is the original job, marker and start time unchanged;
`weekly` (`sun 21:00`) and `monthly` (`*-*-01 21:00`) are created on demand and deleted
when they empty. A schedule change **moves** a guest between buckets rather than leaving
it in two, which would back it up twice wherever the cadences coincide.

A pre-existing legacy `--all` job is migrated in place to the vmid-list model
(`lib/pbs-job.sh::pbs_migrate_all_job`).

## File-level backup (`backup:filesystem`, ADR-012 §3.1)

`backup:vm` snapshots a guest from the outside, which needs nothing inside it.
`backup:filesystem` captures **named paths within** a guest, and only the guest can read
its own files — so this is the one part of the backup system that runs *inside* a
workload: a `proxmox-backup-client` push into `fs/<module>`, on a timer, with a
write-no-delete login scoped to that namespace and a client-side encryption key.

It is offered only on guest OS types TAPPaaS knows the layout of (NixOS today). Any
other `ostype` **fails the service install** rather than capturing something half-right,
and a declared path that does not exist in the guest fails the capture — a backup that
silently stopped covering something is the failure this whole design exists to prevent.

Deleting a module keeps its file backups: `delete-service.sh` removes the manifest, the
runner and the guest's write credential, and leaves the namespace, its snapshots and the
escrowed key. Removing a module is exactly when its backups matter.

## Encryption keys and the DR linchpin (ADR-012 §2.5.1)

Backups are encrypted client-side, so a key that does not outlive its client is the
difference between a restore and a pile of ciphertext. Keys are escrowed centrally on
`tappaas-cicd` — but that escrow is *inside* the system a full-site rebuild recreates,
so it cannot be the only copy. `backup-manager key export <dest>` writes them to
removable media (with a README, because whoever needs it will be rebuilding a site and
will not have this repository); `key import` loads them onto a rebuilt mothership, and
refuses to overwrite a key that is already escrowed. Losing every copy of a key makes
the backups it encrypted permanently unreadable.

## Automated schedule

Configured by `install.sh`, kept current by `update.sh`; ordered so each step runs
against a settled datastore:

| Time  | Job    | Purpose |
|-------|--------|---------|
| 20:30 | Capture | File-level captures (`backup:filesystem`), ahead of the VM job so a night's capture and snapshot describe the same state |
| 21:00 | Backup | Snapshot the daily bucket's VM list to the PBS datastore (weekly `sun 21:00`, monthly `*-*-01 21:00`) |
| 02:00 | Prune  | Apply the retention policy (4/14d/8w/12m/6y defaults) |
| 03:00 | GC     | Garbage-collect unreferenced chunks |
| 04:00 | Verify | Integrity-check backups (re-verify if older than 30 days) |

## Data integrity / bit-rot protection

The datastore lives on ZFS, so silent bit-rot is a real risk. Two safeguards run
automatically: the daily `verify-<datastore>` verify-job (`--ignore-verified true
--outdated-after 30`, spreading load across the month) and `verify-new` (every backup
verified on arrival). `update.sh` retrofits both on already-deployed servers.

## Boot ordering

PBS services get `After=/Requires=zfs-mount.service` drop-ins so they never open the
chunk store before the ZFS datastore mounts; `update.sh` re-creates them if missing.

## Multi-source namespaces

The single datastore is partitioned so it can safely hold more than local VM backups:

    <datastore>/                 root      local TAPPaaS VM backups
    <datastore>/fs/<module>      —         a module's file-level capture (§File-level backup)
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
[README.md](./README.md).

## Off-site symmetry, subset, immutability (ADR-012)

One PBS is simultaneously a **pull replicator**, a **push receiver** and a **push
sender**:

| Role | Command | Namespace | Direction |
|------|---------|-----------|-----------|
| pull (Class A) | `backup-manage.sh add-remote <n>` | `remote/<n>` | this PBS pulls a buddy |
| receive (Class B) | `backup-manage.sh add-external <n>` | `external/<n>` | a client pushes in |
| send (P4) | `backup-manage.sh add-push <n> [--make-default]` | remote's `external/<us>` | we push out (a site with no local PBS) |

`add-push` registers the remote PBS as Proxmox storage `offsite-<n>`; `--make-default`
routes the managed job there. We hold **write-no-delete** and the **remote owns
prune/retention/immutability** — a local compromise cannot erase the off-site copy
(compromise-isolation suite in [TEST.md](./TEST.md)).

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
