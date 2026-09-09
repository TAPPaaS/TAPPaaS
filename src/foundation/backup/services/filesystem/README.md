# backup:filesystem service

Captures **named paths inside** a module's guest, rather than the whole guest.
The narrower half of the backup pair: `backup:vm` snapshots a guest from the
outside and needs nothing within it, while this service backs up a *subset* of
what lives inside — which only the guest itself can read.

1 field — `in-place`, `apply: "reconcile"`.

The one service that runs code **inside** a workload, because file selection is
not something the hypervisor can do on the guest's behalf.

## What a module gets

Declaring the capability and naming the paths is the whole interface:

```jsonc
"dependsOn": ["backup:filesystem"],        // or integratesWith, see below
"backup": {
  "filesystemPaths": ["/home/tappaas/config"],
  "schedule": "daily"                      // optional; inherits the cascade
}
```

The service then provisions the PBS side (a namespace `fs/<module>` and a login
scoped to it), generates a client-side encryption key, escrows it centrally, and
deploys a small runner plus a capture manifest into the guest. A systemd timer
in the guest's own configuration triggers it — captures run from inside, on the
guest's schedule, and do not depend on the mothership being reachable.

Use `integratesWith` instead of `dependsOn` when the module boots *before* the
backup server can exist (#501). The mothership does exactly this to capture
`config/`.

## When to choose it over `backup:vm`

`backup:vm` is the safe general answer and most modules should take it. Reach for
a file capture when:

- **the restore you actually want is a few files**, not a machine — a file
  restore lands in seconds into a running system, where a VM restore gives you a
  whole second guest to reconcile;
- **the data must be restorable somewhere else** — a `.pxar` archive can be
  unpacked onto a *different* host, which a guest snapshot cannot. This is why
  the mothership's `config/` is captured this way: full-site recovery needs it
  back **before** there is a VM to restore it into;
- **the guest is large and the interesting state is small.**

The two are not exclusive. `tappaas-cicd` declares both: the VM snapshot restores
the machine, the file capture restores the state it is rebuilt from.

## Why it fails loudly

Two deliberate hard failures, both preferring "no backup" to "a backup you cannot
trust":

- **Unsupported guest OS.** Selecting and restoring named paths reliably needs
  TAPPaaS to know the guest's layout, so the service install *fails* on any
  `ostype` outside the supported set (NixOS today) instead of capturing something
  half-right. Use `backup:vm` there.
- **A declared path that does not exist.** The capture aborts rather than
  skipping it. A path that silently stopped being captured — renamed, moved,
  never created — is precisely the failure that stays invisible until a restore.

## What deleting the module does *not* delete

`delete-service.sh` removes the capture manifest, the runner and the guest's
write credential. It leaves the `fs/<module>` namespace, every snapshot in it and
the escrowed encryption key. Removing a module is exactly when its backups
matter, so reclaiming that space stays a separate, deliberate act.

## Credentials and the key

The guest holds a `<module>-fs@pbs` login with `DatastoreBackup` on its own
namespace **only** — write, no delete, and nothing outside `fs/<module>`. A
compromised guest can add snapshots of its own files; it cannot erase its history
or touch another module's (proven live: `snapshot forget` is refused with
`missing Datastore.Modify|Datastore.Prune`).

Backups are encrypted with a key the guest holds and `tappaas-cicd` escrows. That
escrow is inside the system a full-site rebuild recreates, so it must not be the
only copy — take the out-of-band one with `backup-manager key export <dest>`
(ADR-012 §2.5.1). Without a key, its backups are unreadable by anyone, including
you.

## See also

- [backup module README](../../README.md) · [DESIGN](../../DESIGN.md) ·
  [RESTORE](../../RESTORE.md) — recovery
- [RESTORE.md](../../RESTORE.md) — the rehearsed restore, including `config/`
- [ADR-012 §3.1](../../../../../docs/ADR/ADR-012-backup-enhancement.md) — why the
  backup kind is a capability you depend on, not a `type` field

<!-- BEGIN GENERATED FIELDS -- edit the manifest, not this block -->

## Fields

`backup:filesystem` owns **1** declared field(s). Each table below carries the field's full definition and, where the service applies it, its ADR-020 change semantics.

### `backup`

Module-level backup policy (ADR-007 P9). The leaf of the Site -> Environment -> Module backup cascade: backup-manager resolves the effective policy by merging site.json backup.defaultRetention, the environment's backup.retention/residency, then these module overrides. `module-manager module add` persists the resolved policy onto the deployed module config. Does NOT replace the dependsOn backup:vm wiring (which decides whether the VM is in the shared PBS job) — it records the resolved retention/exclude/enabled state.

| Attribute | Value |
|---|---|
| Type | `object` |
| Example | `{"enabled": true, "retention": "1y", "schedule": "weekly", "exclude": ["/var/cache"], "filesystemPaths": ["/home/tappaas/config"]}` |
| Required by | *(none)* |
| Used by | `backup:vm`, `backup:filesystem` |
| Change class | `in-place` |
| Apply mode | `reconcile` |

**About the field.** Authored optionally on any module, alongside the dependsOn/integratesWith relationship that opts it into backup. The resolved (cascaded) value is written back into /home/tappaas/config/<name>.json at install time. filesystemPaths is meaningful only for a module declaring backup:filesystem; the other sub-fields apply to both capabilities.

**Why this change class.** Which paths inside the guest are captured, and how often. Applied by re-writing the capture manifest and re-asserting the namespace/ACL — future captures change, nothing already stored is touched, and the guest keeps running.

<!-- END GENERATED FIELDS -->
