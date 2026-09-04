# backup:vm service

Enrols a module's guest in the shared **Proxmox Backup Server** job and resolves
its retention from the site → environment → module cascade. Nothing here can make
a running guest unhealthy: every change governs *future* backups, and already
written snapshots are untouched.

7 fields — all `in-place`, all `apply: "reconcile"`.

A set operation over the shared PBS job's vmid list, plus a retention cascade
resolved *above* the module.
*See [recommendation 2](../../../tappaas-cicd/UPDATE-POLICY.md#2-split-backupvm--scalars-out-cascade-in).*

## Why every change is `in-place`

None of these can make a running guest unhealthy. Changing retention or placement
governs **future** backups; already-written snapshots are untouched, and a
shortened retention prunes on the next PBS GC, not on the converge. The riskiest
field is `backup` itself going false — the guest keeps running and simply stops
being protected, which is a policy decision, not a disruption.

`placementState` is the odd one: it is the *resolved outcome* of `placement`
written back onto the deployed config, so it is more a report than an input.
Recommendation 2 proposes splitting the plain scalars out to `set` and leaving
only the cascade on `reconcile`.

<!-- BEGIN GENERATED FIELDS -- edit the manifest, not this block -->

## Fields

`backup:vm` owns **7** declared field(s). Each table below carries the field's full definition and, where the service applies it, its ADR-020 change semantics.

### `backup`

Module-level backup policy (ADR-007 P9). The leaf of the Site -> Environment -> Module backup cascade: backup-manager resolves the effective policy by merging site.json backup.defaultRetention, the environment's backup.retention/residency, then these module overrides. install-module.sh persists the resolved policy onto the deployed module config. Does NOT replace the dependsOn backup:vm wiring (which decides whether the VM is in the shared PBS job) — it records the resolved retention/exclude/enabled state.

| Attribute | Value |
|---|---|
| Type | `object` |
| Example | `{"enabled": true, "retention": "1y", "exclude": ["/var/cache"]}` |
| Required by | *(none)* |
| Used by | `backup:vm` |
| Change class | `in-place` |
| Apply mode | `reconcile` |

**About the field.** Authored optionally in the source module JSON; the resolved (cascaded) value is written back into /home/tappaas/config/<name>.json at install time.

**Why this change class.** The module's layer of the retention/exclude/enabled cascade. Changing it changes future backups only; nothing already stored is touched, and no guest is disturbed.

### `alwaysBackup`

Set only on the backup module. List of module names whose VMs are always added to the PBS backup job, even though they do not (and cannot) declare dependsOn backup:vm — typically foundation VMs that bootstrap before the backup server (firewall, tappaas-cicd).

| Attribute | Value |
|---|---|
| Type | `array` |
| Default | *(none)* |
| Example | `firewall`, `tappaas-cicd` |
| Required by | *(none)* |
| Used by | `backup:vm` |
| Change class | `in-place` |
| Apply mode | `reconcile` |

**About the field.** Each entry is a module/VM name resolved to its VMID via /home/tappaas/config/<name>.json. Registered when the backup module installs/updates.

**Why this change class.** Set only on the backup module itself: the modules whose VMs are always in the job even though they cannot declare dependsOn backup:vm (the foundation VMs that bootstrap before the backup server).

### `pbsStorageName`

Name of the Proxmox Backup Server datastore / Proxmox storage used for backups. Set on the backup module; read by backup:vm scripts (install/test/restore/backup-manage).

| Attribute | Value |
|---|---|
| Type | `string` |
| Default | `tappaas_backup` |
| Example | `tappaas_backup` |
| Required by | *(none)* |
| Used by | `backup:vm` |
| Change class | `in-place` |
| Apply mode | `reconcile` |

**About the field.** Allows environments whose PBS storage uses a different name (e.g. 'pbs') to override the default. Used as both the PBS datastore name and the Proxmox storage name.

**Why this change class.** Which PBS datastore the job writes to.

### `immutableSnapshots`

Backup module, optional WORM-ish immutability (ADR-012 §3.5 / ADR-010 §7.3, #389). When enabled, periodic read-only ZFS snapshots of the datastore dataset are taken on the PBS node and pruned to `keep`, so backup history cannot be rewritten by a sync/push credential holder or PBS prune/GC — only by node-local root. The weaker of the two tiers; S3 Object Lock (ADR-010 satellite) is the stronger one and is provisioned satellite-side.

| Attribute | Value |
|---|---|
| Type | `object` |
| Default |  |
| Example | `{"enabled": true, "schedule": "daily", "keep": 30}` |
| Required by | *(none)* |
| Used by | `backup:vm` |
| Change class | `in-place` |
| Apply mode | `reconcile` |

**About the field.** Set only on the backup module. ZFS snapshots protect against credential-holder/prune tampering, not node-root compromise (use S3 Object Lock on a satellite for that).

**Why this change class.** Periodic read-only ZFS snapshots of the datastore so backup history cannot be rewritten (ADR-012 §3.5). Enabling it provisions on the PBS node, not on the consuming guest.

### `placement`

Backup module placement policy (ADR-012). Decides WHERE (or whether) a local PBS datastore is realized. 'auto' discovers a tankc pool (preferred node .node first, then any node) and installs PBS there, falling back to a shim if none exists. 'node:<name>' pins PBS to that node's tankc. 'shim' records a datastore-less marker that still satisfies dependsOn:backup and is promotable later via update-module.sh backup. 'remote-only' installs no local PBS (off-site push, ADR-012 P4). The resolved outcome is written back as .placementState (local|shim|remote-only).

| Attribute | Value |
|---|---|
| Type | `string` |
| Default | `auto` |
| Pattern | `^(auto|shim|remote-only|node:.+)$` |
| Example | `auto` |
| Required by | *(none)* |
| Used by | `backup:vm` |
| Change class | `in-place` |
| Apply mode | `reconcile` |

**About the field.** Set only on the backup module. Replaces the old hard node/storage literals as the source of placement truth; .node/.storage remain the preferred hints for 'auto'.

**Why this change class.** Where the module's backups are allowed to live (auto / a named target).

### `placementState`

Resolved backup placement, written by backup/install.sh|update.sh (ADR-012): 'local' (PBS realized on .node/.storage), 'shim' (no datastore), or 'remote-only'. Runtime state — not authored by hand; read by the shim guards and pbs-job.sh.

| Attribute | Value |
|---|---|
| Type | `string` |
| Allowed values | `local`, `shim`, `remote-only` |
| Example | `local` |
| Required by | *(none)* |
| Used by | `backup:vm` |
| Change class | `in-place` |
| Apply mode | `reconcile` |

**About the field.** Set only on the backup module, at install/update time.

**Why this change class.** The resolved outcome of that placement, recorded on the deployed config.

### `pushTarget`

Backup module, remote-only placement only (ADR-012 P4). Name of the default off-site push target — a config/push-<name>.json describing a REMOTE PBS this cluster pushes its VM backups to when there is no local PBS. Empty/absent means no default; onboard with `backup-manage.sh add-push <name> --make-default`.

| Attribute | Value |
|---|---|
| Type | `string` |
| Default | `` |
| Example | `offsite` |
| Required by | *(none)* |
| Used by | `backup:vm` |
| Change class | `in-place` |
| Apply mode | `reconcile` |

**About the field.** Set only on the backup module. The push credential is prompted at onboarding, never stored.

**Why this change class.** An off-site datastore this module's backups are pushed to (ADR-010).

<!-- END GENERATED FIELDS -->
