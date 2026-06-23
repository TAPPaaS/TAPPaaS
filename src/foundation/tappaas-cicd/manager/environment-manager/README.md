# environment-manager

The **Environment** manager. An Environment is a per-tenant deployment context:
public domain(s), DNS mode, a network-zone reference, data residency, backup
retention, and legal processor. Environments live at
`config/environments/<name>.json` and replace the legacy `configuration.json`
`.tappaas.variants` construct.

## What it owns

`config/environments/*.json` (default
`${TAPPAAS_CONFIG:-/home/tappaas/config}/environments/`), validated against
`environment-fields.json`. Mandatory fields: `name`, `displayName`, `ownerOrg`,
`network.zone`. `domains` is optional (the `mgmt` environment omits it);
`domains.dnsMode` defaults to `per-service`. The schema is
`additionalProperties:false`, so an authored `tlsCertRefid` is **rejected** — a
cert refid is runtime state, not authored config.

## Commands

All scripts are bash, linked onto `PATH` by `install.sh`.

### `create-minimal-environments.sh` — bootstrap the required environments

Creates the two always-required environments: `mgmt.json` (zone `mgmt`, no
domains) and the default tenant environment `<N>.json`, named after the TAPPaaS
system name `<N>` (with `network.zone = <N>`). Idempotent; never deletes operator
files.

```
create-minimal-environments.sh [--name <N>] [--config-dir DIR] [--out-dir DIR] [--force]
```

- `--name <N>` — system name (= default zone & env name). If omitted, derived
  from `site.json '.name'`, else from the first-domain label in
  `configuration.json`.
- `--config-dir DIR` — config directory (default `$TAPPAAS_CONFIG`).
- `--out-dir DIR` — environments dir (default `<config-dir>/environments`).
- `--force` — overwrite existing `mgmt.json` / `<N>.json`.

```bash
create-minimal-environments.sh --name acme
```

### `validate-environment.sh` — validate environment files

This is the manager's `validate` operation, named `validate-environment.sh` per
the script-manager `validate-<manager>.sh` convention.

```
validate-environment.sh [FILE|DIR] [--schema-dir PATH] [--config-dir DIR] [--zones FILE] [--quiet]
```

- `FILE|DIR` — an environment `.json` or a directory of them (default
  `$TAPPAAS_CONFIG/environments`).
- `--schema-dir PATH` — directory holding `environment-fields.json`.
- `--config-dir DIR` — config dir for the `zones.json` + organizations lookup.
- `--zones FILE` — path to `zones.json`.
- `--quiet` — errors/warnings only.

It checks the schema **and** reference integrity (`network.zone` must exist in
`zones.json`, `ownerOrg` must exist in the organizations) and rejects an authored
`tlsCertRefid`.

```bash
validate-environment.sh
```

## Retired tooling (ADR-007 Phase D)

The legacy ADR-005 variant registry is retired. The following scripts have been
removed — environments authored under `config/environments/*.json` are the single
source of truth, and modules deploy via `install-module.sh <module> --environment
<env>` (`--variant` is a deprecated alias for `--environment`):

- `variant-manager.sh` (managed `configuration.json` `.tappaas.variants`)
- `migrate-variants.sh` / `migrate-variants-to-environments.sh`
- `migrate-to-variants.sh`

To create or change an environment, author/edit its `config/environments/<env>.json`
file (validated by `validate-environment.sh`); to create its dedicated network
zone use `zone-controller add <env> --from-zone <src> --variant <env>`.
