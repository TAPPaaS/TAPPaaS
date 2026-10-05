# storage-manager — design

Decided by [ADR-029](../../../../../docs/ADR/ADR-029%20-%20NFS%20Service.md) v0.9
(D1, D17–D19). This page is how the code realises it.

## One writer, one file

`config/shares.json` is Site state, like `zones.json`: never part of a module's
release merge, written by nothing but this manager. `Store` (`src/store.ts`) is
the only code that touches it:

- **lock** — a directory lock `config/.shares.lock` (atomic `mkdir`); a lock older
  than 10 minutes is a crashed run's and is broken; a waiter gives up after 60 s.
- **write** — temp file + `rename`, so a reader never sees half a document.
- **absent = empty** — a Site with no shares has no file.

## A verb is a pure function

`src/verbs.ts` maps (document, arguments) → new document or a refusal, with no
I/O: everything a verb refuses, and why, is pinned by the unit tests. `main.ts`
wraps each changing verb in `change()`:

```
lock → verb(doc) → checkShares(whole new doc) → write → converge → unlock
```

A refusal or a validation finding changes nothing. `--check` stops before the
write and prints the result.

The share model — names, owner range, property whitelist, `checkShares`,
`checkMounts` — lives in `lib/ts/src/nfs-shares.ts`, shared with module-manager's
`validate`, so a consumer's mounts and the shares are judged by one set of rules.

## Converging is the storage module's

The manager does not reach nodes or the firewall itself. After a write it runs
the storage module's `lib/nfs-converge.sh` (found through `config/storage.json`'s
`moduleSource`), which:

1. picks the share's server and its kind — a managed instance whose module ships
   `storage/nfs-server.sh` (hook), a registered unmanaged server (nothing to
   build), or neither (refused);
2. runs the hook's `converge <instance>` — the hook builds every share declared
   for that instance and unshares what is no longer declared (data kept);
3. points `nfs-<share>.mgmt.internal` at the server through `dns-manager`;
4. with `--notify` (after `share add` and `grant`), runs the `storage:nfs` update
   of each deployed consumer that mounts the share — a pending mount migrates now,
   with the consumer's consent.

The same script is what the `storage` module's `update.sh` (the sweep) and the
`storage:nfs` service call, so there is one converge path, not three.

## Owner allocation

`share add` allocates the owner uid/gid (64000–64999, the lowest free) into the
declaration itself. Servers never write back: the document is complete the
moment it is written, and a share keeps its owner across a move.

## What is deliberately not here

- **`share move`** — a change of `server` or `pool` is a data migration; refused by
  `modify`, done by hand until a verb exists (ADR-029 D17).
- **Server code** — how a share is built is the server module's hook; the manager
  only says *what*. That is what lets a non-PVE server join later.
