# backup — Installation

Primary audience: TAPPaaS admin.

Backup is a foundation module: in a normal install it is **installed automatically by
`rest-of-foundation.sh`** (first, in the order backup → identity → logging). The steps
below also work stand-alone.

## Prerequisites

1. A node with a `tankc` ZFS pool for the datastore. If none exists yet you can still
   install: `auto` placement records a **shim** (no datastore) that satisfies
   `dependsOn: backup` for other modules; promote it later (see Post-install).
2. Unattended runs: export `TAPPAAS_PBS_PASSWORD` to set the `tappaas@pbs` password.
   With a TTY you are prompted instead; with neither, a strong password is generated and
   saved to `~/.pbs-credentials.txt` (mode 600). Minimum 8 characters.

> To deviate from the defaults in `./backup.json` (target node, storage, zone,
> `placement` policy `auto` | `node:<name>` | `shim` | `remote-only`, `pbsStorageName`,
> `alwaysBackup` list, `immutableSnapshots`), copy the json to `/home/tappaas/config`
> and edit it before installing.

## Install

    install-module.sh backup

(Run from the module directory, or let `rest-of-foundation.sh` drive it.) The install:

1. Resolves placement (ADR-012): discovers a `tankc` pool (preferred node first), or
   records a `shim` / `remote-only` state and stops there.
2. Installs `proxmox-backup-server` + `proxmox-backup-client` via apt on the chosen
   node, and reconciles `proxmox-backup-client` onto **all** current PVE nodes.
3. Orders the PBS services after `zfs-mount.service` so the chunk store waits for the
   datastore mount on boot (issue #230).
4. Adds a DNS entry for `backup.mgmt.internal`, creates the datastore
   (default `tappaas_backup`; re-attaches an existing chunk store on reinstall), the
   `tappaas@pbs` user and its ACL.
5. Configures the retention prune-job (02:00), GC (03:00), verification (verify-new +
   daily verify-job 04:00), and the `remote/` + `external/` namespaces.
6. Registers the PBS datastore as Proxmox storage on the cluster and registers the
   `alwaysBackup` VMs in the managed backup job. (No `--all` job is created — modules
   opt in via `backup:vm`, issue #200.)

## Post-install

None for a normal local install. Optional follow-ups:

- **Promote a shim** once a `tankc` pool exists: `update-module.sh backup` (idempotent).
- **remote-only sites:** onboard the off-site push target (prompts for the remote
  credential): `backup-manage.sh add-push <name> --make-default`.
- **Off-site / multi-source setup** (buddy pull, external clients): see
  [QUICKREF.md](./QUICKREF.md).
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
in [QUICKREF.md](./QUICKREF.md).
