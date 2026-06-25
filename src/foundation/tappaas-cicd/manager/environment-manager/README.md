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

## The `environment-manager` CLI (TypeScript, ADR-007 #3)

A first-pass TypeScript port presents the standardized ADR-007 verbs on the
`environment` entity. It is a thin orchestration boundary — it owns
`config/environments/*.json` and shells out to the plane/module managers for
reconcile; it reimplements no plane logic (exactly as `people-manager` shells
out to `authentik-manager`). Built with `tsc` (zero npm deps, ambient
`src/env.d.ts`) and wrapped via `default.nix`. The bash scripts below stay live.

```
environment-manager list [--json] [--config-dir DIR]
environment-manager show <env> [--json] [--config-dir DIR]
environment-manager validate [<file|dir>] [--config-dir DIR]
environment-manager add [<env>] [--name N] [--domain D] [--owner ORG]
                        [--zone Z] [--display D] [--dns-mode M] [--force] [--config-dir DIR]
environment-manager modify <env> [--domain D] [--owner ORG] [--zone Z]
                        [--display D] [--dns-mode M] [--config-dir DIR]
environment-manager delete <env> [--force] [--config-dir DIR]
environment-manager reconcile <env> [--deep] [--apply] [--config-dir DIR]
```

| Verb | Behaviour |
|------|-----------|
| `list` | Enumerate environments. `--json` emits the full objects as a JSON array; default prints `name (zone …)` per line. |
| `show <env>` | One environment in detail (canonical pretty JSON; `--json` = compact). |
| `validate [<file/dir>]` | **Thin wrapper** over `validate-environment.sh` — the canonical schema + reference gate (one source of truth, zero TS dependency). Relays its output and exit status. |
| `add` | Create an environment (writes validated config). With **no** `<env>` and **no** `--name` it **seeds the minimal set** (`mgmt` + the default `<N>`) via the `create-minimal-environments` bootstrap. With `<env>` (or `--name`) it creates that single env. `--owner` defaults to the first org under `people/organizations/`; `--zone` defaults to `<env>`. |
| `modify <env>` | Change an existing environment (preserves un-flagged fields; writes validated config). |

`--dns-mode <per-service\|wildcard>` (on `add`/`modify`) sets `domains.dnsMode` —
the cert strategy: `per-service` (default; Caddy per-host HTTP-01) or `wildcard`
(one `*.<primary>` OPNsense-ACME cert for the environment). Validated against the
schema enum; this closes the last field that previously required a hand-edit.
| `delete <env>` | Remove an environment file — **guard-railed** (see below). |
| `reconcile <env>` | Converge the environment → live. `--apply` commits (default = preview). `--deep` cascades (see below). |

### Reconcile cascade

- **Shallow** (`reconcile <env>`): reconcile the environment setup **and its
  associated zone**, by shelling out to `network-manager reconcile [--apply]`
  (the network owner converges the zone as part of its pass).
- **Deep** (`reconcile <env> --deep`): the above **plus** every deployed module
  that consumes this environment — `module-manager <module> reconcile [--apply]`
  per module. Consuming modules are enumerated as the deployed `config/*.json`
  files whose `.environment` field equals `<env>`. Each reconcile is idempotent,
  so re-touching the shared network is harmless.

### `delete` guard rails

`delete` **refuses** (exit 1) when, **without** `--force`:

- the target is the reserved management environment `mgmt`, **or**
- the target is the default `<N>` environment (`= site.json '.name'`), **or**
- one or more **deployed modules still consume** the environment (those modules
  are listed in the error).

`create-minimal-environments` is the single owner of the two bootstrap files;
`--force` overrides the guard rails for the rare deliberate removal.

## Commands (bash scripts)

All scripts are bash, linked onto `PATH` by `install.sh`. They remain live and
are the implementation the TS `validate` verb delegates to.

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
