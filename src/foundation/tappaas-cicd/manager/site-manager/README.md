# manager/site-manager

Site (ADR-007d / ADR-007 P2) — site-wide identity, location, hardware (Proxmox
nodes + storage pools), backup, update schedule, repositories, and references to
environment/organization config files. The Site is the umbrella over a TAPPaaS
installation; domain/DNS/identity are per-environment, not here.

## Entry points (linked into ~/bin by install.sh)

- `migrate-configuration.sh` — migrate `config/configuration.json` -> `config/site.json`
  (alias: `migrate-configuration-to-site.sh`). **Phased (S3a):** creates
  `site.json`, backs up `configuration.json` to `.bak`, and does NOT delete
  `configuration.json`. Idempotent (`--force` to overwrite). Variant ->
  environment expansion is deferred to S4/P3 (`environments` stays `[]`).
- `validate-site.sh` — validate a `site.json` against
  `src/foundation/schemas/site-fields.json` (jsonschema + jq fallback).

Legacy site scripts (`create-configuration.sh`, `validate-configuration.sh`,
`convert-json-to-config.sh`, `repository.sh`) remain until the flag-day cutover.

## Auto-migration

`pre-update.sh` runs `migrate-configuration.sh` when `configuration.json` exists
and `site.json` does not (guarded, idempotent).

## Testing

`test.sh` follows the cicd fast/deep convention. FAST (default) migrates a
fixture `configuration.json` on a temp copy and asserts the schema + field
mapping; there are no deep/disruptive tests (S3a is all fast). The live config
is never touched. Fixture: `test/fixtures/configuration.json`.
