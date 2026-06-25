# module-manager — design notes

## Language and build

- **Front door:** the `module-manager` **TypeScript** CLI (ADR-007 #3 verb
  alignment) — a thin orchestrator mirroring `people-manager` / `network-manager`
  (zero npm deps, ambient `src/env.d.ts`, built by `tsc` via `default.nix` into
  `result/bin/module-manager`). It owns the CONFIG-layer verbs in-process and
  delegates the LIFECYCLE verbs to the bash scripts.
- **Underlying lifecycle scripts:** Bash, unchanged. `install-module.sh`,
  `update-module.sh`, `delete-module.sh`, `reconcile-module.sh`,
  `test-module.sh`, `snapshot-vm.sh` + helpers (`copy-update-json.sh`,
  `module-format.sh`, `validate-module-tier-source.sh`,
  `test-validate-module-tier-source.sh`). They stay the source of truth until a
  later retire phase; the TS verbs orchestrate them.
- **`install.sh`** links every `*.sh` (except the verb scripts) into `~/bin`
  (`${TAPPAAS_BIN:-/home/tappaas/bin}`). NOTE (next phase, NOT done here): it does
  not yet `nix-build` + link the `module-manager` TS bin — that is deferred.
- **`update.sh`** re-runs `install.sh` (idempotent relink).

## Standardized verbs (ADR-007 #3)

`module-manager` presents the canonical verbs on entity `module`. CONFIG-layer
verbs are pure TS (read `config/*.json`); LIFECYCLE verbs shell out via an
injected `ModuleClient` (production `CliModuleClient`; tests inject a fake):

| Verb | Layer | Maps to |
|------|-------|---------|
| `list` / `show` | TS (config) | enumerate / detail deployed modules (`--json`) |
| `validate` | TS (config) | tier/source lint (ported from `validate-module-tier-source.sh`) |
| `add` | bash | `install-module.sh` |
| `modify` | bash | `update-module.sh` (release update) |
| `delete` | bash | `delete-module.sh` |
| `reconcile` | bash | `reconcile-module.sh` (leaf converge — see below) |
| `test` | bash | `test-module.sh` |
| `snapshot-vm` | bash | `snapshot-vm.sh` (special VM op) |

Common options: `--config-dir`, `--json` (list/show/validate). The `module`
entity keyword is optional.

### Module identity — the `kind` tag

`install-module.sh` stamps `"kind":"module"` onto every deployed config (via the
Pattern-A-aware `jq_module_write`). `module list`/`show` select on
`.kind=="module"` — the authoritative way to distinguish a deployed module from
the co-located state files (`zones.json`, `site.json`, `module-fields.json`,
`switch-configuration-*`, `cert-refids.json`). For configs not yet re-installed
(pre-tag) a **heuristic** fallback applies: any of `dependsOn`/`provides`/
`location` present. The heuristic intentionally does **not** require `vmname`, so
provider-only modules (e.g. `templates`: `provides:["nixos","debian"]`, no
vmid/vmname) are still enumerated (shown without vmid/node, not filtered out).

### `reconcile` vs `modify` — two distinct verbs

`reconcile` (`reconcile-module.sh`) is the **leaf converge** the
`site/environment reconcile --deep` cascade walks down to: it re-applies the
module's **current** config to its VM/service — re-running each dependency's
idempotent `install-service.sh` then the module's own `update.sh`/`install.sh` —
with **no snapshot, no pre/post tests, no 3-way merge, and no `updateTime`
bump**. `modify` (`update-module.sh`) *changes* the config via a release update
and does all of those. Because `reconcile` mutates no config and is idempotent,
re-running it (or a shared dependency) anytime is safe.

## Config state

- **`config/<module>.json`** — the effective module config (`<module>-<env>.json`
  for non-default environments). Fields are validated against
  `src/foundation/schemas/module-fields.json`, which also defines the `usedBy` grouping
  used for the canonical config-block ("Pattern A") form.
- **`config/<module>.json.orig`** — the pre-image used for a 3-way merge so
  operator customizations survive a release update.
- **Classification:** `tier` (`foundation` | `app`) and `source`
  (`official` | `community` | `private` | `local`) on each module JSON, with the
  rule `tier:foundation` ⇒ `source:official` (override `--allow-fork`).
- **Environment:** `--environment` resolves the VM name and the zone from the
  target environment's `network.zone` (`config/environments/<env>.json`); the
  chosen environment is persisted on the module JSON so update/delete resolve the
  right source.

## How it talks to the cluster

It does not drive a control-plane controller; it operates Proxmox directly over
SSH (`root@<node>.mgmt.internal`): `pvesh get /cluster/resources` to discover
VMs, `qm config` / `qm status`, `qm snapshot` / `delsnapshot` / `rollback` for
snapshots, and `qm guest cmd ... ping` for guest-agent health. NixOS modules are
rebuilt locally **on the VM** (not via `--target-host`) so the hardware config
matches, after waiting for cloud-init + passwordless sudo to be ready. Heavy `jq`
parsing throughout.

## Testing

`test.sh` — **fast (default), no provisioning, temp fixtures:** entry-script
smoke (parse + on-PATH); the `resolve_default_zone` helper (explicit zone0 wins,
then `site.json` fallback, then a single non-mgmt environment, then `mgmt`);
the environment/zone/vmname resolution; tier/source lint cases (foundation+official
pass, foundation+community fail, app+any pass, invalid enums fail, `--allow-fork`
override); the foundation→non-mgmt and foundation+community rejections; the
`--variant`→`--environment` alias; the delete-foundation `--force` gate; and
back-compat (a tier-less app module with no site/environments). It folds in the
standalone `test-validate-module-tier-source.sh` lint suite. The **deep**
(`TAPPAAS_TEST_DEEP=1`) path currently runs the same checks — no live provisioning
tier has been added yet.

## Pending / not yet implemented

- **`validate` is real (in the TS verb).** `module validate` ports the ADR-007b
  tier/source lint into `src/validate.ts` (foundation⇒official, enum checks,
  community warn, `--allow-fork`) and runs it over one or every deployed config.
  The legacy `validate-module.sh` bash entry remains a stub (kept for the old
  on-PATH name until retire). Still **not** ported: a JSON **schema** check
  against `module-fields.json` and dependsOn **reference-integrity** (do the
  named providers exist among deployed modules) — both flagged in
  `src/validate.ts` as future work.
- **`install.sh` does not build/link the TS bin yet** (next phase). Today it
  only relinks the `*.sh` scripts; the `module-manager` bin is built manually via
  `default.nix`.
- **No deep test tier yet.** `test.sh` does not add live cluster/VM provisioning
  probes under `TAPPAAS_TEST_DEEP=1`.
- **Operational guards** carried in the scripts (worth knowing): `snapshot-vm.sh`
  and `update-module.sh` refuse to snapshot the controller's own host (it would
  freeze its own root FS); `--reinstall` recovers from a failed partial install;
  `copy-update-json.sh` searches both `src/module-catalog.json` and the legacy
  `src/modules.json` for back-compat.
