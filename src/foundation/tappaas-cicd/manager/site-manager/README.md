# site-manager

The **Site** manager. The Site is the umbrella over a whole TAPPaaS installation:
site-wide identity, location, hardware (Proxmox nodes + storage pools), backup,
update schedule, repositories, and references to the environment/organization
config. (Domain / DNS / identity are *per-environment*, owned by
`environment-manager`, not here.)

## What it owns

`config/site.json` (default `${TAPPAAS_CONFIG:-/home/tappaas/config}/site.json`),
validated against `site-fields.json`. It also migrates the legacy
`config/configuration.json` into `site.json`.

## `site-manager` (TypeScript, ADR-007 verb-aligned)

The TypeScript `site-manager` bin is the verb-aligned front door (ADR-007, #3).
It owns the Site as a **singleton** and the `node` / `repository` sub-entities,
following the same `<entity> <verb>` shape as `network-manager`. The heavy
git/cluster I/O stays in the still-live bash tools, invoked as thin delegations:
`add` → `create-site.sh`, `repository add`/`delete` → `repository.sh`,
`validate` → `validate-site.sh`. TS owns config CRUD (`site modify`, `node`
CRUD, the `site.json` writes) + `validate` + `reconcile`.

### Entities and verbs

```
site (singleton)   site show [--json]
                   site modify --<field> <value> [...]
node               node list [--json]
                   node add --name <N> [--pool <p> ...]
                   node delete <name>
repository         repository list [--json]
                   repository add <url> [--branch <b>] [--managed full|tracked] [--catalog <p>]
                   repository delete <name> [--force]
                   repository reconcile [--apply]
top-level          add --name <N> [create-site options]   (= create-site.sh)
                   validate [FILE] [--schema-dir PATH]     (= validate-site.sh)
                   reconcile [--apply] [--deep]
```

Common options: `--config-dir DIR`, `--json` (machine output for list/show),
`--apply` (reconcile commits; default is preview), `--deep` (reconcile cascade),
`--force` (repository delete → `repository.sh remove --force`).

`site modify` editable fields (scalar, site-wide): `--displayName`, `--owner`,
`--email`, `--automaticReboot`, `--snapshotRetention`, `--backupTarget`,
`--backupOffsite`, `--locationCountry`, `--locationTimezone`,
`--locationLocale`, `--networkIsp`, `--networkPublicIp`. The discovery-derived
`hardware.nodes[]` (use `node …`) and the `repositories`/`environments`/
`organizations` lists (own CRUD / own managers) are **not** modifiable here.

### `reconcile` and the `--deep` cascade

`reconcile` is **shallow by default** — it converges the site's own concern:
validate `site.json`, then bring each `repositories[]` entry to a live clone
(clone if missing, checkout if the branch drifts). Default output is a
**preview**; `--apply` commits. `repository reconcile` is the repo-scoped
subset of the same engine.

`reconcile --deep` then cascades to the dependent managers in dependency order:

```
site reconcile --deep
  → people-manager  reconcile          (people → Authentik)
  → network-manager reconcile          (the 4 network planes)
  → for each environment in config/environments/*.json:
       environment-manager <env> reconcile --deep
```

people/network are single bins; environments fan out — one deep reconcile per
registered environment. Every leg is idempotent, so re-running is safe; this is
the natural whole-platform converge after `update-tappaas`.

### Build

TypeScript, built with `tsc` (zero npm deps, ambient `src/env.d.ts`), wrapped by
`default.nix` into `result/bin/site-manager` — mirroring `people-manager` /
`network-manager`. `install.sh` is **not** yet wired to nix-build it (the bash
tools below remain the installed entry points for now).

## Commands (legacy bash tools — kept live until cutover)

All scripts are bash, linked onto `PATH` by `install.sh`. `repository.sh` and
`validate-site.sh` remain live and are the tools the TS `repository add`/`delete`
and `validate` delegate to; `create-site.sh` backs the TS `add`.

### `repository.sh` — manage module repositories

The current, supported tool for registering the external module repositories
TAPPaaS pulls modules from (add / remove / modify / list). It stays until the
TypeScript site-manager subsumes it as a verb. (It currently reads/writes the
repository list in the legacy `configuration.json`; repointing it to
`site.json .repositories` is pending — see DESIGN.md.)

```
repository.sh add <url> [--branch <b>] [--managed full|tracked] [--catalog <path>]
repository.sh remove <name> [--force]
repository.sh modify <name> [--url <new>] [--branch <new>]
repository.sh list
```

### `validate-site.sh` — validate site.json

This is the manager's `validate` operation, named `validate-site.sh` per the
script-manager `validate-<manager>.sh` convention; runnable directly.

```
validate-site.sh [FILE] [--schema-dir PATH] [--quiet]
```

- `FILE` — site.json to validate (default `$TAPPAAS_CONFIG/site.json`).
- `--schema-dir PATH` — directory holding `site-fields.json`.
- `--quiet` — errors/warnings only.

```bash
validate-site.sh
```

## Legacy tools (kept until the flag-day cutover)

These predate `site.json` and operate on the legacy `configuration.json`:

### `migrate-configuration.sh` — configuration.json → site.json

One-time, phased migration: it creates `site.json`, backs up
`configuration.json` to `.bak`, and leaves `configuration.json` in place.
Idempotent. (Migration tool — retired once the cutover completes and
`configuration.json` is removed.)

```
migrate-configuration.sh [--config-dir DIR] [--input FILE] [--output FILE] [--force]
```

- `--config-dir DIR` — config directory (default `$TAPPAAS_CONFIG`).
- `--input FILE` — input configuration.json (default `<config-dir>/configuration.json`).
- `--output FILE` — output site.json (default `<config-dir>/site.json`).
- `--force` — overwrite an existing `site.json`.

Also linked as `migrate-configuration-to-site.sh` (alias).

```bash
migrate-configuration.sh
migrate-configuration.sh --force
```

### `create-configuration.sh`

Create/update `configuration.json` by discovering the running Proxmox cluster.
Accepts named flags (`--upstream-git`, `--branch`, `--domain`, `--email`,
`--schedule monthly|weekly|daily|none`, `--weekday`, `--hour`, `--primary-node`,
`--update`) or legacy positionals
(`<upstreamGit> <branch> <domain> <email> <schedule> [weekday] [hour]`). Idempotent.

### `validate-configuration.sh`

Validate `configuration.json`. Flags: `--config <path>`, `--check-connectivity`
(ping nodes), `--check-cluster` (SSH the first node, compare cluster membership),
`--check-repos` (git ls-remote each repo URL), `--quiet`.

### `convert-json-to-config.sh`

Convert a flat module JSON into the canonical config-block form. CLI:
`convert-json-to-config.sh [--in-place|--dry-run] <module-json>`; or source it and
call `regroup_to_pattern_a`.
