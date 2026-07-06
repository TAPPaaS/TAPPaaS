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

## TypeScript implementation

The manager is TypeScript under `src/` (built by `default.nix`, a thin
wrapper over the shared `lib/nix/ts-manager.nix` builder: `tsc`, zero npm deps,
ambient `lib/ts/src/env.d.ts`; shared CLI/help/exec/config-io helpers come from
`lib/ts/src/` — mirrors `site-manager`). `install.sh` builds + links the
`backup-manager` bin; the legacy bash entry scripts (`backup-manager.sh`,
`backup-status.sh`, `backup-restore.sh`, `validate-backup.sh`,
`lib-cascade.sh`) were **retired** in the ADR-007 post-implementation refactor,
Phase 7.4. The TS `backup-manager` shells out to `backup-controller` via
`CliClient` (`src/client.ts`, parsing `--json` output) — no PBS API is
reimplemented.

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

The single entry point is the TS `backup-manager` bin (linked onto `PATH` by
`install.sh`). Legacy-name → verb mapping (Phase 7.4 retirements):

| Retired script       | Replacement |
|----------------------|-------------|
| `backup-manager.sh`  | `backup-manager resolve` / `list` / `restore` |
| `backup-status.sh`   | `backup-manager list [--json] [--disabled-only]` |
| `backup-restore.sh`  | `backup-manager restore list\|restore\|list-all` |
| `validate-backup.sh` | `backup-manager validate` (also via `validate.sh`, P10) |
| `lib-cascade.sh`     | `src/config.ts` `resolvePolicy` (the cascade source of truth) |

## Controllers it calls

- [`backup-controller`](../../controller/backup-controller/) — PBS job status,
  snapshot listing, verify, namespaces (`--json` for machine output), and the
  `reconcile` mutations `add-to-job` / `apply-schedule` (reuses the foundation
  PBS libs).
- The foundation [`backup/restore.sh`](../../../backup/restore.sh) for the actual
  VM restore.

## Validation (`validate` verb)

`backup-manager validate` (`src/validate.ts`) checks the hierarchy is consistent
and exits non-zero on any inconsistency: retention strings parse
(`^[0-9]+[dwmy]$`), residency is a valid enum, an `eu-only` environment is not
targeted at a non-EU offsite (`site.backup.offsiteResidency`), module
`backup.enabled:false` is honoured, and there is no dangling target (enabled
in-job modules require `site.backup.target`).

## Testing

`test.sh` is fast + offline (fixtures, never the live config or PBS). It
compiles the TS sources + unit tests, runs the unit suite under `test/unit/`
(a `FakeClient` for the controller boundary, fixtures under
`test/fixtures/config/`): cascade resolution, `validate`, `list`/`show`, the
`reconcile` plan (idempotent ensure-job-member + apply-schedule, and the
controller-mutation apply path), the `restore` delegation, and the
`modify`/`add`/`delete` atomic `.backup` writes. It then exercises the compiled
CLI against temp fixtures: cascade resolution at each layer, the `7y → 5y → 1y`
override demo, `enabled:false` disabling, `list` output, and the validator's
accept/reject cases.
