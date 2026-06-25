# environment-manager — design notes

## Language and build

- **Language:** TypeScript for the `environment-manager` CLI (ADR-007 #3
  first-pass port), with the original Bash scripts kept live underneath.
- **TypeScript port (`src/`):** `main.ts` (verb dispatch + `usage()`),
  `types.ts` (Environment model + `NetworkClient`/`ModuleClient` interfaces),
  `config.ts` (load/write/serialize + in-process ref validation),
  `bootstrap.ts` (the `create-minimal-environments` logic), `reconcile.ts` (the
  pure cascade engine, depends only on the injected clients), `clients.ts`
  (`CliNetworkClient`/`CliModuleClient` — the spawnSync FFI), `validate.ts` (a
  thin wrapper over `validate-environment.sh`), `env.d.ts` (zero-dependency
  ambient decls — Node built-ins only, no `@types/node`). Built with `tsc` and
  wrapped by `default.nix`; unit tests under `test/unit/` inject fakes.
- **`install.sh`** links every `*.sh` (except the verb scripts) into `~/bin`.
  (The legacy ADR-005 variant registry tooling — `variant-manager.sh`,
  `migrate-variants.sh`, `migrate-to-variants.sh` — has been retired, ADR-007
  Phase D.) Wiring `install.sh` to `nix-build`/symlink the TS bin is a follow-up.
- **`update.sh`** re-runs `install.sh` (idempotent relink).
- **`validate-environment.sh`** is the CANONICAL `validate` gate (full JSON-Schema
  conformance via Python `jsonschema` + jq fallback, plus reference checks); the
  TS `environment validate` verb is a thin wrapper that shells out to it (one
  source of truth, zero TS dependency).
- On-PATH entry points after install: `create-minimal-environments.sh`,
  `validate-environment.sh` (and, once wired, the `environment-manager` bin).

## Verbs (the `environment` entity)

Standardized ADR-007 verbs, all on `config/environments/<env>.json`:

- **`list` / `show`** — enumerate / detail; `--json` for machine output.
- **`validate`** — delegates to `validate-environment.sh` (see above).
- **`add`** — create an env (writes validated config). No `<env>` + no `--name`
  ⇒ seed the minimal set (`mgmt` + default `<N>`) via the bootstrap; otherwise a
  single env. `--owner` defaults to the first org under `people/organizations/`;
  `--zone` defaults to `<env>`.
- **`modify`** — change an env, preserving un-flagged fields.
- **`delete`** — remove an env, guard-railed (below).
- **`reconcile [--deep] [--apply]`** — converge config → live (below).

### Reconcile cascade

- **shallow** (`reconcile <env>`): reconcile the environment setup **and its
  associated zone** by shelling out to `network-manager reconcile [--apply]`
  (the network owner converges that zone in its pass).
- **`--deep`**: the above **plus** every deployed module that consumes this
  environment → `module-manager <module> reconcile [--apply]`. Consumers are the
  deployed `config/*.json` whose `.environment === <env>`. `--apply` commits;
  default is preview. Each reconcile is idempotent, so re-touching the shared
  network is harmless.

### `delete` guard rails

Without `--force`, `delete` refuses to remove `mgmt`, the default `<N>`
environment (`= site.json '.name'`), or any environment still consumed by one or
more deployed modules (listed in the error). `create-minimal-environments` is the
single owner of the two bootstrap files; `--force` overrides for deliberate
removal.

## Config state

- **`config/environments/<name>.json`** — the Environment document: `name`,
  `displayName`, `ownerOrg`, `network.zone` (required), optional `domains`
  (`primary`, `aliases[]`, `aliasMode`, `dnsMode`), `dataResidency`, `backup`,
  `legal`. Schema `environment-fields.json` is `additionalProperties:false`. This
  is the single source of truth (the `configuration.json` `.tappaas.variants`
  registry is retired, ADR-007 Phase D).
- Cross-referenced state it validates against: `config/zones.json` (for
  `network.zone`) and `config/people/organizations/*.json` (for `ownerOrg`).

`create-minimal-environments.sh` is the single owner of `mgmt.json` and the
default `<N>.json`; downstream steps consume but do not re-author them.

## How it talks to controllers

It is a thin orchestration boundary — it owns `config/environments/*.json` and
shells out for everything else (no plane/module logic is reimplemented, exactly
as `people-manager` shells out to `authentik-manager`):

- **`reconcile`** → `network-manager` (`zone exists`, `reconcile [--apply]`) for
  the environment's zone, and `module-manager <module> reconcile [--apply]` per
  consuming module under `--deep`. These are injected `NetworkClient` /
  `ModuleClient` interfaces (`clients.ts`), so the engine is pure and the unit
  tests use fakes.
- **`validate`** → `validate-environment.sh` (Python `jsonschema` with a `jq`
  fallback, plus `jq` cross-reference checks).

A dedicated network zone for an environment is created via `network-manager zone
add` (the TS network owner; was `zone-controller add`).

## Testing

- **TS unit tests (`test/unit/`):** zero-dep, inline-assert harness compiled via
  `test/unit/tsconfig.json` and run under Node. `reconcile.test.ts` exercises the
  pure cascade engine with `FakeNetworkClient`/`FakeModuleClient` (shallow vs
  `--deep`, unknown-zone warning, apply ordering). `config.test.ts` covers
  load/write/serialize, `validateEnvironmentRefs` (valid, unknown zone/owner,
  `tlsCertRefid` reject), the bootstrap (name/owner derivation, idempotency), and
  `CliModuleClient` consumer discovery — all against a throwaway temp config tree.
- **`test.sh`** follows the fast/deep convention. **Fast (default, temp fixtures,
  non-disruptive):** the `tlsCertRefid` drop + schema reject, reference checks
  (`network.zone`, `ownerOrg`), bootstrap (`--name <N>` and derivation from
  `site.json '.name'`), idempotency, and `--force` overwrite. **Deep
  (`TAPPAAS_TEST_DEEP=1`):** additionally read-only-validates the live
  `config/environments` directory when present — never writes to live. Fixtures
  under `test/fixtures/`.

## Pending / not yet implemented

- **Deliberate drop of `tlsCertRefid`.** The schema
  rejects it: whether a cert ref exists is decided by `dnsMode`, and the refid (if
  any) is reconciler-populated runtime state owned by the network/cert layer, not
  authored here.
- **Legacy `default.json`.** Older bootstraps may carry a literal `default.json`;
  `create-minimal-environments.sh` leaves it in place and notes it rather than
  deleting an operator file.
