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
                   node add <N> [--pxe] [--boot-disk <d>] [--mac <m>]
                            [--wan-port <if>|--no-wan] [--pool <p>] [--ttl <s>]
                            [--config-only]
                   node delete <name>
                   node reconcile [--apply]
repository         repository list [--json]
                   repository add <url> [--branch <b>] [--managed full|tracked] [--catalog <p>]
                   repository delete <name> [--force]
                   repository reconcile [--apply]
top-level          add --name <site-code> [--organization <org>] [create-site options]  (= create-site.sh)
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

### `node add` — standing up a follow-on node (design N3/N4)

`node add <tappaasN>` is the operator front door for growing the cluster;
hardware-validated end-to-end on 2026-07-07. Three modes:

- **default (adopt)** — a Proxmox was already installed by hand (USB stick,
  §2.1 media) at the node's DESIGNATED mgmt IP (`tappaasN` → `10.0.0.<9+N>`):
  verifies the hostname + `pveversion` over ssh, then runs the join pipeline.
  A node that is already clustered skips straight to capture.
- **`--pxe`** — bare machine: registers the node with `node-provisioner`,
  arms the TTL-limited PXE trap, waits for the unattended install (the ONLY
  console interaction is the boot-disk question, and only when `--boot-disk`
  was not given), then continues with the same join pipeline. Requires the
  netboot assets staged once per PVE version — done automatically by the
  cicd install (`prepare-netboot.sh`). Booting the SAME prepared ISO from a
  USB stick instead of PXE works identically (the answer still comes over
  HTTP from the mothership).
- **`--config-only`** — just write the `hardware.nodes[]` entry (no machine
  contact); the pre-N3 behaviour.

The join pipeline (shared by adopt and `--pxe`): asks for the WAN NIC and
the data-pool declarations with the node's REAL hardware listed (skip the
questions with `--wan-port <if>`/`--no-wan` and `--pool 'tanka1=…'`),
serves the repo from the mothership on :8090 (committed branch state — no
GitHub dependency), runs the node step (`install.sh --join`), corrects
`/etc/hosts`, seeds node→tappaas1 ssh trust, `pvecm add`, and captures the
node + its pools via `node reconcile --apply`. Every wait is time-boxed and
the PXE trap is disarmed on every exit path. Fully unattended example:

```
site-manager node add tappaas2 --pxe --boot-disk sda \
    --mac aa:bb:cc:dd:ee:ff --no-wan --pool 'tanka1=single:nvme0n1'
```

Afterwards run `update-tappaas --force` to fold HA + replication.

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

(The former `migrate-configuration-to-site.sh` alias was retired in Phase 7.1 — it was a byte-identical duplicate.)

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
