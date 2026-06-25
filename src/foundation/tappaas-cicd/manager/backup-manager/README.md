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

The shared PBS backup job itself is driven by `dependsOn: ["backup:vm"]`. The
manager **owns the `.backup` writes** on the deployed module JSON (`modify` /
`add` / `delete`) and re-wires the *config*; `install-module` still calls
`resolve` to **record** the resolved policy after a deploy (that path is
unchanged — the manager does not duplicate it). The *live* PBS job membership
converges on `reconcile`.

## Verb / controller split (ADR-007 verb-alignment #3)

**The manager resolves the cascade; the controller mutates PBS.** `backup-manager
reconcile` resolves the Site→Environment→Module policy for every deployed module
and calls the controller's mutation verbs (`add-to-job <vmid>`, `apply-schedule
<spec>`) to make PBS match. The manager never talks to PBS directly.

## TypeScript port

A first-pass TypeScript port lives under `src/` (built by `default.nix` via
`tsc`, zero npm deps, ambient `src/env.d.ts` — mirrors `people-manager`). It is
**not yet wired into `install.sh`** (the `.sh` entry points stay live). The TS
`backup-manager` shells out to `backup-controller` via `CliClient`
(`src/client.ts`, parsing `--json` output) — no PBS API is reimplemented.

## Commands (standardized verbs)

```
backup-manager validate [--config-dir DIR]
        Backup hierarchy is well-formed + internally consistent (was validate-backup.sh).

backup-manager list [--disabled-only] [--json] [--config-dir DIR]
        Effective policy for every deployed module (was backup-status).

backup-manager show <module> [--json] [--config-dir DIR]
        One module's effective policy (was backup-status <module>).

backup-manager resolve <module> [--environment <env>] [--config-dir DIR]
        Cascade-resolve + print one module's policy (JSON).

backup-manager modify <module> [--enabled true|false] [--retention SPEC] [--exclude a,b]
        Write the module's .backup {enabled,retention,exclude} onto
        config/<module>.json (ATOMIC). Only the flags given are changed.

backup-manager add <module> | delete <module>
        Wire / un-wire the module into the shared PBS job (adds/removes
        "backup:vm" in .dependsOn). modify-driven .json writes; live membership
        converges on reconcile.

backup-manager reconcile [--apply] [--config-dir DIR]
        Converge resolved policies → PBS (whole-cluster; PREVIEW by default,
        --apply commits). Idempotent. Calls backup-controller add-to-job /
        apply-schedule.

backup-manager restore list <module> | restore <module> [opts] | list-all
        SPECIAL recovery verb — delegates to the foundation backup/restore.sh and
        backup-controller (snapshot listing).
```

Entry scripts (the live bash, all linked onto `PATH` by `install.sh`):

| Script               | Verb / purpose |
|----------------------|----------------|
| `backup-manager.sh`  | main entry (`resolve` / `status` / `restore`); `backup-manager` alias |
| `backup-status.sh`   | per-module status; `--json`, `--disabled-only` |
| `backup-restore.sh`  | restore wrapper over the foundation `restore.sh` + controller |
| `validate-backup.sh` | domain validation (also the `validate` verb via `validate.sh`) |
| `lib-cascade.sh`     | sourced cascade resolver (`bc_resolve`, `bc_list_modules`) — not linked |

> `lib-cascade.sh` is the bash source of truth for the cascade (also reusable by
> the controller); the TypeScript `src/config.ts` re-implements the same
> precedence in lock-step. Keep the two in sync.

## Controllers it calls

- [`backup-controller`](../../controller/backup-controller/) — PBS job status,
  snapshot listing, verify, namespaces (`--json` for machine output), and the
  `reconcile` mutations `add-to-job` / `apply-schedule` (reuses the foundation
  PBS libs).
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

The TypeScript port adds offline unit tests under `test/unit/` (a `FakeClient`
for the controller boundary, fixtures under `test/fixtures/config/`): cascade
resolution, `validate`, `list`/`show`, the `reconcile` plan (idempotent
ensure-job-member + apply-schedule, and the controller-mutation apply path), the
`restore` delegation, and the `modify`/`add`/`delete` atomic `.backup` writes.
Build + run via the `test/unit/tsconfig.json` (`tsc` + `node`).
