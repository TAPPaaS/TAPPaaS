# module-manager

The **module lifecycle** manager: install, update, delete, test, and snapshot
TAPPaaS modules, with tier/source classification lint and environment-aware
deployment. It owns the per-module JSON config in `config/` and drives the
Proxmox cluster (over SSH) to provision and maintain the module's VM.

## What it owns

- Per-module config JSON in `config/` (`<module>.json`, or
  `<module>-<environment>.json` for non-default environments), plus `.orig`
  backups used for a 3-way merge of operator edits against release updates.
- The `tier` (`foundation` | `app`) and `source`
  (`official` | `community` | `private` | `local`) classification on each module
  JSON, validated against `module-fields.json`.

## Commands

All bash, linked onto `PATH` by `install.sh`.

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
