# storage

Primary audience: TAPPaaS admin.

Storage for consumer modules, decided by
[ADR-029](../../../docs/ADR/ADR-029%20-%20NFS%20Service.md) (v0.9). Today: **NFS
shares** — a library, a media tier, anything a guest should not keep on its own
VM disk.

Like `cluster`, `storage` is a **virtual module**: it is registered
(`config/storage.json`) so that `storage:nfs` resolves, but it installs nothing on
any machine. Three parts do the work:

| Part | What it is | Where |
|---|---|---|
| The shares | Site state in `config/shares.json` — name, server, pool, quota, backup, owner, grants | written only by [`storage-manager`](../tappaas-cicd/manager/storage-manager/README.md) |
| The servers | each server's module ships an NFS hook; a cluster node builds its shares as ZFS datasets shared with `sharenfs` | [`pvehost/storage/nfs-server.sh`](../pvehost/storage/nfs-server.sh) |
| The consumers | a module that depends on `storage:nfs` and lists its `mounts` by share name | [services/nfs](services/nfs/README.md) |

```bash
storage-manager nfs share add media --server tappaas1 --pool tankb1 --quota 4T --backup true
storage-manager nfs grant media jellyfin rw
storage-manager nfs show
```

Every share is reached through its alias `nfs-<share>.mgmt.internal`, which
follows the share's server — a consumer never names a machine.

## What is in this directory

| Path | Role |
|---|---|
| `storage.json` | the registration; provides `nfs` |
| `install.sh` | nothing to install (virtual) |
| `update.sh` | the sweep: every server converges its shares and every alias is checked (`lib/nfs-converge.sh all`) |
| `test.sh` | the unit suite, `storage-manager validate`, the aliases; `--deep` the end-to-end suite |
| `services/nfs/` | `storage:nfs` — consumers' mounts, pending mounts and migration |
| `lib/nfs-lib.sh` | the share model in bash (reads `config/shares.json`) |
| `lib/nfs-converge.sh` | drives server hooks and aliases — the one place storage-manager, the sweep and the service converge through |
| `lib/nfs-guest.sh` | probing and writing mounts in a guest |
| `test-nfsconsumer/` | the disposable consumer the deep suite deploys |

## Not built yet (#772)

Share backup (WP6), registered NAS servers beyond the reference check (WP7), the
storage zone (WP9), LXC consumers (WP10), quota health (WP11), `nfs share move`,
servers other than cluster nodes, storage kinds other than NFS. NFS runs
cleartext on internal VLANs; TLS is deferred (#771).
