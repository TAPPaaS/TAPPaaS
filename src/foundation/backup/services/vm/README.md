# backup:vm service

Enrols a module's guest in the managed **Proxmox Backup Server** job — a
whole-guest snapshot — and resolves its retention and schedule from the site →
environment → module cascade. Nothing here can make a running guest unhealthy:
every change governs *future* backups, and already written snapshots are
untouched.

The broader half of the backup pair. Its sibling
[`backup:filesystem`](../filesystem/README.md) captures named paths *inside* a
guest instead; `backup:vm` is the safe general answer, and most modules want it.

7 fields — all `in-place`, all `apply: "reconcile"`.

A set operation over a backup job's vmid list, plus a retention and schedule
cascade resolved *above* the module.
*See [recommendation 2](../../../tappaas-cicd/UPDATE-POLICY.md#2-split-backupvm--scalars-out-cascade-in).*

## Two ways to opt in — and opting out is a real choice

Backup is opt-in. A module joins a job by declaring the capability, and a module
that declares neither relationship is in no job at all — which is what hardware
and test modules should do, deliberately:

- **`dependsOn: ["backup:vm"]`** — the normal case, a hard dependency with
  install ordering.
- **`integratesWith: ["backup:vm"]`** — for a module that comes up *before* the
  backup server can exist and therefore cannot depend on it (#501): the
  foundation VMs whose state is not reproducible from git. Same wiring, no
  ordering constraint.

Membership is the union of the two, and the backup module's own update
reconciles it — so a module that declared the integration before there was a
backup server is picked up once there is one.

## One job per schedule, not one job

Proxmox schedules a *job*, not a guest, so a per-module schedule only means
something if a job carries it. Each distinct resolved frequency gets its own
marker-tagged cluster job — a **bucket** (ADR-012 §3.2): `daily` (the original
job, unchanged), `weekly`, `monthly`. Changing a module's schedule **moves** its
guest between buckets rather than adding a second membership, which would back it
up twice wherever the two cadences coincide.

The cascade resolves `module.backup.schedule` > `environment.backup.schedule` >
`site.backup.defaultSchedule` > `daily`, and **rejects anything sub-daily by
name** rather than rounding it down — once a day is the maximum the platform
backs anything up.

## Why every change is `in-place`

None of these can make a running guest unhealthy. Changing retention or schedule
governs **future** backups; already-written snapshots are untouched, and a
shortened retention prunes on the next PBS GC, not on the converge. The riskiest
field is `backup.enabled` going false — the guest keeps running and simply stops
being protected, which is a policy decision, not a disruption.

`placementState` is the odd one out: it is not an input at all. It is the
*resolved* answer to where PBS lives, written back onto the deployed config by
the backup module's own install (ADR-012 §2.1) — a report, not a setting. Two
fields here are on their way out: `alwaysBackup` is superseded by
`integratesWith` and `pushTarget` by `placementState: external` + `pbsUrl`; both
are read for one release. Recommendation 2 proposes splitting the plain scalars
out to `set` and leaving only the cascade on `reconcile`.

<!-- BEGIN GENERATED FIELDS -- edit the manifest, not this block -->

## Fields

`backup:vm` owns **7** declared field(s). Each table below carries the field's full definition and, where the service applies it, its ADR-020 change semantics.

### `alwaysBackup`

DEPRECATED (ADR-012 §2.7) — being replaced by 'integratesWith: ["backup:vm"]' on the foundation modules that bootstrap before the backup server. Read for one release, then the field and its code path are removed; backup stays opt-in. Set only on the backup module. List of module names whose VMs are always added to the PBS backup job, even though they do not (and cannot) declare dependsOn backup:vm — typically foundation VMs that bootstrap before the backup server (firewall, tappaas-cicd).

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

Backup module, optional WORM-ish immutability (ADR-012 §3.5 / ADR-010 §7.3). When enabled, periodic read-only ZFS snapshots of the datastore dataset are taken on the PBS node and pruned to `keep`, so backup history cannot be rewritten by a sync/push credential holder or PBS prune/GC — only by node-local root. The weaker of the two tiers; S3 Object Lock (ADR-010 satellite) is the stronger one and is provisioned satellite-side.

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

### `placementState`

Resolved backup placement (ADR-012 §2.1) and the single source of truth for where PBS lives. Ships EMPTY on the released module; backup/install.sh resolves it once and writes it back. Values: 'node:<name>' (PBS software + datastore realized on that node's tankc pool), 'shim' (no datastore anywhere — still satisfies dependsOn:backup:vm, promoted in place by `module-manager module modify backup` once storage appears), 'external' (an externally-managed PBS at .pbsUrl is consumed; nothing is provisioned — set at install time and permanent thereafter). The legacy values 'local' and 'remote-only' are accepted for one release and migrated in place by update.sh to 'node:<name>' / 'external' (§4.1).

| Attribute | Value |
|---|---|
| Type | `string` |
| Pattern | `^$|^(shim|external|node:.+|local|remote-only)$` |
| Example | `node:tappaas3` |
| Required by | *(none)* |
| Used by | `backup:vm` |
| Change class | `in-place` |
| Apply mode | `reconcile` |

**About the field.** Set only on the backup module, at install/update time — never hand-authored. The resolved NODE is carried by this state; .node is only the discovery constraint.

**Why this change class.** Where the site's backups actually live. Resolved by install; forcing 'external' is an install-time action (`module-manager module add backup --placementState external --pbsUrl <url>`).

### `pushTarget`

DEPRECATED (ADR-012 v0.3) — subsumed by placementState:'external' + pbsUrl, which name the external PBS clients push to directly. Read for one release (update.sh seeds pbsUrl from this target's remoteHost when migrating a legacy remote-only install), then removed. Backup module, remote-only placement only (ADR-012 P4). Name of the default off-site push target — a config/push-<name>.json describing a REMOTE PBS this cluster pushes its VM backups to when there is no local PBS. Empty/absent means no default; onboard with `backup-manager peer add push <name> …`.

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

### `pbsUrl`

The PBS that backup clients push their snapshots to (ADR-012 §1.4/§2.1). Defaults to the local PBS DNS name; overridden to the externally-managed PBS's URL (a satellite's tunnel address, a public host, or a pre-existing LAN PBS) when placementState is 'external'. The credential for it is prompted at onboarding and never stored here.

| Attribute | Value |
|---|---|
| Type | `string` |
| Default | `backup.mgmt.internal` |
| Example | `pbs.offsite.example` |
| Required by | *(none)* |
| Used by | `backup:vm` |
| Change class | `in-place` |
| Apply mode | `reconcile` |

**About the field.** Set only on the backup module. Required (non-default) when placementState is 'external'.

**Why this change class.** Which PBS the clients upload to. Changing it re-points future backups; nothing already stored moves.

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

**Why this change class.** The module's layer of the retention/exclude/enabled/schedule cascade. Changing it changes future backups only; nothing already stored is touched, and no guest is disturbed. A changed schedule MOVES the guest between bucket jobs (ADR-012 §3.2).

<!-- END GENERATED FIELDS -->
