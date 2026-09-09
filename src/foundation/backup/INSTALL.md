# backup — Installation

Primary audience: TAPPaaS admin.

Backup is a foundation module: in a normal install it is **installed automatically by
`rest-of-foundation.sh`** (first, in the order backup → identity → logging). The steps
below also work stand-alone.

## Prerequisites

1. A node with a `tankc` ZFS pool for the datastore — discovery searches every node
   unless `backup.json` `.node` names one. If no such pool exists yet you can still
   install: the module records a **shim** (no datastore) that satisfies
   `dependsOn: backup` for other modules; promote it later (see Post-install).
   A site that already runs its own PBS skips all of this and consumes it by URL
   (see Post-install, "adopt an existing PBS").
2. Unattended runs: export `TAPPAAS_PBS_PASSWORD` to set the `tappaas@pbs` password.
   With a TTY you are prompted instead; with neither, a strong password is generated and
   saved to `~/.pbs-credentials.txt` (mode 600). Minimum 8 characters.

> To deviate from the defaults in `./backup.json` (`.node` to pin discovery to one
> node, `.storage`, zone, `pbsStorageName`, `pbsUrl`, `immutableSnapshots`), copy the
> json to `/home/tappaas/config` and edit it before installing.
>
> There is no `placement` policy field: `placementState` is resolved by the install
> and written back (ADR-012 §2.1). The one placement decision you *make* rather than
> discover is going external, which is an install-time action — see below.

## Install

    install-module.sh backup

(Run from the module directory, or let `rest-of-foundation.sh` drive it.) The install:

1. Resolves `placementState` (ADR-012 §2.2): keeps an already-resolved state, else
   discovers a `tankc` pool (only `.node` if set, else every node) and records
   `node:<name>` — or records a **`shim`** and stops there when there is none.
   An install told to go `external` records that instead and provisions nothing.
2. Installs `proxmox-backup-server` + `proxmox-backup-client` via apt on the chosen
   node, and reconciles `proxmox-backup-client` onto **all** current PVE nodes.
3. Orders the PBS services after `zfs-mount.service` so the chunk store waits for the
   datastore mount on boot (issue #230).
4. Adds a DNS entry for `backup.mgmt.internal`, creates the datastore
   (default `tappaas_backup`; re-attaches an existing chunk store on reinstall), the
   `tappaas@pbs` user and its ACL.
5. Configures the retention prune-job (02:00), GC (03:00), verification (verify-new +
   daily verify-job 04:00), and the `remote/` + `external/` namespaces.
6. Registers the PBS datastore as Proxmox storage on the cluster and reconciles the
   managed backup job so every module that opted in is a member. (No `--all` job is
   created — backup is opt-in: a module joins by declaring `backup:vm` under
   `dependsOn`, or under `integratesWith` if it boots before the backup server
   (#501). Issue #200.)

## Post-install

None for a normal local install. Optional follow-ups:

- **Promote a shim** once a `tankc` pool exists: `update-module.sh backup` (idempotent).
- **Adopt an existing PBS** (on the LAN, at a satellite, or a third party — #456):
  `backup-manage.sh use-external <url> [--datastore <ds>]`. It registers that PBS as
  this module's backup storage, creates no datastore and never touches what is
  already stored there. **Permanent** — it is refused from a live local PBS.
- **Sites with no local PBS:** either the `external` route above (clients push
  straight to that PBS), or a push target: `backup-manage.sh add-push <name>
  --make-default`.
- **File-level capture** for a module that wants named paths rather than the whole
  guest: declare `backup:filesystem` + `backup.filesystemPaths` on it (NixOS guests).
- **Export the encryption key** — mandatory, and easy to postpone until it is too
  late: `backup-manager key export /media/<stick>`. The escrow lives on the
  mothership, so it cannot be the only copy (ADR-012 §2.5.1).
- **Off-site / multi-source setup** (buddy pull, external clients): see
  [RESTORE.md](./RESTORE.md).
- Consider setting up a backup-of-backup to a remote PBS.

## Verification

    test-module.sh backup

Fast tier runs the offline PBS helper unit suites; `TAPPAAS_TEST_DEEP=1` adds a live PBS
reachability check (see [TEST.md](./TEST.md)).

| Check | Expected |
|-------|----------|
| Browse `https://backup.mgmt.internal:8007` | PBS GUI; login as root@pam or tappaas@pbs |
| `./backup-manage.sh status` (from the module dir on cicd) | PBS system overview, datastore visible |
| `ssh root@<node>.mgmt.internal "pvesm status"` | PBS storage (`tappaas_backup`) listed and `active` |
| `backup-manager placement` | placement + state shown (`local` on a normal install) |

## Troubleshooting

**Backups failing**

    ssh root@backup.mgmt.internal "systemctl status proxmox-backup"
    ssh root@backup.mgmt.internal "df -h"
    ssh root@backup.mgmt.internal "journalctl -u proxmox-backup -f"

**"unable to open chunk store" right after a reboot**
The PBS services are ordered `After=/Requires=zfs-mount.service` (issue #230). Confirm
the drop-ins are present, then reload + restart:

    ssh root@backup.mgmt.internal "cat /etc/systemd/system/proxmox-backup-proxy.service.d/zfs-wait.conf"
    ssh root@backup.mgmt.internal "systemctl daemon-reload && systemctl restart proxmox-backup-proxy"

Re-running the module's update (`update-module.sh backup`) re-creates the drop-ins,
retrofits the verify configuration, and heals client coverage on all nodes.

**Full disk**

    ./backup-manage.sh gc          # garbage-collect unreferenced chunks
    ./backup-manage.sh retention   # review the policy
    ./backup-manage.sh prune       # apply it

**Still a shim after install**
No usable `tankc` pool was found (`backup-manager validate` warns loudly). Create the
pool, then `update-module.sh backup` promotes the shim to a real PBS in place.

**Restore issues**
`./restore.sh --vmid <id> --list` to confirm backups exist;
`ssh root@<node>.mgmt.internal "pvesm status"` to check target storage. More scenarios
in [RESTORE.md](./RESTORE.md).
