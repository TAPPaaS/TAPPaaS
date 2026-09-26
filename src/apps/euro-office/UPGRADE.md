# euro-office — Upgrade Guide

Operational upgrade guide for **operators**. To change the pinned document-server image, see
"Maintainer: bumping the pinned image" at the bottom.

## Routine upgrade

```bash
cd /home/tappaas/TAPPaaS/src/apps/euro-office
update-module.sh euro-office
```

`update-module.sh` runs the safe-upgrade pipeline: snapshot -> pre-test -> `nixos-rebuild switch`
(pulls the pinned container image) -> `update.sh` -> post-test -> auto-rollback on failure.

Euro-Office runs as a single pinned Podman container
(`ghcr.io/euro-office/documentserver:<tag>`), so an app upgrade is an image-tag bump — no
in-place database migration in this module.

## Connector after upgrade

The euro-office <-> Nextcloud connector is owned by the `nextcloud` module. No separate step is
needed: every install or update of this module runs the `nextcloud` module's
`services/fileservice/update-service.sh`, which re-reads the JWT and re-applies the wiring
(`config["nextcloud:fileservice"].connector = "onlyoffice"`). After rotating the JWT secret on
this VM, run `update-module.sh euro-office` so Nextcloud picks it up.

**Two different things are called `onlyoffice`.** Connector v11 renamed the **Nextcloud app ID**
from `onlyoffice` to `eurooffice`; that change reaches a site when Nextcloud is updated, and the
old app is disabled then. The **TAPPaaS connector label** `onlyoffice`
(`config["nextcloud:fileservice"].connector` in `euro-office.json`) did not change and needs no
update. The connector requires Nextcloud >= 33.

Update Nextcloud before euro-office (the scheduled sweep does). Until Nextcloud runs v11,
euro-office's checks say so and leave the working v10 wiring alone: "Nextcloud still runs the
pre-v11 connector app 'onlyoffice': update Nextcloud first" (#743).

## Rollback

```bash
snapshot-vm.sh euro-office --restore 1
```

A failed `update-module.sh` also auto-restores the pre-update snapshot.

## Verify

```bash
cd /home/tappaas/TAPPaaS/src/apps/euro-office
./test.sh euro-office
```

Expected: container running, `/healthcheck` 200, `/web-apps/.../api.js` 200, JWT secret present.

To confirm Nextcloud itself sees the document server, run on the Nextcloud VM (needs a TTY):

```bash
ssh -t tappaas@nextcloud.<zone>.internal "sudo nextcloud-occ --no-ansi eurooffice:documentserver --check"
```

"is successfully connected" means the connector is working.

---

## Maintainer: bumping the pinned image

The document-server image is pinned in `euro-office.nix`, and mirrored in `update.sh`:

```nix
image = "ghcr.io/euro-office/documentserver:v9.3.1";   # immutable semver tag — never :latest/:nightly
```

1. Pick a new **immutable** semver tag (verify it runs: `/healthcheck`, `/web-apps/.../api.js`).
2. Update `image =` in `euro-office.nix`, the matching `CONTAINER_IMAGE` in `update.sh`, and
   `appVersion` in `euro-office.json` — keep all three in sync.
3. If the new server needs a newer connector, that pin lives in the `nextcloud` module
   (`eurooffice-nextcloud.nix`) — bump it there separately.
4. Test on a test environment before production.
