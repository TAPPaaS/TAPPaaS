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
| `share purge` | the hook destroys the dataset (retrying for 2 minutes while nfsd lets go); the last share on a pool takes `<pool>/tappaas-nfs` with it | while the share is still declared, without `--yes` |
| `grant` | re-shared to the consumer; the consumer's `storage:nfs` update runs (mount or migration, with its consent) | an undeclared share |
| `revoke` | unshared from the consumer | while the consumer mounts it |
| `converge` | without arguments, the whole Site (what `storage` `update.sh` runs) | — |

Changing a share's server or pool (a move) is not a verb yet: send the dataset,
edit `config/shares.json`, then `storage-manager nfs converge <share>`.

## Files

| Path | Role |
|---|---|
| `src/main.ts` | CLI: argument parsing, `change()` = lock → verb → validate → write → converge |
| `src/verbs.ts` | each verb as a pure function over the document — what the unit tests pin |
| `src/store.ts` | `config/shares.json` on disk: atomic write, directory lock, instance lookups |
| `../../lib/ts/src/nfs-shares.ts` | the share model, shared with module-manager's validate |

Converging is delegated to the storage module's `lib/nfs-converge.sh`, found
through `config/storage.json`.

## Test

```bash
./test.sh       # unit suite + the CLI against a temp config dir; never the live Site
```

The end-to-end suite is the storage module's: `src/foundation/storage/test.sh --deep`.
