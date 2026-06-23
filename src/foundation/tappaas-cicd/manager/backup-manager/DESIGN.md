# backup-manager — design

## Language / build

**Bash.** The manager is thin glue over `jq` config reads and the existing
foundation PBS bash logic, so Bash is the right tier (per the manager/controller
language preference TypeScript → Python → Bash, Bash is reserved for thin glue
and config-time scripts). Nothing to compile; `install.sh`/`update.sh` only link
the entry scripts onto `PATH` (idempotent).

## Shape

- `lib-cascade.sh` is the single source of the resolver. It is *sourced* by
  `backup-manager.sh`, `backup-status.sh`, and `validate-backup.sh` so all three
  agree on precedence. It does pure config reads from `CONFIG_DIR` (overridable
  for fixtures) and never mutates state or contacts PBS — making the cascade
  fully unit-testable.
- The cascade is computed in a single `jq -n` pass over the three layers
  (`site`, `environment`, `module`), so precedence is explicit and auditable.
- The `validate` verb is `validate.sh` (P10 contract) delegating to the domain
  validator `validate-backup.sh` (script-manager `validate-<manager>` convention).

## Integration

- `module-manager/install-module.sh` calls `backup-manager resolve` after zone0
  resolution and writes the module-relevant fields (`enabled`/`retention`/
  `exclude`) back onto the deployed module JSON's `.backup` — mirroring the
  existing zone0 write-back. Record-only: the `dependsOn backup:vm` wiring that
  adds a VM to the shared PBS job is untouched.
- `health-manager/check-backup-status.sh` calls `backup-manager status` and
  flags disabled / not-in-PBS-job modules (read-only).

## Pending / aspirations

- **Schedule application.** `backup.schedule` is resolved and recorded but not
  yet pushed to PBS as a per-environment job schedule (the shared job uses one
  site-wide start time today). Wiring it through `backup-controller` is a
  follow-up.
- The companion `backup-controller` is Bash that reuses the foundation PBS libs.
  The ADR-007 design names a *Python* controller (`pbs-api.py`); reusing the
  tested bash was the pragmatic choice for P9 — see
  [`backup-controller/DESIGN.md`](../../controller/backup-controller/DESIGN.md).
