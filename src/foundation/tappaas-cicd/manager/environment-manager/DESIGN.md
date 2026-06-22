# environment-manager — design notes

## Language and build

- **Language:** Bash throughout.
- **`install.sh`** links every `*.sh` (except the verb scripts) into `~/bin`, and
  additionally creates `~/bin/variant-manager` (symlink to `variant-manager.sh`)
  and `~/bin/migrate-variants-to-environments.sh` (alias for
  `migrate-variants.sh`). Nothing to compile.
- **`update.sh`** re-runs `install.sh` (idempotent relink).
- **`validate-environment.sh`** is the manager's `validate` operation
  (script-manager `validate-<manager>.sh` convention); there is no generic
  `validate.sh`.
- On-PATH entry points after install: `create-minimal-environments.sh`,
  `validate-environment.sh`, `migrate-variants.sh` (+ alias), `variant-manager`,
  `migrate-to-variants.sh`.

## Config state

- **`config/environments/<name>.json`** — the Environment document: `name`,
  `displayName`, `ownerOrg`, `network.zone` (required), optional `domains`
  (`primary`, `aliases[]`, `aliasMode`, `dnsMode`), `dataResidency`, `backup`,
  `legal`. Schema `environment-fields.json` is `additionalProperties:false`.
- **`configuration.json` `.tappaas.variants`** — the legacy migration source.
- Cross-referenced state it validates against: `config/zones.json` (for
  `network.zone`) and `config/people/organizations/*.json` (for `ownerOrg`).

`create-minimal-environments.sh` is the single owner of `mgmt.json` and the
default `<N>.json`; downstream steps consume but do not re-author them.

## How it talks to controllers

It drives no controller directly. `validate-environment.sh` validates with Python
`jsonschema` (with a `jq` fallback) plus `jq`-based cross-reference checks. The
legacy `variant-manager.sh` can create a zone via the network tooling
(`zone-manager`) unless `--no-activate` is given.

## Testing

`test.sh` follows the fast/deep convention. **Fast (default, temp fixtures,
non-disruptive):** the variant→environment migration shape, the `tlsCertRefid`
drop + schema reject, reference checks (`network.zone`, `ownerOrg`), bootstrap
(`--name <N>` and derivation from `site.json '.name'`), idempotency, and `--force`
overwrite. **Deep (`TAPPAAS_TEST_DEEP=1`):** additionally read-only-validates the
live `config/environments` directory when present — never writes to live.
Fixtures under `test/fixtures/`.

## Pending / not yet implemented

- **Phased migration.** `migrate-variants.sh` leaves `configuration.json` in
  place and the legacy `variant-manager.sh` / `migrate-to-variants.sh` scripts are
  kept as-is during the transition.
- **Deliberate drop of `tlsCertRefid`.** Migration discards it and the schema
  rejects it: whether a cert ref exists is decided by `dnsMode`, and the refid (if
  any) is reconciler-populated runtime state owned by the network/cert layer, not
  authored here.
- **Legacy `default.json`.** Older bootstraps may carry a literal `default.json`;
  `create-minimal-environments.sh` leaves it in place and notes it rather than
  deleting an operator file.
