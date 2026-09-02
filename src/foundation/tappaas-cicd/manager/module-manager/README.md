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
| `module resolve <m>` | `src/resolve.ts` (TS) | **desired state**: the config *plus* the schema defaults it does not declare (`--json`) |
| `module drift <m>` | `src/converge.ts` (TS) | that desired state **vs the live guest**, per service. `--service cluster:vm --json` prints the record a converge applies |
| `module validate [<m>]` | tier/source lint (TS) | all modules, or one; `--allow-fork` |
| `module add <m>` | `install-module.sh` | create + provision |
| `module modify <m>` | `update-module.sh` | release update (snapshot + test + 3-way merge). `--set field=value` also **changes a declared field** first (ADR-020) |
| `module delete <m>` | `delete-module.sh` | `--archive` (default) / `--remove` |
| `module reconcile <m>` | `src/inspect.ts` (TS) | read-only drift report (default); `--apply` → **leaf converge** (`src/reconcile.ts`) |
| `module test <m>` | `test-module.sh` | `--deep`, `--vmid`, `--zone0` |
| `module snapshot-vm <m>` | `snapshot-vm.sh` | special VM op (not CRUD) |

Common options: `--config-dir <dir>`, `--json` (list/show/resolve/validate), `-h`.
The leading `module` entity keyword is optional (it is the only entity).

**`show` vs `resolve`** — `show` prints the deployed config verbatim; `resolve`
prints what that config *means* once the `module-fields.json` defaults for
fields it does not declare are filled in. That resolved value is what a converge
actually uses, so the two differ exactly where a field is undeclared: `show`
omits `cputype`, `resolve` reports `host` (marked `default`). There is one
resolver behind it, shared by the drift report and the apply path, so the
reported desired value and the applied one cannot diverge (ADR-020 D1, #550).

> Not to be confused with `resolve-module.sh`, which answers a different
> question — *where* a module's source directory is. `list --resolution` is that
> one's reporting front door.

### Changing a field: `modify --set` (ADR-020)

```
module-manager module modify nextcloud --set cores=8 --set memory=16384
module-manager module modify nextcloud --set zone0=iot --force
```

One verb, one algorithm. Bare, `modify` is the release update `update-tappaas`
already runs. With `--set` it writes the field into the deployed config first and
then runs that *same* algorithm — snapshot, 3-way merge, converge, test,
`updateTime`. There is no second apply path to keep in step with the first.

**What it refuses, and when.** A change is refused up front only when the schema
alone can say so:

| Class | Example | What happens |
|---|---|---|
| `in-place` | `cores`, `memory`, `cputype`, `vmtag` | applied live, no downtime |
| `grow-only` | `diskSize` | a grow applies; a **shrink** is refused at apply time |
| `in-place-reboot` | `zone0`, `bridge0` | needs a guest reboot → **deferred** unless authorized |
| `migrate` | `node` | relocates the guest → deferred unless authorized |
| `manual` | `storage` | reported; moving a disk stays an operator action |
| `immutable` / `recreate` | `vmid`, `bios`, `image*` | **rejected before anything is written** |

A `--set` naming an immutable field is rejected *whole* — if any field in one
command cannot be applied, none of them are written, so config and cluster never
move apart. A field none of the module's services use is also rejected: writing
it would change the config and nothing else.

### `--force` vs `rebootOk` — three levers that no longer collide

Some changes need downtime. Whether we are *allowed* to cause it is a separate
question from whether the change needs it, and it has exactly two answers:

- **`module modify <m> --force`** — an operator, now.
- **`rebootOk: true` on the module**, honoured only inside the unattended sweep,
  and only because the site already accepts downtime in that window
  (`automaticReboot`). Default `false`: silence never authorizes a reboot.

**`update-tappaas --force` is neither.** It means "run the sweep now" — a
scheduling override — and is deliberately never forwarded, or a routine hourly
update could reboot production guests.

When a disruptive change is not authorized the converge applies everything else,
prints a machine-parseable line, and **still exits 0** — not applying a change is
not a failure:

```
⚠ DEFERRED: nextcloud net0 needs a disruptive change (reboot/offline migrate) that is not authorized
  Apply in a maintenance window:  module-manager module modify nextcloud --force
```

`update-tappaas` collects those and ends the sweep with one summary of what is
still pending.

**`reconcile` vs `drift`** — both compare declared state with reality, for
different readers. `reconcile <m>` is the operator's three-way report
(Released[git] / Desired[~/config] / Actual), field by field, plus the
dependency-service section. `drift <m>` is the two-way record a CONVERGE acts
on: which apply unit each change belongs to, what class it is, which hook takes
it, and what side effects it drags along. `drift --service <p:s> --json` is
literally the input to `update-service.sh --apply-drift`, so what you read is
what would be applied — there is one differ behind both (ADR-020 D7).

**`reconcile` vs `modify`** — `reconcile --apply` re-applies the *existing* config
(idempotent converge: each dependency's `update-service.sh` + the module's own
`update.sh`/`install.sh`, all run from the module directory), with **no snapshot,
no tests, no 3-way merge, and no `updateTime` bump**. `modify`
(`update-module.sh`) *changes* the config via a release update, then performs the
**same** apply by delegating to `reconcile --apply`, wrapped in snapshot + pre/post
tests + rollback. `reconcile` is the leaf the `site/environment reconcile --deep`
cascade walks down to.

**Service contract** — `services/<svc>/update-service.sh` is the converge for an
already-installed module and every service must ship one (enforced by `test.sh`).
`install-service.sh` is create-only prerequisites; where a service has no
create-only work it simply `exec`s `update-service.sh`. There is no fallback from
one to the other: `install-service.sh` has create semantics (`cluster:vm`'s calls
`Create-TAPPaaS-VM.sh`, which refuses an existing VMID), which is why reconcile
failed on every VM-backed module before #495.

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
