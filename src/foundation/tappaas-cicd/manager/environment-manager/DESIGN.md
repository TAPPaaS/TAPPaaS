# environment-manager — design notes

## Language and build

- **Language:** TypeScript for the `environment-manager` CLI (ADR-007 #3
  first-pass port; the original Bash entry points are retired).
- **TypeScript port (`src/`):** `main.ts` (verb dispatch + `usage()`),
  `types.ts` (Environment model + `NetworkClient`/`ModuleClient` interfaces),
  `config.ts` (load/write/serialize + in-process ref validation),
  `bootstrap.ts` (the minimal-set bootstrap — the retired
  `create-minimal-environments.sh`, ported), `reconcile.ts` (the
  pure cascade engine, depends only on the injected clients), `clients.ts`
  (`CliNetworkClient`/`CliModuleClient` — the spawnSync FFI), `validate.ts` (the
  native schema + reference gate). The shared TS library
  (`../../lib/ts/src/`) supplies the CLI conventions (`cli.ts`), the exec
  helpers (`exec.ts`), config I/O (`config-io.ts`), the `--help` renderer
  (`help.ts`), and the zero-dependency ambient decls (`env.d.ts` — Node
  built-ins only, no `@types/node`); the former vendored `src/help.ts` /
  `src/env.d.ts` copies are gone. Built with `tsc` and wrapped by `default.nix`
  (a thin import of `lib/nix/ts-manager.nix`); unit tests under `test/unit/`
  inject fakes.
- **`install.sh`** nix-builds + links the TS bin and links any remaining `*.sh`
  (except the verb scripts) into `~/bin`; it also drops stale links from older
  installs. (The legacy ADR-005 variant registry tooling — `variant-manager.sh`,
  `migrate-variants.sh`, `migrate-to-variants.sh` — has been retired, ADR-007
  Phase D.)
- **`update.sh`** re-runs `install.sh` (idempotent relink).
- On-PATH entry point after install: the `environment-manager` bin. The former
  bash entry points are retired — `validate-environment.sh` (→ the native
  `validate` verb, Phase 7.3) and `create-minimal-environments.sh` (→ `add`
  with no positional `<env>`, Phase 8.1).

## Verbs (the `environment` entity)

Standardized ADR-007 verbs, all on `config/environments/<env>.json`:

- **`list` / `show`** — enumerate / detail; `--json` for machine output.
- **`validate`** — the native schema + reference gate (`src/validate.ts`).
- **`add`** — create an env (writes validated config). No positional `<env>`
  ⇒ seed the minimal set (`mgmt` + default `<N>`) via the bootstrap — `--name`
  gives `<N>` explicitly, else it derives from `site.json '.name'`; otherwise a
  single env. `--owner` defaults to the first org under `people/organizations/`;
  `--zone` defaults to `<env>`.
- **`modify`** — change an env, preserving un-flagged fields.
- **`delete`** — remove an env, guard-railed (below).
- **`reconcile [--deep] [--apply]`** — converge config → live (below).

### Reconcile cascade

- **shallow** (`reconcile <env>`): shell out to `network-manager reconcile
  [--apply]`. This is a **system-wide** pass, not a per-environment one:
  network-manager takes no zone or environment filter, so it converges every
  zone on every plane and this environment's zone is merely included. The plan
  labels the action `[system-wide]` and says so (#461) — an operator must never
  read it as narrow.
- **`--deep`**: the above **plus** every deployed module that consumes this
  environment → `module-manager <module> reconcile [--apply]`. Consumers are the
  deployed `config/*.json` whose `.environment === <env>`. `--apply` commits;
  default is preview. Each reconcile is idempotent, so re-touching the shared
  network is harmless.
- **`--skip-network`**: omit the network action because the caller already ran
  the system-wide pass. Without it, driving N environments performs N identical
  whole-platform network runs; `site-manager reconcile --deep` passes it after
  running the pass once itself. The zone-reference check (and its warning) still
  runs — that is about config correctness, not about who converges.

### `delete` guard rails

Without `--force`, `delete` refuses to remove `mgmt`, the default `<N>`
environment (`= site.json '.name'`), or any environment still consumed by one or
more deployed modules (listed in the error). The `add` minimal-set bootstrap is
the single owner of the two bootstrap files; `--force` overrides for deliberate
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

The `add` minimal-set bootstrap (`src/bootstrap.ts`) is the single owner of
`mgmt.json` and the default `<N>.json`; downstream steps consume but do not
re-author them.

## How it talks to controllers

It is a thin orchestration boundary — it owns `config/environments/*.json` and
shells out for everything else (no plane/module logic is reimplemented, exactly
as `people-manager` shells out to `authentik-manager`):

- **`reconcile`** → `network-manager` (`zone exists`, `reconcile [--apply]`) for
  the environment's zone, and `module-manager <module> reconcile [--apply]` per
  consuming module under `--deep`. These are injected `NetworkClient` /
  `ModuleClient` interfaces (`clients.ts`), so the engine is pure and the unit
  tests use fakes.
- **`validate`** is native (`src/validate.ts` interprets
  `environment-fields.json` in-process, plus the cross-reference checks) — no
  shell-out.

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
  the `add` minimal-set bootstrap leaves it in place and notes it rather than
  deleting an operator file.
