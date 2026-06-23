# backup-manager

Owns the **backup hierarchy**: the Site → Environment → Module backup-policy
cascade. It is a *manager* — it owns configuration state (backup policy resolved
from `site.json`, `environments/*.json`, and per-module JSON) and orchestrates
the `backup-controller` for live PBS operations. It does **not** talk to PBS
directly.

## What it owns

The **effective backup policy** for any module, derived by merging three layers
(most specific wins):

| Field       | Source (in precedence order)                                              |
|-------------|---------------------------------------------------------------------------|
| `retention` | module `.backup.retention` → environment `.backup.retention` → site `.backup.defaultRetention` → `7y` |
| `residency` | environment `.backup.residency` → environment `.dataResidency` → `eu-only` |
| `enabled`   | module `.backup.enabled` (default `true`)                                 |
| `exclude`   | module `.backup.exclude` (default `[]`)                                   |
| `schedule`  | environment `.backup.schedule` → `null` (inherit the site PBS job)        |
| `target`    | site `.backup.target`                                                     |
| `offsite`   | site `.backup.offsite`                                                    |

The shared PBS backup job itself is still driven by `dependsOn: ["backup:vm"]`
(the foundation `backup` module / `pbs-job.sh`) — this manager **records** the
resolved policy onto the deployed module JSON; it does not re-wire the job.

## Commands

```
backup-manager resolve <module> [--environment <env>] [--config-dir DIR]
        Print the effective backup policy as JSON (the cascade result).

backup-manager status [--config-dir DIR]
        Effective policy for every deployed module (table; --json on
        backup-status.sh for machine output).

backup-manager restore [args...]
        Restore operations — delegates to backup-restore.sh (which wraps the
        foundation backup/restore.sh and backup-controller).
```

Entry scripts (all linked onto `PATH` by `install.sh`):

| Script               | Verb / purpose |
|----------------------|----------------|
| `backup-manager.sh`  | main entry (`resolve` / `status` / `restore`); `backup-manager` alias |
| `backup-status.sh`   | per-module status; `--json`, `--disabled-only` |
| `backup-restore.sh`  | restore wrapper over the foundation `restore.sh` + controller |
| `validate-backup.sh` | domain validation (also the `validate` verb via `validate.sh`) |
| `lib-cascade.sh`     | sourced cascade resolver (`bc_resolve`, `bc_list_modules`) — not linked |

## Controllers it calls

- [`backup-controller`](../../controller/backup-controller/) — PBS job status,
  snapshot listing, verify, namespaces (reuses the foundation PBS libs).
- The foundation [`backup/restore.sh`](../../../backup/restore.sh) for the actual
  VM restore.

## Validation (`validate` verb)

`validate-backup.sh` checks the hierarchy is consistent and exits non-zero on
any inconsistency: retention strings parse (`^[0-9]+[dwmy]$`), residency is a
valid enum, an `eu-only` environment is not targeted at a non-EU offsite
(`site.backup.offsiteResidency`), module `backup.enabled:false` is honoured, and
there is no dangling target (enabled in-job modules require `site.backup.target`).

## Testing

`test.sh` is fast + offline (fixtures, never the live config or PBS): cascade
resolution at each layer, the `7y → 5y → 1y` override demo, `enabled:false`
disabling, `status` listing, and the validator's accept/reject cases.
