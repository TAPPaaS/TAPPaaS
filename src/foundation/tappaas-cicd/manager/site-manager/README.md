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

## Commands

All scripts are bash, linked onto `PATH` by `install.sh`.

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
