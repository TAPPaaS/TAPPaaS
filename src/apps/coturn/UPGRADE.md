# coturn — Upgrade Guide

## Routine upgrade

```bash
cd /home/tappaas/TAPPaaS/src/apps/coturn
update-module.sh coturn
```

`update-module.sh` runs the safe pipeline: snapshot → pre-test → `nixos-rebuild switch` → `update.sh`
→ post-test → auto-rollback on failure. coturn is the `pkgs.coturn` package pinned via nixpkgs.

## Connector after upgrade

The Talk TURN connector (sharing `COTURN_SECRET` with Nextcloud) is owned by Nextcloud (ADR-COM-0002,
triggered by `config["nextcloud:nextcloud"].connector = "talk"`). No connector action here on upgrade.

## Rollback / verify

```bash
snapshot-vm.sh coturn --restore     # manual rollback
./test.sh coturn                    # verify: coturn.service active, TURN port 3478 reachable
```

---

## Maintainer: bumping the pin

coturn tracks `pkgs.coturn` (nixpkgs) via the `versions` block in `coturn.nix`. To move it, bump the
pinned nixpkgs rev (engine-side) and update `appVersion` in `coturn.json` to match. Test on a variant first.
