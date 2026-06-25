# site-manager — design notes

## Language and build

- **Language:** TypeScript for the verb-aligned `site-manager` bin (ADR-007 #3);
  Bash for the still-live operational tools it delegates to.
- **TypeScript `site-manager`** — the ADR-007 front door. Structure mirrors
  `people-manager` / `network-manager`: `src/main.ts` (verb dispatch + usage),
  `src/types.ts` (the Site model + the injected `SiteClient` boundary +
  reconcile-plan shapes), `src/config.ts` (load/validate/write `site.json`),
  `src/reconcile.ts` (the pure engine, depends only on `SiteClient`),
  `src/client.ts` (`CliSiteClient` — shells out to `git` / `validate-site.sh` /
  the dependent manager bins), `src/env.d.ts` (zero-dependency ambient decls).
  Built with `tsc` via `default.nix` (`result/bin/site-manager`), zero runtime
  deps. Unit tests under `test/unit/` use an in-memory `FakeSiteClient`.
- **Thin delegations.** TS owns config CRUD (`site modify`, `node` CRUD, the
  `site.json` writes) + `validate` + `reconcile`. The heavy git/cluster I/O
  stays in the bash tools, invoked over the client boundary: `add` →
  `create-site.sh`, `repository add`/`delete` → `repository.sh`, `validate` →
  `validate-site.sh` (one schema source).
- **`install.sh`** links every `*.sh` in the directory (except the lifecycle verb
  scripts `install.sh`/`update.sh`/`test.sh`) into `~/bin`, makes them
  executable, and additionally links `migrate-configuration-to-site.sh` as an
  alias for `migrate-configuration.sh`. **Not yet wired to nix-build the TS bin**
  — the bash tools remain the installed entry points for now. The bash
  `validate-site.sh` stays the `validate-<manager>.sh` convention entry.
- **`update.sh`** re-runs `install.sh` (idempotent relink).
- On-PATH entry points after install: `migrate-configuration.sh`,
  `migrate-configuration-to-site.sh`, `validate-site.sh`, plus the legacy
  `create-configuration.sh`, `validate-configuration.sh`,
  `convert-json-to-config.sh`, `repository.sh`.

## Verb model (TypeScript `site-manager`)

Entities are the first arg (`<entity> <verb>`, as in `network-manager`):

| Entity | Verbs | Notes |
|---|---|---|
| `site` (singleton) | `show`, `modify` | one `site.json`; no add/delete |
| `node` | `list`, `add`, `delete` | `hardware.nodes[]` CRUD |
| `repository` | `list`, `add`, `delete`, `reconcile` | add/delete delegate to `repository.sh`; reconcile = repo-scoped converge |

Top-level lifecycle verbs: `add` (create the singleton, = `create-site.sh`),
`validate` (= `validate-site.sh`), `reconcile` (`[--apply] [--deep]`).

Common options: `--config-dir`, `--json` (machine output for list/show),
`--apply` (reconcile commits; default preview), `--deep`, `--force`.

`site modify` editable fields are the **scalar site-wide** ones only:
`displayName`, `owner`, `email`, `automaticReboot`, `snapshotRetention`,
`backup.target`/`offsite`, `location.country`/`timezone`/`locale`,
`network.isp`/`publicIp`. `hardware.nodes[]` (via `node …`) and the
`repositories`/`environments`/`organizations` lists are excluded (own CRUD).

## Reconcile cascade

`reconcile` is shallow by default (validate `site.json`; converge each
`repositories[]` entry to a live clone — clone if missing, checkout on branch
drift). `--deep` walks the dependent managers in dependency order:

```
site reconcile --deep
  → people-manager  reconcile
  → network-manager reconcile
  → for each environment in config/environments/*.json:
       environment-manager <env> reconcile --deep
```

people/network are single bins (`people-manager reconcile` was renamed from
`sync` and now exists); environments are enumerated from
`config/environments/*.json` and each is driven with its own deep reconcile.
Every leg is idempotent. The reconcile engine is pure and depends only on the
injected `SiteClient`; `CliSiteClient` performs the actual `spawnSync` calls.

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
