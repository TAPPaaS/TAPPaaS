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
`network.zone`. `domains` is optional in the schema, though bootstrap seeds it
on `mgmt` and the default environment alike when a site domain is known;
`domains.dnsMode` defaults to `per-service`. The schema is
`additionalProperties:false`, so an authored `tlsCertRefid` is **rejected** — a
cert refid is runtime state, not authored config.

## The `environment-manager` CLI (TypeScript, ADR-007 #3)

A first-pass TypeScript port presents the standardized ADR-007 verbs on the
`environment` entity. It is a thin orchestration boundary — it owns
`config/environments/*.json` and shells out to the plane/module managers for
reconcile; it reimplements no plane logic (exactly as `people-manager` shells
out to `authentik-manager`). Built with `tsc` (zero npm deps, ambient
`lib/ts/src/env.d.ts` from the shared TS library) and wrapped via `default.nix`
(a thin import of `lib/nix/ts-manager.nix`). The bash scripts below stay live.

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
                                   [--skip-network]
```

| Verb | Behaviour |
|------|-----------|
| `list` | Enumerate environments. `--json` emits the full objects as a JSON array; default prints `name (zone …)` per line. |
| `show <env>` | One environment in detail (canonical pretty JSON; `--json` = compact). |
| `validate [<file/dir>]` | The canonical schema + reference gate, implemented natively (src/validate.ts interprets `environment-fields.json` in-process — the former `validate-environment.sh` is retired). Checks full schema conformance (`additionalProperties:false`, `pattern`/`enum`/`minLength`, the `tlsCertRefid` rejection) **and** reference integrity (`network.zone` in `zones.json`, `ownerOrg` in the organizations). See "The `validate` gate" below. |
| `add` | Create an environment (writes validated config). With **no** positional `<env>` it **seeds the minimal set** (`mgmt` + the default `<N>`) — the bootstrap that replaced the retired `create-minimal-environments.sh`; `--name <N>` gives the system name explicitly, else it derives from `site.json '.name'` (see "The minimal-set bootstrap" below). With a positional `<env>` it creates that single env. `--owner` defaults to the first org under `people/organizations/`; `--zone` defaults to `<env>`. |
| `modify <env>` | Change an existing environment (preserves un-flagged fields; writes validated config). |

`--dns-mode <per-service\|wildcard>` (on `add`/`modify`) sets `domains.dnsMode` —
the cert strategy: `per-service` (default; Caddy per-host HTTP-01) or `wildcard`
(one `*.<primary>` OPNsense-ACME cert for the environment). Validated against the
schema enum; this closes the last field that previously required a hand-edit.
| `delete <env>` | Remove an environment file — **guard-railed** (see below). |
| `reconcile <env>` | Converge the environment → live. `--apply` commits (default = preview). `--deep` cascades (see below). Also **materializes a missing service zone** and **hard-errors on a wrongly-typed one** — see "Env ↔ service zone" below. |

### Reconcile cascade

### Env ↔ service zone (ADR-014 D1)

An Environment binds to **exactly one** service zone (`network.zone`, defaulting
to the environment's own name). Making that binding real used to be two steps in
a specific order, and getting it wrong failed quietly:

- **`add <env> --create-zone`** authors the Service zone *first* (if it does not
  already exist), then writes the environment — one command yields a working
  pair. Opt-in on purpose: default-on would let a typo'd `--zone` silently mint
  a stray zone.
- **`reconcile <env>`** no longer merely warns that `network.zone` is absent —
  it **plans the zone's creation** and authors it before the network pass. An
  environment naming a zone that never existed could previously never converge.
- If the zone **exists but is not a Service zone** (the operator pointed the
  environment at a client/IoT segment), that is a **hard error** in both preview
  and apply. Reconcile will not paper over it by minting a second zone; re-point
  the environment with `modify <env> --zone <serviceZone>`, or — if you meant the
  client zone to *consume* the environment — bind it the other way round with
  `network-manager bind <zone> --environment <env>`.

```bash
environment-manager add acme --create-zone          # env + service zone 'acme'
environment-manager add acme --zone shared --create-zone
network-manager reconcile --apply                   # converge the new zone
```

**Ownership boundary (unchanged).** `network-manager` remains the sole writer of
`zones.json`; environment-manager *requests* zone creation across the existing
client seam (`network-manager add <Z> --archetype service`), never editing zones
itself. The `service` archetype means the new zone lands tier-correct rather than
with bare defaults.

- **Shallow** (`reconcile <env>`): shell out to `network-manager reconcile
  [--apply]`. **This pass is system-wide, not scoped to the environment** —
  network-manager has no zone or environment filter, so it converges every zone
  on every plane; `<env>`'s zone is simply part of it. The plan tags the action
  `[system-wide]` so the label matches what actually happens (#461).
- **Deep** (`reconcile <env> --deep`): the above **plus** every deployed module
  that consumes this environment — `module-manager reconcile <module> [--apply]`
  per module. Consuming modules are enumerated as the deployed `config/*.json`
  files whose `.environment` field equals `<env>`. Each reconcile is idempotent,
  so re-touching the shared network is harmless.
- **`--skip-network`**: drop the network action when the caller has already run
  the system-wide pass. Reconciling N environments otherwise repeats one
  identical whole-platform operation N times — which is what
  `site-manager reconcile --deep` used to do.

### `delete` guard rails

`delete` **refuses** (exit 1) when, **without** `--force`:

- the target is the reserved management environment `mgmt`, **or**
- the target is the default `<N>` environment (`= site.json '.name'`), **or**
- one or more **deployed modules still consume** the environment (those modules
  are listed in the error).

The `add` minimal-set bootstrap is the single owner of the two bootstrap files;
`--force` overrides the guard rails for the rare deliberate removal.

### The `validate` gate

`environment-manager validate` (also reachable as the P10 verb script
`validate.sh`) validates environment files against
`src/foundation/schemas/environment-fields.json` plus reference integrity:

```
environment-manager validate [FILE|DIR] [--schema-dir PATH] [--config-dir DIR] [--zones FILE] [--quiet]
```

- `FILE|DIR` — an environment `.json` or a directory of them (default
  `$TAPPAAS_CONFIG/environments`).
- `--schema-dir PATH` — directory holding `environment-fields.json` (default:
  `$SCHEMA_DIR`, else derived from the checkout).
- `--config-dir DIR` — config dir for the `zones.json` + organizations lookup.
- `--zones FILE` — path to `zones.json`.
- `--quiet` — errors/warnings only.

The schema stays the single source of truth: `src/validate.ts` interprets it at
runtime (the small draft-2020-12 subset it uses), and **fails loudly** if the
schema ever grows a keyword the interpreter does not implement — so the gate can
never silently under-validate. Exit codes: 0 = valid (warnings allowed),
1 = validation errors. The former `validate-environment.sh` bash implementation
(Python `jsonschema` + jq fallback) is retired.

### The minimal-set bootstrap (`add` with no `<env>`)

Creates the two always-required environments: `mgmt.json` (zone `mgmt`, no
domains) and the default tenant environment `<N>.json`, named after the TAPPaaS
system name `<N>` (with `network.zone = <N>`). Idempotent (existing files are
left untouched without `--force`); never deletes operator files (a stale legacy
`default.json` is noted, not removed).

```
environment-manager add [--name <N>] [--domain <D>] [--config-dir DIR] [--force]
```

- `--name <N>` — system name (= default zone & env name). If omitted, derived
  from `site.json '.name'`.
- `--domain <D>` — the default env's `domains.primary` (omitted ⇒ no domain yet).
- `--config-dir DIR` — config directory (default `$TAPPAAS_CONFIG`);
  environments land in `<config-dir>/environments`.
- `--force` — overwrite existing `mgmt.json` / `<N>.json`.

```bash
environment-manager add --name acme
```

This is the single owner of the two bootstrap files (`install.sh` and
`migrate-to-adr007.sh` call it) — downstream steps consume, they do not
re-author them.

## Retired tooling (ADR-007 Phase D)

The legacy ADR-005 variant registry is retired. The following scripts have been
removed — environments authored under `config/environments/*.json` are the single
source of truth, and modules deploy via `install-module.sh <module> --environment
<env>` (`--variant` is a deprecated alias for `--environment`):

- `variant-manager.sh` (managed `configuration.json` `.tappaas.variants`)
- `migrate-variants.sh` / `migrate-variants-to-environments.sh`
- `migrate-to-variants.sh`

Also retired (ADR-007 post-implementation refactor): `validate-environment.sh` —
the `environment-manager validate` verb is the schema + reference gate now
(same flags, same exit codes; see "The `validate` gate" above) — and
`create-minimal-environments.sh` (Phase 8.1) — `environment-manager add` with no
positional `<env>` is the minimal-set bootstrap now (same `--name`/`--domain`/
`--config-dir`/`--force` flags; the unused `--out-dir` was dropped).

To create or change an environment, author/edit its `config/environments/<env>.json`
file (validated by `environment-manager validate`); to create its dedicated network
zone use `network-manager zone add <env> --from-zone <src> --variant <env>`.
