# Euro-Office — Upgrade Guide

Operational upgrade guide for **operators**. To change the pinned document-server image, see
"Maintainer: bumping the pin" at the bottom.

## Routine upgrade

```bash
cd /home/tappaas/TAPPaaS/src/apps/euro-office
update-module.sh euro-office
```

`update-module.sh` runs the safe-upgrade pipeline: snapshot → pre-test → `nixos-rebuild switch`
(pulls the pinned container image) → `update.sh` → post-test → auto-rollback on failure.

Euro-Office runs as a **single pinned Podman container** (`ghcr.io/euro-office/documentserver:<tag>`),
so an app upgrade is an image-tag bump — no in-place database migration in this module.

## Connector after upgrade

The euro-office ↔ Nextcloud connector is owned by Nextcloud (ADR-COM-0002). No connector action is
needed here on upgrade: Nextcloud's `services/nextcloud/install-service.sh` re-wires it from this
module's manifest (`config["nextcloud:fileservice"].connector = "onlyoffice"`) and JWT. If the JWT
secret rotates, re-run the Nextcloud module's update so it re-reads it.

## Rollback

A failed `update-module.sh` auto-restores the pre-update snapshot, or manually:

```bash
snapshot-vm.sh euro-office --restore
```

## Verify

```bash
cd /home/tappaas/TAPPaaS/src/apps/euro-office
./test.sh euro-office
```

Expected: container running, `/healthcheck` 200, `/web-apps/.../api.js` 200, JWT secret present.

---

## Maintainer: bumping the pinned image

The document-server image is pinned in `euro-office.nix`:

```nix
image = "ghcr.io/euro-office/documentserver:v9.3.1";   # immutable semver tag — never :latest/:nightly
```

1. Pick a new **immutable** semver tag (verify it runs: `/healthcheck`, `/web-apps/.../api.js`).
2. Update `image =` in `euro-office.nix` and `appVersion` in `euro-office.json` to match.
3. If the connector app version must move with it, bump it on the Nextcloud side
   (`update-eurooffice-app.sh` in the nextcloud module).
4. Test on a variant before production.
