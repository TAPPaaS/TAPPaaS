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

- Majors must be sequential — Nextcloud refuses to skip one (33 → 34 → 35, never 33 → 35).
- **The module steps for you, one major per update.** `nc-major.nix` builds
  `min(targetMajor, installed + 1)` from the installed major that `build-facts.sh` reads from
  the guest's `config.php` before every build (only the major leaves the guest; the build runs
  on the mothership, #774/#797). A config.php without a version, or data without a config.php,
  stops the update before it switches — it is never taken for a fresh install. A site on 33 goes
  to 34 at its next update and to 35 at the one after, keeping its data; the scheduled sweep
  does both, a night apart. To take both steps now, run `update-module.sh nextcloud` twice.
- An intermediate step uses nixpkgs' own app set for that major; the release's app-store pins
  and patches apply from `targetMajor` on.
- A fresh install goes straight to `targetMajor`.
- The build refuses, before anything changes, a site whose next major this nixpkgs does not
  carry (reinstall it, or restore it into a release that does) and an installed major newer
  than the release (Nextcloud cannot go back).

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

Expected: `installed: true`, HTTP 200/302, PostgreSQL and Redis active, no in-guest backup left.

---

## Maintainer: bumping the pinned version

Edit the single `versions` block at the top of `nextcloud.nix`:

```nix
targetMajor = 35;   # the release's Nextcloud; each build installs min(this, installed + 1)
```

The installed major (`ncMajor`, from `nc-major.nix`) resolves `pkgs."nextcloud${ncMajor}"` and
`pkgs."nextcloud${ncMajor}Packages".apps`, so the package and all bundled apps move together.
The pinned nixpkgs must carry every major between the oldest supported site and the target,
or those sites are refused. Also:

1. Bump `appVersion` in `nextcloud.json` to match.
2. Ensure the nixpkgs template revision (pinned engine-side, in `update-os.sh`) carries the new
   major.
3. If a newer euro-office connector is required, run `./update-eurooffice-app.sh`. It refreshes
   the source and npm hashes in `eurooffice-nextcloud.nix`; update the submodule pins and the
   `firebase/php-jwt` pin (from the tag's `composer.lock`) by hand, then build it once.
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

## What an existing site gets with 35

The sweep upgrades an existing site in place (33 → 34 → 35, above). On the way it also changes:

- **User IDs are kept.** A new install names Authentik users by username (`--unique-uid=0`); a
  site that already has the Authentik provider keeps what it has — hashed IDs, unless it was set
  otherwise. Changing it later would give every user a new, empty account.
- **Admin rights come from Authentik.** Members of the `nextcloud-admins` Authentik group become
  Nextcloud admins at login. A user made admin by hand in Nextcloud and not in that group may
  lose admin at their next login: add them to `nextcloud-admins` first.
- **The login page goes straight to Authentik.** Local accounts still log in at
  `/login?direct=1` (bookmark it for the local `admin`).
- **The euro-office connector becomes `eurooffice`.** The old `onlyoffice` app is disabled and
  its settings are rebuilt under the new ID from `/etc/secrets/onlyoffice.env`; connector
  settings changed by hand in the Nextcloud UI are not carried over.
- **Clients:** nothing to do while user IDs are kept. On a fresh install (new IDs), every app on
  every device must remove and re-add its account, or failed logins trip brute-force
  throttling (`occ security:bruteforce:reset <ip>` clears it).
