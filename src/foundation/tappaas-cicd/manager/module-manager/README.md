# manager/module-manager

Module lifecycle manager (install / update / delete / test of TAPPaaS modules).

See `docs/design/ADR-007-implementation.md` — P4 (layout) and **P5** (module
tier/source classification + environment-aware deployment).

## Scripts

- `install-module.sh` — install a module. ADR-007 P5: `--environment <name>`
  (deprecated alias `--variant`), tier/source lint at Step 0, computed VM name
  (`<module>` in the default env, else `<module>-<env>`), zone0 from the target
  environment's `network.zone`, foundation-tier constraints (mgmt-only,
  single-instance).
- `update-module.sh` — update a module. `--environment <name>` resolves the
  installed config name.
- `delete-module.sh` — delete a module. `--environment <name>`; tier:foundation
  modules require `--force`.
- `copy-update-json.sh` — copy/normalize a module JSON into `config/`. Now
  understands `--environment` / `--default-environment` (registry-free P5 path,
  distinct from the legacy `--variant` registry path).
- `validate-module-tier-source.sh` — ADR-007b tier/source lint. `tier:foundation`
  requires `source:official` (override with `--allow-fork`); rejects invalid
  tier/source enums; warns on `source:community`. Used standalone and by install.
- `test-module.sh`, `snapshot-vm.sh`, `module-format.sh` — supporting tools.

## Tests

- `test.sh` — FAST offline suite (temp fixtures, no provisioning): entry-script
  smoke; `resolve_default_zone` (S6 N6); P5 tier/source lint; environment + zone
  + vmname resolution; foundation→non-mgmt rejection; foundation+community lint
  rejection; `--variant`→`--environment` alias; delete foundation `--force` gate;
  back-compat (tier-less/app module, no site/environments). Folds in the
  standalone lint suite.
- `test-validate-module-tier-source.sh` — standalone lint test suite.
