# backup-manager — design

## Language / build

**TypeScript (first-pass port, ADR-007 verb-alignment #3); bash still live.** The
manager is being migrated to TypeScript to match `people-manager` /
`network-manager` (all-managers-to-TS, #3). The TS sources are under `src/`,
built by `default.nix` with `tsc` (zero npm deps, ambient `src/env.d.ts`), and
expose the standardized verbs (`validate`/`list`/`show`/`resolve`/`modify`/
`add`/`delete`/`reconcile`/`restore`). The original bash entry scripts
(`backup-manager.sh`, `backup-status.sh`, `validate-backup.sh`,
`backup-restore.sh`, `lib-cascade.sh`) **stay live** — `install.sh` is NOT yet
switched to the nix-build/compiled-component pattern.

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

- `lib-cascade.sh` is the bash source of truth for the resolver. It is *sourced*
  by `backup-manager.sh`, `backup-status.sh`, and `validate-backup.sh` (and is
  reusable by the controller) so all agree on precedence. It does pure config
  reads from `CONFIG_DIR` (overridable for fixtures) and never mutates state or
  contacts PBS — making the cascade fully unit-testable. `src/config.ts`
  re-implements the same precedence in lock-step; keep the two in sync.
- The bash cascade is computed in a single `jq -n` pass over the three layers
  (`site`, `environment`, `module`), so precedence is explicit and auditable; the
  TS port mirrors it field-for-field in `resolvePolicy`.
- The `validate` verb is `validate.sh` (P10 contract) delegating to the domain
  validator `validate-backup.sh` (script-manager `validate-<manager>` convention);
  the TS port re-implements the same checks in `src/validate.ts`.

## Integration

- `module-manager/install-module.sh` calls `backup-manager resolve` after zone0
  resolution and writes the module-relevant fields (`enabled`/`retention`/
  `exclude`) back onto the deployed module JSON's `.backup` — mirroring the
  existing zone0 write-back. Record-only: the `dependsOn backup:vm` wiring that
  adds a VM to the shared PBS job is untouched. The operator-facing `modify` /
  `add` / `delete` verbs are the hand-free way to change the same `.backup` /
  wiring.
- `health-manager/check-backup-status.sh` calls `backup-manager status`/`list`
  and flags disabled / not-in-PBS-job modules (read-only).

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
