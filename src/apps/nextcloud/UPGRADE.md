# Nextcloud — Upgrade Guide

Operational upgrade guide for **operators**. To change the pinned Nextcloud version itself, see
"Maintainer: bumping the pin" at the bottom.

## Routine upgrade

```bash
cd /home/tappaas/TAPPaaS/src/apps/nextcloud
update-module.sh nextcloud
```

`update-module.sh` runs the full safe-upgrade pipeline:

1. **Snapshot** the VM (pre-update rollback point) via `snapshot-vm.sh`.
2. **Pre-update test** (`test.sh` + dependency `test-service.sh`).
3. **Rebuild** via the `templates:nixos` layer (`nixos-rebuild switch` with the pinned nixpkgs rev).
4. `update.sh` (module-specific post-rebuild steps).
5. **Post-update test**.
6. **Auto-rollback** to the pre-update snapshot if any step fails.

Nextcloud's own database/app migration (`occ upgrade`) is run automatically by the
`services.nextcloud` NixOS module on activation — no manual `occ upgrade` needed.

## Nextcloud major-version upgrades

- Majors must be **sequential** — Nextcloud refuses to skip (33 → 34 → 35, never 33 → 35).
- The pinned major lives in `nextcloud.nix` (`ncMajor`); a maintainer bumps it (see below). Once
  the new package is deployed, `services.nextcloud` performs the schema upgrade automatically.
- For a two-major jump, deploy each major in turn (bump → `update-module.sh` → repeat).

## PostgreSQL major upgrades

The DB is pinned to `postgresql_15` (`versions.postgresPkg`). If a future release bumps the
PostgreSQL major, NixOS initialises a **fresh** data directory and the old data must be migrated —
`update.sh` should handle the dump/restore (mirror the openwebui pattern). Until then, PostgreSQL
stays on 15, so no DB migration is required for app-only upgrades.

## Rollback

A failed `update-module.sh` auto-restores the pre-update snapshot. To roll back manually:

```bash
snapshot-vm.sh nextcloud --restore
```

## Verify

```bash
cd /home/tappaas/TAPPaaS/src/apps/nextcloud
./test.sh nextcloud
```

Expected: `installed: true`, HTTP 200/302, PostgreSQL + Redis active, backup timers active.

---

## Maintainer: bumping the pinned version

Edit the single `versions` block at the top of `nextcloud.nix`:

```nix
ncMajor = 35;   # drives both the package and its app-set
```

`ncMajor` resolves `pkgs."nextcloud${ncMajor}"` and `pkgs."nextcloud${ncMajor}Packages".apps`, so the
package and all bundled apps move together. Also:

1. Bump `appVersion` in `nextcloud.json` to match (e.g. `"36"`).
2. Ensure the **nixpkgs template rev** (pinned engine-side by `update-os.sh`) carries the new major.
3. If a newer **eurooffice connector** is required, run `./update-eurooffice-app.sh` (recomputes the
   `rev` + npm/composer hashes in `eurooffice-nextcloud.nix`).
4. Test on a variant (`install-module.sh nextcloud --variant test --vmid <free>`) before production.

## 33 → 35 (2026-09-24): a clean install, not an upgrade

The Qualiware site went from 33 straight to 35 by reinstalling the module: its data was disposable,
so no `occ upgrade` ran and 34 was skipped. A site that must keep its data still has to step through
every major (33 → 34 → 35), because Nextcloud refuses to skip one.

What 35 changed in this module:

- **App-store pins.** nixpkgs' `nextcloud35Packages` was last regenerated before these apps released
  35 support, so `storeApps` in `nextcloud.nix` fetches them from the app store by hash:
  `news` 29.0.0-beta.1 (a pre-release), `previewgenerator` 5.15.0, `uppush` 2.6.0. Drop each pin once
  `nextcloud35Packages.apps` carries it. Keep `unpack = true`: it hashes the unpacked tree, so a
  re-generated codeberg `/archive` tarball cannot break the hash.
- **`quota_warning` dropped.** It has no release for 35 yet (1.24.0 declares `<35`). Re-add it to
  `extraApps` once one exists.
- **Connector v11.** v10 declared Nextcloud 33 only. v11 declares 33–35, **renames the app ID from
  `onlyoffice` to `eurooffice`** (occ: `eurooffice:documentserver`, system config key `eurooffice`),
  and needs `firebase/php-jwt` 7. The settings keys are unchanged. The TAPPaaS connector label
  `connector: "onlyoffice"` and `/etc/secrets/onlyoffice.env` keep their names.

