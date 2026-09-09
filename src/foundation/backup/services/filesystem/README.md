# backup:filesystem service

<!-- Describe what this service provides and how a module uses it. This prose is yours; the generated block below is not. -->

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
