# Nextcloud — Upgrade Guide

Operational upgrade guide for **operators**. To change the pinned Nextcloud version itself, see
"Maintainer: bumping the pin" at the bottom.

## Routine upgrade

    update-module.sh nextcloud

`update-module.sh` runs the full safe-upgrade pipeline: snapshot the VM, pre-update test,
rebuild via `templates:nixos` against the pinned nixpkgs revision, run this module's
`update.sh`, post-update test, and auto-rollback to the pre-update snapshot if any step fails.

Nextcloud's own database/app migration (`occ upgrade`) runs automatically on activation by the
`services.nextcloud` NixOS module — no manual `occ upgrade` needed.

## Nextcloud major-version upgrades

- Majors must be sequential — Nextcloud refuses to skip one (33 → 34 → 35, never 33 → 35). A
  site that keeps its data must step through every major in turn.
- The pinned major lives in `nextcloud.nix` (`ncMajor`); a maintainer bumps it (see below).
  Once the new package is deployed, `services.nextcloud` performs the schema upgrade
  automatically.
- For a multi-major jump, deploy each major in turn: bump the pin, run
  `update-module.sh nextcloud`, repeat.

## PostgreSQL major upgrades

The database is pinned to `postgresql_15` (`versions.postgresPkg`). If a future release bumps
the PostgreSQL major, NixOS initialises a fresh data directory and the old data must be
migrated by hand as part of `update.sh`. Until then, PostgreSQL stays on 15 and no DB migration
is needed for app-only upgrades.

## Rollback

A failed `update-module.sh` auto-restores the pre-update snapshot. To roll back manually:

    snapshot-vm.sh nextcloud --restore 1

## Verify

    test-module.sh nextcloud

Expected: `installed: true`, HTTP 200/302, PostgreSQL and Redis active, backup timers active.

---

## Maintainer: bumping the pinned version

Edit the single `versions` block at the top of `nextcloud.nix`:

```nix
ncMajor = 35;   # drives both the package and its app-set
```

`ncMajor` resolves `pkgs."nextcloud${ncMajor}"` and `pkgs."nextcloud${ncMajor}Packages".apps`,
so the package and all bundled apps move together. Also:

1. Bump `appVersion` in `nextcloud.json` to match.
2. Ensure the nixpkgs template revision (pinned engine-side, in `update-os.sh`) carries the new
   major.
3. If a newer euro-office connector is required, run `./update-eurooffice-app.sh`. It refreshes
   the source and npm hashes in `eurooffice-nextcloud.nix`; check the connector's `composer.lock`
   by hand and update the vendored `firebase/php-jwt` pin to match, then build it once.
4. Test on a separate environment (`install-module.sh nextcloud --environment <test-env>`) before
   production.

## What moving to a new major can change — lessons from 35

- **App-store pins.** When nixpkgs' `nextcloud<N>Packages` set is regenerated before an app has
  released support for the new major, that app has to be pinned from the Nextcloud app store by
  hash instead (`storeApps` in `nextcloud.nix`). For 35 this affected `news` (pinned to a
  pre-release, 29.0.0-beta.1), `previewgenerator` (5.15.0) and `uppush` (2.6.0). Drop each pin
  once nixpkgs carries a compatible release. Keep `unpack = true` on a store pin: it hashes the
  unpacked tree, so a re-generated upstream archive tarball cannot break the hash.
- **An app can drop out entirely.** `quota_warning` has no release for 35 yet, so it is not in
  this module's app set. Re-add it once one exists.
- **The euro-office connector can rename its app ID.** Connector v11 (required for 35) renamed
  the Nextcloud app ID from `onlyoffice` to `eurooffice` (`occ eurooffice:documentserver`,
  system config key `eurooffice`); the settings keys themselves did not change. The TAPPaaS
  connector label (`connector: "onlyoffice"`) and the `/etc/secrets/onlyoffice.env` filename
  keep their old names on purpose, for backward compatibility.
- **A migration can need a local patch.** uppush 2.6.0's first database migration fails on 35
  (upstream issue #124, open); this module carries a small patch until upstream fixes it.
- **notify_push's app and daemon must move together.** nixpkgs' notify_push package (1.3.3)
  does not support 35, so both the app and the daemon are pinned here to 1.4.1.
