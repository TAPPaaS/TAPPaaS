# module-manager

The **module lifecycle** manager: install, update, delete, test, reconcile, and
snapshot TAPPaaS modules, with tier/source classification lint and
environment-aware deployment. It owns the per-module JSON config in `config/` and
drives the Proxmox cluster (over SSH) to provision and maintain the module's VM.

## What it owns

- Per-module config JSON in `config/` (`<module>.json`, or
  `<module>-<environment>.json` for non-default environments), plus `.orig`
  backups used for a 3-way merge of operator edits against release updates.
- The `tier` (`foundation` | `app`) and `source`
  (`official` | `community` | `private` | `local`) classification on each module
  JSON, validated against `module-fields.json`.
- The `"kind":"module"` tag stamped onto every deployed config at install time —
  the authoritative marker `list`/`show` use to tell a deployed module apart
  from the co-located state files (`zones.json`, `site.json`, …). Configs from
  before the tag fall back to a heuristic (any of `dependsOn`/`provides`/
  `location`); provider-only modules (e.g. `templates`, no vmid/vmname) are kept.

## Standardized verbs (ADR-007 #3) — `module-manager`

The `module-manager` TypeScript CLI presents the **standardized verbs** on entity
`module` (the verb-alignment front door). It is a thin orchestrator: the
CONFIG-layer verbs (`list`/`show`/`validate`) are pure TS over `config/*.json`;
the LIFECYCLE verbs delegate to the bash scripts below (which stay live until a
later retire phase).

| Verb | Maps to | Notes |
|------|---------|-------|
| `module list` | — (TS) | enumerate deployed modules (`--json` for the cascade) |
| `module show <m>` | — (TS) | one deployed config in full (`--json`) |
| `module validate [<m>]` | tier/source lint (TS) | all modules, or one; `--allow-fork` |
| `module add <m>` | `install-module.sh` | create + provision |
| `module modify <m>` | `update-module.sh` | release update (snapshot + test + 3-way merge) |
| `module delete <m>` | `delete-module.sh` | `--archive` (default) / `--remove` |
| `module reconcile <m>` | `src/inspect.ts` (TS) | read-only drift report (default); `--apply` → **leaf converge** (`src/reconcile.ts`) |
| `module test <m>` | `test-module.sh` | `--deep`, `--vmid`, `--zone0` |
| `module snapshot-vm <m>` | `snapshot-vm.sh` | special VM op (not CRUD) |

Common options: `--config-dir <dir>`, `--json` (list/show/validate), `-h`.
The leading `module` entity keyword is optional (it is the only entity).

**`reconcile` vs `modify`** — `reconcile --apply` re-applies the *existing* config
(idempotent converge: dependency `*-service.sh` applies + the module's own
`update.sh`/`install.sh`), with **no snapshot, no tests, no 3-way merge, and no
`updateTime` bump**. `modify` (`update-module.sh`) *changes* the config via a
release update and does all of those. `reconcile` is the leaf the
`site/environment reconcile --deep` cascade walks down to.

**What `reconcile <m>` (no `--apply`) reports** — a read-only drift report in two
parts:

1. **Config fields** — three-way `Released[git]` / `Desired[~/config]` /
   `Actual[running VM]`; for a module with no `vmid` the Actual column is N/A and
   the diff degrades to Released-vs-Desired.
2. **Dependency-service state** — for each `dependsOn` entry, that provider's
   read-only `services/<service>/test-service.sh <module>` (the same verifier
   `module test` runs): declared firewall rules, NAT rules, discovery relays. For
   a policy-only module (no VM) this is the whole module, so without it a clean
   field diff said nothing (#458). `--no-services` skips it.

Detected drift **exits 0** — this is a report, and `list --diff` plus the
`--deep` cascade propagate the rc. A check that could not *run* (missing or
non-executable `test-service.sh`) exits 1: unknown state is not clean. A provider
that ships no `test-service.sh` is reported as **NOT checked**, never as passing.

The service checks cost one child process — usually one firewall API round-trip —
per dependency, so they are **on** for a single `reconcile <m>` and **off** for
the fleet/cascade paths: `list --diff` needs `--services` to include them (and
says so when it does not), and the `environment reconcile` preview passes
`--no-services`.

```bash
module-manager module list
module-manager module show nextcloud --json
module-manager module validate --allow-fork
module-manager module add nextcloud --environment acme
module-manager module reconcile nextcloud                # report: fields + dependency services
module-manager module reconcile nextcloud --no-services   # report: fields only
module-manager module reconcile nextcloud --apply        # converge to the current config
module-manager module list --diff --services             # fleet rollup, services included
```

## Underlying scripts

All bash, linked onto `PATH` by `install.sh`. These remain the source of truth
(the TS verbs orchestrate them) until a later retire phase.

### `install-module.sh` — install a module

```
install-module.sh <module-name> [--environment <name>] [--allow-fork]
                  [--force] [--reinstall] [--<field> <value>]...
```

- `--environment <name>` — target environment (sets the VM name and zone; default
  env → `<module>`, otherwise `<module>-<env>`). `--variant <name>` is a
  deprecated alias.
- `--allow-fork` — permit a `tier:foundation` module from a non-`official` source.
- `--force` — re-run against an existing install.
- `--reinstall` — delete then install (recover a failed partial install).
- `--<field> <value>` — override any module JSON field.

```bash
install-module.sh nextcloud
install-module.sh nextcloud --environment acme
```

### `update-module.sh` — update a module

```
update-module.sh [options] <module-name>
```

- `--environment <name>` — resolve the installed config name (deprecated alias
  `--variant`).
- `--force` — proceed despite a failing pre-update test.
- `--no-snapshot` — skip the pre-update snapshot / rollback.
- `--debug`, `--silent`.

It snapshots the VM, tests, updates, and rolls back on a fatal failure.

### `delete-module.sh` — delete a module

```
delete-module.sh <module-name> [--archive|--remove] [--vmid <id>]
                 [--environment <name>] [--yes|-y] [--force]
```

- `--archive` (default) keeps the config; `--remove` deletes it.
- `--vmid <id>` — target a specific VMID.
- `--environment <name>` (alias `--variant`).
- `--yes` / `-y` — skip the confirmation prompt.
- `--force` — skip dependency checks; **required** for `tier:foundation` modules.

### `test-module.sh` — run a module's tests

```
test-module.sh [--deep] [--vmid <id>] [--zone0 <zone>] <module-name>
```

```bash
test-module.sh openwebui
test-module.sh --deep litellm
```

### `snapshot-vm.sh` — manage a module's VM snapshots

```
snapshot-vm.sh <module-name> [--list | --cleanup <N> | --restore <N>]
```

No action = create a snapshot. `--list` lists; `--cleanup <N>` keeps the last
`N`; `--restore <N>` restores `N` steps back (1 = most recent).

### `copy-update-json.sh` — copy/normalize a module JSON into config

```
copy-update-json.sh <module-name> [--variant <name>] [--environment <name>]
                    [--default-environment <name>] [--vmname <v>] [--vmid <v>]
                    [--zone0 <v>] [--proxyDomain <v>] [--<field> <value>]...
```

Applies environment defaults (vmname suffix, auto-incremented vmid, zone from the
environment), validates fields against the schema, and writes canonical
config-block form.

### `module-format.sh` — convert JSON form

```
module-format.sh <to-flat|to-config> <file.json> [--in-place]
```

### `validate-module-tier-source.sh` — tier/source lint

```
validate-module-tier-source.sh [--allow-fork] [--quiet] <module.json>
```

`tier:foundation` requires `source:official` (override with `--allow-fork`);
invalid tier/source enums are rejected; `source:community` warns. Used standalone
and at install time.
