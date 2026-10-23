# storage-manager

The control plane for TAPPaaS storage
([ADR-029](../../../../../docs/ADR/ADR-029%20-%20NFS%20Service.md) v0.9, D17). It
owns `config/shares.json` — the Site's NFS shares — and is the only thing that
writes it. Every verb that changes a share validates the whole document, writes
it atomically under a lock, and converges at once: the share's server builds it
(through its module's NFS hook) and the share alias follows.

## Verbs

```
storage-manager validate
storage-manager inventory [--json] [--node <n>] [--no-smart]   # the site's disks, pools and volumes
storage-manager nfs show [<share>] [--server <instance>] [--json]
storage-manager nfs share add <name> --server <instance> --pool <pool> [--quota Q] --backup true|false
                              [--backup-exclude L] [--prop K=V]...           # a cluster node
storage-manager nfs share add <name> --server <instance> --path <p> [--version V] [--v3-ports L]
                                                                              # a registered, unmanaged NAS
storage-manager nfs share modify <name> --set quota=Q|backup.enabled=B|backup.exclude=L|properties.K=V ...
storage-manager nfs share delete <name>                    # unshare; the data is kept
storage-manager nfs share purge <name> --server <instance> --yes   # destroy an orphan's data
storage-manager nfs grant <share> <consumer> ro|rw
storage-manager nfs revoke <share> <consumer>
storage-manager nfs converge [<share> [--notify] | --server <instance>]
```

Every changing verb takes `--check`: show the result, change nothing.

| Verb | Converges | Refuses |
|---|---|---|
| `share add` | the server builds the share; alias created; owner uid allocated (64000–64999) | a name in use, a server that cannot serve, a missing `--backup` |
| `share modify` | the server re-quotas / re-sets properties | `server`, `pool`, `owner`, rename — data migrations |
| `share delete` | unshared, alias dropped | while any consumer mounts it |
| `share purge` | the hook destroys the dataset (expiring nfsd clients no export lists any more, then retrying for 2 minutes); the last share on a pool takes `<pool>/tappaas-nfs` with it | while the share is still declared, without `--yes` |
| `grant` | re-shared to the consumer; the consumer's `storage:nfs` update runs (mount or migration, with its consent) | an undeclared share |
| `revoke` | unshared from the consumer | while the consumer mounts it |
| `converge` | without arguments, the whole Site (what `storage` `update.sh` runs) | — |

Changing a share's server or pool (a move) is not a verb yet: send the dataset,
edit `config/shares.json`, then `storage-manager nfs converge <share>`.

## Inventory

`storage-manager inventory` reads the site's storage live and prints it; it
changes nothing and stores nothing. Per cluster node (the `pvehost` instances, `site-manager node list`):

- **boot** — the disk that holds `/` and the EFI partition: model, serial, size,
  type, life left, temperature, SMART health;
- **pools** — every ZFS pool on the node and every pool its record declares
  (`storagePools`) (a declared pool that is not imported is listed, and fails): size, how much
  is used and free, fragmentation, compression, health, the last scrub;
  - its **vdevs** (mirror, raidz, stripe) and under them the **physical disks**,
    with SMART (health, temperature, reallocated, pending and uncorrectable
    sectors, NVMe media errors) and ZFS's own view of each (state, read, write
    and checksum errors);
  - what it **holds**: each guest volume — the module behind it, its size and what
    it takes from the pool, and whether it is the guest's **own** disk, the HA
    **mirror** copy of a guest that runs on another node, a **template**, or an
    **orphan** (no guest, or a copy no replication job keeps) — then the PBS
    datastore, the NFS shares and other datasets;
  - the **totals** a pie is drawn from: own + mirror copies + other + free = the
    pool's usable size;
- **disks in no pool** — named, with the pool on them that is not imported if
  there is one;
- **replication** — the jobs that copy this node's HA guests to their other node:
  schedule, last sync, failures.

The text shows one block per node, pools and disks indented, the state at the
end of each line; `--json` prints the document (what the console draws), with a
`findings` list naming each problem's node and disk, pool or job. SMART takes
about a second per disk: `--no-smart` skips it (the document says
`"smart": false`). Expect a few seconds per node. Sizes are binary (GiB, TiB);
the JSON gives bytes.

### What the states mean

| State | Disk | Pool | Replication job |
|---|---|---|---|
| **fail** | SMART health FAILED; ZFS has the disk DEGRADED, FAULTED, UNAVAIL or REMOVED (too many errors); 10% or less of its rated life left | FAULTED, UNAVAIL or SUSPENDED; declared but not imported; 90% used or more | — |
| **warn** | reallocated, pending or uncorrectable sectors; NVMe media errors or a critical warning; ZFS read, write or checksum errors; 20% or less life left; 60°C or more (70°C for NVMe) | DEGRADED or another state than ONLINE; 80% used or more; a disk in it not ok; the last scrub found errors or is over 40 days old; not declared in `site.json` | in error or failed attempts; never synced; the last sync more than twice its interval ago |
| **ok** | none of these | none of these | none of these |

A node is the worst of its boot device, pools, other disks and jobs. A disk
whose SMART still says PASSED can be failing: ZFS's verdict and the sector
counts are what tell.

### Where each number comes from

| Number | Source (on the node) |
|---|---|
| disks, model, serial, type, life left | `pvesh get /nodes/<n>/disks/list` (wearout is Proxmox's: % of rated life left) |
| SMART attributes, temperature | `pvesh get /nodes/<n>/disks/smart --disk <dev>` |
| pool size, allocated, free, fragmentation, dedup, health | `zpool list -Hp` |
| vdevs, member disks, their state and error counts, scrub | `zpool status -P -p` (exact counts; the pvesh view rounds them) |
| used, free, % used, volumes, datasets, compression | `zfs list -Hp` (the pool's top dataset: used of used + available — the numbers Proxmox and the `storage-pools` health gate count) |
| boot device | `lsblk` (the disk under `/` and `/boot/efi`) |
| a mirror copy's last sync | the copy's `__replicate_<job>_<time>__` snapshot |
| replication jobs and state | `pvesh get /cluster/replication`, `pvesh get /nodes/<n>/replication` |
| disks in a pool not imported | `zpool import` (lists, imports nothing) |
| PBS datastore | `proxmox-backup-manager datastore list`; when it is a directory in a dataset, its size is that dataset's own data (`≈` in the text) |
| guest → node, module | `pvesh get /cluster/resources`, `module-manager list` |
| NFS share datasets | `config/shares.json` (`<pool>/tappaas-nfs/<share>`) |

What a volume *takes* includes its snapshots and, for a thick disk, its
reservation; its size is what the guest sees. Not read: SMART self-test logs,
per-disk I/O load, and a datastore directory's exact size (it would need a walk of
the whole store).

## Files

| Path | Role |
|---|---|
| `src/main.ts` | CLI: argument parsing, `change()` = lock → verb → validate → write → converge |
| `src/verbs.ts` | each verb as a pure function over the document — what the unit tests pin |
| `src/store.ts` | `config/shares.json` on disk: atomic write, directory lock, instance lookups |
| `src/inventory.ts` | `inventory`: the parsers, `buildInventory` (pure: the join and the states), `collectSources` (the reads), the text view |
| `../../lib/ts/src/cluster.ts` | `queryNodeStorage` (one ssh probe per node), `queryClusterReplication`, `queryClusterGuests` |
| `../../lib/ts/src/nfs-shares.ts` | the share model, shared with module-manager's validate |

Converging is delegated to the storage module's `lib/nfs-converge.sh`, found
through `config/storage.json`.

## Test

```bash
./test.sh       # unit suite (incl. the inventory over hrossen's captured reads) + the CLI against a temp config dir; never the live Site
```

The end-to-end suite is the storage module's: `src/foundation/storage/test.sh --deep`.
