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

## Verb / controller split (ADR-007 verb-alignment)

**The manager resolves the cascade; the controller mutates PBS.** `backup-manager
reconcile` resolves the Site→Environment→Module policy for every deployed module
and calls the controller's mutation verbs (`add-to-job <vmid>`, `apply-schedule
<spec>`) to make PBS match. The manager never talks to PBS directly.

## Implementation

The manager lives under `src/` (built by `default.nix`; shared
CLI/help/exec/config-io helpers come from `lib/ts/src/` — mirrors
`site-manager`). `install.sh` builds + links the
`backup-manager` bin; the legacy bash entry scripts (`backup-manager.sh`,
`backup-status.sh`, `backup-restore.sh`, `validate-backup.sh`,
`lib-cascade.sh`) were **retired** in the ADR-007 post-implementation refactor,
Phase 7.4. The `backup-manager` bin shells out to `backup-controller` via
`CliClient` (`src/client.ts`, parsing `--json` output) — no PBS API is
reimplemented.

## Commands (standardized verbs)

```
backup-manager validate [--config-dir DIR]
        Backup hierarchy is well-formed + internally consistent (was validate-backup.sh).

backup-manager list [--disabled-only] [--json] [--config-dir DIR]
        Effective policy for every deployed module (was backup-status).
        OPTED-IN is the module's backup:vm declaration; IN-PBS-JOB is read
        from the managed bucket jobs and names the bucket holding it. They
        diverge — an archived module declares but has no guest, and a module
        that declared before the backup server existed is not a member yet.
        When PBS is unreachable the column falls back to the declaration and
        is marked `?` (--json: membershipSource "declaration").

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

backup-manager placement [--json]
        Where this site's PBS lives (placementState, pbsUrl, storage name).

backup-manager placement reset [--peer NAME] [--yes] [--no-update]
        Leave an external PBS for a local one (ADR-012 §2.3, #607). Refused unless
        placementState is external and a tankc pool exists. Runs, in order:
        backup-manage.sh reset-external (the old storage entry → <name>_former,
        still restorable; placementState → shim; formerExternal recorded), writes
        the old PBS as pull peer former-<host>, update-module.sh backup (the shim
        becomes a local PBS; the nodes push there), then onboards the pull
        (prompts for a read login on the old PBS). src/placement-reset.ts.

backup-manager placement finish-reset [--yes]
        Remove the <name>_former storage entry — after the pull and a test restore
        from pull/<peer>. The old PBS is never touched.
```

The single entry point is the `backup-manager` bin (linked onto `PATH` by
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

It also **warns** — never fails — about an off-site target not shown to be off-site (#609,
ADR-012 §1.5; `src/offsite.ts`): a satellite, `remote-` or `pull-` peer whose
`physicalLocation` is missing, or equal to `site.json`'s `location` at every level both record
(country, city, facility). A peer that predates the field is not a broken configuration.

## Testing

`test.sh` is fast + offline (fixtures, never the live config or PBS). It
compiles the sources + unit tests, runs the unit suite under `test/unit/`
(a `FakeClient` for the controller boundary, fixtures under
`test/fixtures/config/`): cascade resolution, `validate`, `list`/`show`, the
`reconcile` plan (idempotent ensure-job-member + apply-schedule, and the
controller-mutation apply path), the `restore` delegation, and the
`modify`/`add`/`delete` atomic `.backup` writes. It then exercises the compiled
CLI against temp fixtures: cascade resolution at each layer, the `7y → 5y → 1y`
override demo, `enabled:false` disabling, `list` output, and the validator's
accept/reject cases.
