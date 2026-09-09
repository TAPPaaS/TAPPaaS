# TAPPaaS Backup Quick Reference

Run all commands from `tappaas-cicd` as the `tappaas` user.

## Initial Setup

```bash
cd ~/TAPPaaS/src/foundation/backup
./install.sh
```

## Daily Operations

### Check Backup Status
```bash
./backup-manage.sh status          # Overview of PBS system
./backup-manage.sh list-jobs       # Show scheduled backup jobs
```

### Manual Backups
```bash
./backup-manage.sh run-now 101     # Backup single VM
./backup-manage.sh run-now-all     # Backup all VMs
```

### Restore Operations
```bash
# List available backups
./restore.sh --list-all            # All backups
./restore.sh --vmid 101 --list     # Backups for VM 101

# Restore VM
./restore.sh --vmid 101            # Restore latest backup
./restore.sh --vmid 101 --node tappaas2   # Restore to different node
```

### Maintenance
```bash
./backup-manage.sh prune           # Remove old backups per retention policy
./backup-manage.sh gc              # Free up disk space
./backup-manage.sh retention       # Show retention settings
./backup-manage.sh verify <id>     # Manually verify a backup's integrity
```

## Common Scenarios

### Disaster Recovery - Full VM Restore
```bash
# 1. List available backups
./restore.sh --vmid <vmid> --list

# 2. Restore the VM
./restore.sh --vmid <vmid>

# 3. Start VM when prompted (or manually later)
```

### Test Restore alongside the original (rehearsing recovery)

```bash
# Restore into an UNUSED vmid: stopped, fresh MACs, original untouched.
./restore.sh --vmid 110 --target-vmid 910 --node tappaas1 --storage tanka1
ssh root@tappaas1.mgmt.internal qm config 910      # inspect it
ssh root@tappaas1.mgmt.internal qm destroy 910     # when done
```

Never start a restored copy on the same network as its running original — two
guests answering for one identity is worse than the guest being down.

### Test Restore to Different Node
```bash
# Restore to secondary node for testing without affecting production
./restore.sh --vmid 101 --node tappaas2 --storage tanka2
```

### Before Major Changes
```bash
# Backup specific VMs before risky operations
./backup-manage.sh run-now 101
./backup-manage.sh run-now 102
```

### Weekly Maintenance
```bash
# Check status and clean up
./backup-manage.sh status
./backup-manage.sh prune
./backup-manage.sh gc
```

## Troubleshooting

### Backup Failing
```bash
# Check PBS status
ssh root@backup.mgmt.internal "systemctl status proxmox-backup"

# Check disk space on PBS node
ssh root@backup.mgmt.internal "df -h"

# Check PBS logs
ssh root@backup.mgmt.internal "journalctl -u proxmox-backup -f"
```

### "unable to open chunk store" right after a reboot
The PBS services are ordered `After=/Requires=zfs-mount.service` so they wait
for the ZFS datastore to mount on boot (issue #230). If you ever see this error,
confirm the drop-ins are present, then reload + restart:
```bash
ssh root@backup.mgmt.internal "cat /etc/systemd/system/proxmox-backup-proxy.service.d/zfs-wait.conf"
ssh root@backup.mgmt.internal "systemctl daemon-reload && systemctl restart proxmox-backup-proxy"
```
Re-running the backup module's `update.sh` re-creates the drop-ins if missing.

### Restore Issues
```bash
# Verify backup integrity
./restore.sh --vmid 101 --list     # Check if backups exist

# Check storage availability on target node
ssh root@tappaas1.mgmt.internal "pvesm status"
```

### Full Disk
```bash
# Run garbage collection to free space
./backup-manage.sh gc

# Check if old backups should be pruned
./backup-manage.sh retention
./backup-manage.sh prune
```

## PBS GUI Access

URL: `https://<pbs-node-ip>:8007`

Login options:
- **root@pam** - Full administrative access
- **tappaas@pbs** - Backup operations only

## Important Files

- `backup.json` - PBS installation configuration
- `configure.sh` - Automated PBS setup
- `restore.sh` - VM restoration utility
- `backup-manage.sh` - Backup management operations

## Default Retention Policy

- Last 4 backups
- 14 daily backups (2 weeks)
- 8 weekly backups (2 months)
- 12 monthly backups (1 year)
- 6 yearly backups

## Multi-source backups (namespaces, issue #227)

The single PBS datastore is partitioned into namespaces so it can safely hold
more than just local VM backups:

```
<datastore>/                 root      → local TAPPaaS VM backups (unchanged)
<datastore>/remote/<name>    Class A   → a TAPPaaS buddy's PBS, PULLED here
<datastore>/external/<name>  Class B   → a third-party client, PUSHED here
```

`remote` and `external` parent namespaces are created by `install.sh`; per-source
child namespaces are created on demand by the commands below.

### Class A — TAPPaaS buddy (pull)
This PBS pulls another cluster's PBS into `remote/<name>` (`--remove-vanished
false`, so a source compromise can't erase our copy; encryption preserved
end-to-end; admin-owned sync + prune).

```bash
cp services/remote/remote.json ~/config/remote-lars.json   # edit host/store/namespace/retention
./backup-manage.sh add-remote lars        # prompts for the buddy's API auth-id + password
./backup-manage.sh list-sources
./backup-manage.sh remove-remote lars            # keeps the synced data
./backup-manage.sh remove-remote lars --purge    # also deletes remote/lars
```

### Class B — external client (push)
A non-TAPPaaS device writes into `external/<name>`. The client authenticates as
`<name>@pbs` with the **DatastoreBackup** role on that namespace only (write, no
delete); an admin prune-job controls retention; datastore-wide `verify-new`
flags key-swap anomalies. **The client encrypts with its own key** — the
operator cannot read the data.

```bash
cp services/external/external.json ~/config/external-synology.json   # edit namespace/retention
./backup-manage.sh add-external synology   # prompts for the client password (blank = auto-generate)
./backup-manage.sh remove-external synology [--purge]
```

Client side (encrypt with the **client's** key):
```bash
# Synology Hyper Backup → rsync target, or proxmox-backup-client on TrueNAS Scale / MacBook:
proxmox-backup-client backup data.pxar:/path \
  --repository 'synology@pbs@<pbs-host>:<datastore>' --ns 'external/synology' \
  --keyfile /path/to/client.key
# Fingerprint: ssh root@backup.mgmt.internal "proxmox-backup-manager cert info | grep Fingerprint"
```

## ADR-012 — Placement, capabilities, schedules, off-site

### Placement: where (or whether) PBS lives

There is **no `placement` policy field**. `placementState` is the single source
of truth: it ships empty, `install.sh` resolves it once, and the resolved value
is written back so it is inspectable and idempotent.

| `placementState` | How it gets there | Meaning |
|---|---|---|
| *(empty)* | the released default | unresolved — install derives it |
| `node:<name>` | a `tankc` pool was found on `<name>` | PBS software + datastore live on that node's Proxmox OS (not a VM) |
| `shim` | no `tankc` anywhere | marker only, no datastore. Still satisfies `dependsOn: backup:vm`, so dependents install and their `backup:vm` install/update/test **skip gracefully**. Promoted in place later |
| `external` | forced at install, with a `pbsUrl` | a PBS this site does **not** provision is consumed by URL. **Permanent** |

Two operator inputs shape resolution, both on `backup.json`:

- **`.node`** *(optional)* — restrict `tankc` discovery to one named node.
  Empty (the default) searches every node.
- **`.pbsUrl`** — the PBS clients push to. Defaults to `backup.mgmt.internal`.

```bash
backup-manager placement           # state, kind, node, pbsUrl (--json for machine)
backup-manager peers               # off-site peers (pull/receive/push)
backup-manager validate            # loud about a shim or an unresolved state
update-module.sh backup            # re-derives empty/shim → promotes in place
```

**Forcing `external`** needs no special flag — install-module stages the fields:

```bash
install-module.sh backup --force --placementState external --pbsUrl pbs.lan.example
backup-manage.sh use-external pbs.lan.example [--datastore <ds>]   # friendlier
```

`use-external` registers that PBS as the module's backup storage (so the
existing job machinery targets it unchanged), verifies it, and only then records
the placement. It **creates no datastore and never touches what is already
stored there** — a site's existing snapshots stay listable and restorable
(#456). It refuses to run from a live `node:<name>`, which would orphan a
datastore full of backups.

**Legacy states migrate in place** on the next `update-module.sh backup`:
`local` → `node:<name>` (the datastore is **not** moved) and `remote-only` →
`external`, seeding `pbsUrl` from the old push target.

### What a module backs up: two capabilities

Backup is **opt-in**. A module declares the kind it wants — or neither, which is
how hardware and test modules stay out of every job:

| Declared | Captures | Notes |
|---|---|---|
| `dependsOn: ["backup:vm"]` | the whole guest, as a PBS snapshot | the general case |
| `integratesWith: ["backup:vm"]` | same | for the foundation VMs that boot **before** the backup server and so cannot depend on it (#501) |
| `dependsOn`/`integratesWith` `["backup:filesystem"]` | named paths **inside** the guest | needs `backup.filesystemPaths`; **NixOS guests only** — the service install fails loudly on any other OS rather than capturing something half-right |
| *neither* | nothing | deliberate |

A file capture runs *inside* the guest (only it can read its own files): a
`proxmox-backup-client` push into `fs/<module>`, on a timer, with a
**write-no-delete** login scoped to that namespace and a client-side encryption
key. Deleting a module keeps its file backups — that is exactly when they matter.

```json
"integratesWith": ["backup:filesystem"],
"backup": { "filesystemPaths": ["/home/tappaas/config"] }
```

### Schedules: the cascade, and the ceiling

`module.backup.schedule` > `environment.backup.schedule` >
`site.backup.defaultSchedule` > `daily`.

Vocabulary: **`daily` | `weekly` | `monthly`**, or a bare **`HH:MM`** (daily at
that time). **Nothing sub-daily** — once a day is the maximum the platform backs
anything up, and a request for anything more frequent is rejected by name rather
than quietly rounded down.

Proxmox schedules a *job*, not a guest, so each distinct frequency gets its own
cluster backup job (a **bucket**). The daily bucket is the pre-existing job,
marker and start time unchanged; `weekly` (`sun 21:00`) and `monthly`
(`*-*-01 21:00`) are created on demand and deleted when they empty. Changing a
module's schedule **moves** it between jobs — never leaves it in two.

```bash
site-manager site modify --backupDefaultSchedule weekly   # the site's base
backup-manager resolve <module>       # effective policy incl. schedule + bucket
backup-manager reconcile [--apply]    # converge memberships + bucket schedules
```

### Encryption keys — the out-of-band copy (§2.5.1)

Backups are encrypted client-side and the keys are escrowed on the mothership —
which is *inside* the system a full-site rebuild recreates, so that cannot be
the only copy:

```bash
backup-manager key list
backup-manager key export /media/usb-stick    # mandatory, store off-site
backup-manager key import /media/usb-stick    # onto a rebuilt mothership, BEFORE restoring
```

Losing every copy of a key makes the backups it encrypted permanently
unreadable. See [backup-recovery-runbook.md](../../../docs/design/backup-recovery-runbook.md).

### Relocating a datastore without losing history

When PBS itself moves (old node → a new `tankc`, or external → a new local PBS),
seed the new datastore by **pulling** from the old one rather than starting
empty:

```bash
backup-manage.sh add-remote old-pbs      # the old PBS as a temporary pull source
#   … let the sync job complete, then verify …
backup-manage.sh use-external <new-url>  # or re-run install to resolve node:<new>
#   … confirm a TEST RESTORE from the new target succeeds …
backup-manage.sh remove-remote old-pbs   # only now decommission the old datastore
```

Decommission only once the pull **and a test restore** are green. This is plain
pull replication — there is no special migration path, and nothing is rewritten.

### Off-site symmetry (one PBS is all three)

A PBS is simultaneously a **pull replicator**, a **push receiver**, and a **push
sender** — namespace-partitioned, one prompt-not-store credential model:

| Role | Command | Namespace | Direction |
|------|---------|-----------|-----------|
| pull (Class A) | `backup-manage.sh add-remote <n>` | `remote/<n>` | this PBS pulls a buddy |
| receive (Class B) | `backup-manage.sh add-external <n>` | `external/<n>` | a client pushes in |
| **send (ADR-012 P4)** | `backup-manage.sh add-push <n> [--make-default]` | remote's `external/<us>` | **we push out** (remote-only) |

`add-push` registers the remote PBS as a Proxmox storage `offsite-<n>`; `--make-default`
routes the managed backup job there. We hold **write-no-delete** and the **remote owns
prune/retention/immutability** — a compromise here cannot erase the off-site copy.

> A site with **no local PBS** does not need `add-push`: it sets
> `placementState: external` + `pbsUrl` and its clients push to that PBS
> directly, with the same write-no-delete credential (§1.4).

### Subset + independent retention (off-site ≠ 1:1)

- **Subset (pull):** set `.groupFilter` in `remote-<n>.json` (string or array,
  e.g. `"type:vm"` or `["group:vm/101","group:vm/102"]`) to replicate only part
  of the source.
- **Independent retention:** each `remote-`/`external-<n>.json` carries its own
  `retention` → an admin-owned, namespace-scoped prune-job (destination-owned).

### Immutability (opt-in WORM)

Set `backup.json` `.immutableSnapshots` to take read-only ZFS snapshots of the
datastore that a sync/push credential holder or PBS prune/GC **cannot** rewrite
(only node-local root can). The stronger tier — **S3 Object Lock** — is provided
by an ADR-010 satellite, not this module.

```json
"immutableSnapshots": { "enabled": true, "schedule": "daily", "keep": 30 }
```

### Endpoint-agnostic tooling (P7)

`backup-manager --pbs <host> <verb>` targets a non-local PBS (e.g. a satellite):
the same controller ops drive local or remote PBS.

## Automated Schedule

Configured by `install.sh` (and kept current by `update.sh`). All times are
daily and ordered so each step runs against a settled datastore:

| Time  | Job          | Purpose                                                  |
|-------|--------------|----------------------------------------------------------|
| 21:00 | Backup       | Snapshot the managed VM list to the PBS datastore        |
| 02:00 | Prune        | Apply the retention policy (mark old snapshots removable) |
| 03:00 | GC           | Garbage-collect unreferenced chunks, free disk           |
| 04:00 | Verify       | Integrity-check backups (re-verify if older than 30 days) |

## Data Integrity / Bit-rot Protection

The datastore lives on a ZFS pool, so silent bit-rot is a real risk. Two
safeguards run automatically (issue #228):

- **verify-job** `verify-<datastore>` — daily at 04:00 (after GC). Uses
  `--ignore-verified true --outdated-after 30`, so each backup is re-verified
  at least every 30 days; load is spread across the month rather than
  re-scanning the whole datastore every night.
- **verify-new** — every backup is verified as soon as it arrives.

```bash
# Inspect / trigger from the PBS node
ssh root@backup.mgmt.internal "proxmox-backup-manager verify-job list"
ssh root@backup.mgmt.internal "proxmox-backup-manager datastore show tappaas_backup"
./backup-manage.sh verify <backup-id>   # ad-hoc verification of one backup
```

On an already-running PBS server, re-running the backup module's `update.sh`
retrofits both the verify configuration and the ZFS-mount ordering (issue #230)
without a reinstall.

## Emergency Contacts

For critical backup failures:
1. Check PBS GUI dashboard
2. Review system logs on PBS node
3. Verify network connectivity between nodes
4. Ensure adequate disk space on backup storage

## Best Practices

- Monitor backup job completion daily
- Test restore procedures monthly
- Keep PBS node updated
- Maintain off-site backup copy
- Document any configuration changes
