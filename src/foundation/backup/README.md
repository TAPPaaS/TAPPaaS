# backup

Primary audience: TAPPaaS admin.

Proxmox Backup Server (PBS) for TAPPaaS — automated, verified, deduplicated VM backups
with retention, restore tooling and off-site options.

## What you get

| Capability | Access from | How |
|------------|-------------|-----|
| Daily automated VM backups (21:00) of every opted-in module plus the `alwaysBackup` foundation VMs (`network`, `firewall`, `tappaas-cicd`) | — | managed cluster backup job; modules opt in via `dependsOn: ["backup:vm"]` |
| Retention (4 last / 14 daily / 8 weekly / 12 monthly / 6 yearly) with daily prune (02:00) and garbage collection (03:00) | tappaas-cicd | automatic; `backup-manage.sh prune` / `gc` on demand |
| Integrity verification: every new backup verified on arrival, daily verify-job (04:00) re-verifies anything older than 30 days | tappaas-cicd | automatic (issue #228) |
| PBS web GUI | `mgmt` zone | `https://backup.mgmt.internal:8007` (root@pam, or tappaas@pbs for backup ops) |
| VM restore, incl. to another node/storage | tappaas-cicd | `restore.sh --vmid <id> [--node <n>] [--storage <s>]` |
| Manual/ad-hoc backups and job management | tappaas-cicd | `backup-manage.sh status \| run-now <vmid> \| run-now-all \| list-jobs \| verify <id>` |
| Multi-source vault: pull a buddy's PBS (`remote/<name>`) or receive third-party pushes (`external/<name>`) in isolated namespaces | tappaas-cicd | `backup-manage.sh add-remote / add-external` (issue #227) |
| Off-site push for storage-less sites (`remote-only` placement) and placement policies incl. a `shim` | tappaas-cicd | `backup.json .placement`; `backup-manage.sh add-push <n>` (ADR-012) |
| Opt-in WORM-ish immutability (read-only ZFS snapshots of the datastore) | tappaas-cicd | `backup.json .immutableSnapshots` (ADR-012 §3.5) |

Reference docs in this directory:

- [QUICKREF.md](./QUICKREF.md) — day-to-day operations quick reference (status, restore,
  maintenance, multi-source setup, ADR-012 features).
- [TEST.md](./TEST.md) — what the module tests cover (fast and deep tiers).

## What is not included

- Foundation VMs that are reproducible from git are deliberately **not** auto-backed-up —
  only opt-in (`backup:vm`) modules and the `alwaysBackup` list are.
- S3 Object Lock immutability — that stronger tier is provided by an ADR-010 `satellite`,
  not this module (local immutability is ZFS-snapshot based, opt-in).
- Automated restore verification — test restores are an operator practice (see
  [QUICKREF.md](./QUICKREF.md) and [TEST.md](./TEST.md)).

## Requirements

- A node with a `tankc` ZFS storage pool for the datastore (preferred node/storage:
  `tappaas3` / `tankc1` in `backup.json`). Without one, `auto` placement installs a
  `shim` (no datastore) that still satisfies dependents and can be promoted later.
- PBS is installed via apt **on the Proxmox node itself** (not a VM), from
  `http://download.proxmox.com/debian/pbs`.
- Zone: `mgmt` (DNS name `backup.mgmt.internal`).

## Dependencies

| Depends on | Purpose |
|------------|---------|
| — | `dependsOn` is empty: backup is the first module `rest-of-foundation.sh` installs, before identity and logging |

Provides the `vm`, `remote` and `external` services consumed by other modules
(`backup:vm` is how a module opts into the managed backup job).

For installation steps see [INSTALL.md](./INSTALL.md).
