# site-manager — design notes

## Language and build

- **Language:** Bash throughout.
- **`install.sh`** links every `*.sh` in the directory (except the verb scripts
  `install.sh`/`update.sh`/`test.sh`/`validate.sh`) into `~/bin`, makes them
  executable, and additionally links `migrate-configuration-to-site.sh` as an
  alias for `migrate-configuration.sh`. There is nothing to compile.
- **`update.sh`** re-runs `install.sh` (idempotent relink).
- On-PATH entry points after install: `migrate-configuration.sh`,
  `migrate-configuration-to-site.sh`, `validate-site.sh`, plus the legacy
  `create-configuration.sh`, `validate-configuration.sh`,
  `convert-json-to-config.sh`, `repository.sh`.

## Config state

- **`site.json`** — the canonical Site document: `name`, `displayName`, `owner`,
  `email`, `version`, `location` (country/timezone/locale), `network`,
  `hardware.nodes[]` (each with `storagePools`), `backup`, `updateSchedule`,
  `automaticReboot`, `snapshotRetention`, `repositories[]`, `environments[]`,
  `organizations[]`. Validated against `site-fields.json` (JSON Schema 2020-12).
- **`configuration.json`** — the legacy predecessor (fields under `.tappaas` plus
  a `.tappaas-nodes[]` array). The migration source.

The migration maps the domain label to `name`, `tappaas-nodes` to
`hardware.nodes`, and carries email / repositories / update schedule / reboot /
snapshot-retention; it drops `domain`, `variants`, and `nodeCount`. The owner is
derived from `config/people/organizations/`.

## How it talks to controllers

It does not drive any controller. `validate-site.sh` validates via Python
`jsonschema` (with a `jq` required-field fallback). `create-configuration.sh`
discovers the live Proxmox cluster over SSH and calls `validate-configuration.sh`
afterward. `repository.sh` validates module catalogs and writes the repository
list into `configuration.json`. `convert-json-to-config.sh` is also sourced as a
library by other module-JSON tooling.

## Auto-migration hook

The mothership's pre-update step runs `migrate-configuration.sh` automatically
when `configuration.json` exists and `site.json` does not (guarded, idempotent).

## Testing

`test.sh` follows the fast/deep convention. **Fast (default):** migrate a fixture
`configuration.json` on a temp copy and assert the schema, field mapping, dropped
fields, idempotency, `--force` overwrite, the alias, and owner derivation. The
live config is never touched (fixture: `test/fixtures/configuration.json`). There
are **no deep/disruptive tests** for this manager.

## Pending / not yet implemented

- **Phased migration, not flag-day.** `migrate-configuration.sh` deliberately
  leaves `configuration.json` in place rather than deleting it; the legacy tools
  (`create-configuration.sh`, `validate-configuration.sh`,
  `convert-json-to-config.sh`, `repository.sh`) remain until a future flag-day
  cutover removes them.
- **Environment expansion deferred.** The migration writes `environments` as an
  empty list (`[]`); populating it from the legacy variants is owned by
  `environment-manager`, run separately.
