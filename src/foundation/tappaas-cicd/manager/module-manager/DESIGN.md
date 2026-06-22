# module-manager — design notes

## Language and build

- **Language:** Bash throughout.
- **`install.sh`** links every `*.sh` (except the verb scripts) into `~/bin`
  (`${TAPPAAS_BIN:-/home/tappaas/bin}`): `install-module.sh`,
  `update-module.sh`, `delete-module.sh`, `copy-update-json.sh`, `snapshot-vm.sh`,
  `module-format.sh`, `validate-module-tier-source.sh`,
  `test-validate-module-tier-source.sh` (and `test-module.sh`). Nothing to
  compile.
- **`update.sh`** re-runs `install.sh` (idempotent relink).

## Config state

- **`config/<module>.json`** — the effective module config (`<module>-<env>.json`
  for non-default environments). Fields are validated against
  `src/foundation/module-fields.json`, which also defines the `usedBy` grouping
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

- **`validate-module.sh` is a stub.** This is the manager's `validate` operation
  (script-manager `validate-<manager>.sh` convention; renamed from the former
  `validate.sh` stub). It prints `validate: ok (stub)`; the real validator —
  which will lint every module config via `validate-module-tier-source.sh` (the
  per-file tier/source lint) — has not been filled in yet.
- **No deep test tier yet.** `test.sh` does not add live cluster/VM provisioning
  probes under `TAPPAAS_TEST_DEEP=1`.
- **Operational guards** carried in the scripts (worth knowing): `snapshot-vm.sh`
  and `update-module.sh` refuse to snapshot the controller's own host (it would
  freeze its own root FS); `--reinstall` recovers from a failed partial install;
  `copy-update-json.sh` searches both `src/module-catalog.json` and the legacy
  `src/modules.json` for back-compat.
