# backup-manager — design

## Language / build

**TypeScript (ADR-007 verb-alignment #3), matching `people-manager` /
`network-manager` (all-managers-to-TS, #3).** The TS sources are under `src/`,
built by `default.nix` via the shared `lib/nix/ts-manager.nix` builder with
`tsc` (zero npm deps, ambient `lib/ts/src/env.d.ts`; help/CLI/exec/config-io
helpers imported from the shared `lib/ts/src/`), and
expose the standardized verbs (`validate`/`list`/`show`/`resolve`/`modify`/
`add`/`delete`/`reconcile`/`restore`). `install.sh` builds + links the bin.
The original bash entry scripts (`backup-manager.sh`, `backup-status.sh`,
`validate-backup.sh`, `backup-restore.sh`, `lib-cascade.sh`) were **retired**
in the ADR-007 post-implementation refactor, Phase 7.4.

### Division of labour (manager ↔ controller)

**The manager resolves the cascade; the controller mutates PBS.** `reconcile`
resolves the Site→Environment→Module policy per module (pure, `src/config.ts` +
`src/reconcile.ts`) and drives the controller's mutation verbs via `CliClient`
(`src/client.ts`, parsing `backup-controller --json`):

- `backup-controller add-to-job <vmid> [--retention SPEC]` — ensure a module's
  VM is a member of the shared managed PBS job (reuses `pbs_ensure_vmid`).
- `backup-controller apply-schedule <spec>` — set the shared job's start time.

`reconcile` is whole-cluster and idempotent (preview by default; `--apply`
commits). No PBS API is reimplemented in the manager.

### CRUD = the module `.backup` layer

`modify <module>` writes `.backup` `{enabled, retention, exclude}` onto
`config/<module>.json` (atomic temp-write + rename, `src/modify.ts`); `add` /
`delete` manage the module's `dependsOn: ["backup:vm"]` wiring. The manager OWNS
these `.backup` writes. `install-module` keeps calling `resolve` to record the
resolved policy after a deploy — that path is unchanged and not duplicated here.

## Shape

- `src/config.ts` `resolvePolicy` is the source of truth for the resolver
  (it replaced the sourced `lib-cascade.sh` in Phase 7.4). It does pure config
  reads from the config dir (`--config-dir` / `$CONFIG_DIR`, overridable for
  fixtures) and never mutates state or contacts PBS — making the cascade fully
  unit-testable. Precedence is explicit and field-for-field over the three
  layers (`site`, `environment`, `module`).
- The `validate` verb is `validate.sh` (P10 contract) exec-ing
  `backup-manager validate`; the checks live in `src/validate.ts`.

## Integration

- `module-manager/install-module.sh` calls `backup-manager resolve` after zone0
  resolution and writes the module-relevant fields (`enabled`/`retention`/
  `exclude`) back onto the deployed module JSON's `.backup` — mirroring the
  existing zone0 write-back. Record-only: the `dependsOn backup:vm` wiring that
  adds a VM to the shared PBS job is untouched. The operator-facing `modify` /
  `add` / `delete` verbs are the hand-free way to change the same `.backup` /
  wiring.
- `health-manager`'s `backup-status` gate (`src/checks.ts`) spawns
  `backup-manager list --json` and flags disabled / not-in-PBS-job modules
  (read-only).

## Pending / aspirations

- **Per-environment schedules.** `reconcile` now pushes the resolved `schedule`
  to PBS via `backup-controller apply-schedule`, but PBS carries a *single*
  shared-job start time; a true per-environment schedule (multiple jobs) is the
  remaining follow-up — `reconcile` warns when modules resolve >1 distinct
  schedule and applies the first.
- **Per-job retention.** `add-to-job --retention` is plumbed through but per-job
  prune wiring is a follow-up; the shared job + the foundation prune-job own
  retention today.
- The companion `backup-controller` is Bash that reuses the foundation PBS libs.
  The ADR-007 design names a *Python* controller (`pbs-api.py`); reusing the
  tested bash was the pragmatic choice for P9 — see
  [`backup-controller/DESIGN.md`](../../controller/backup-controller/DESIGN.md).
