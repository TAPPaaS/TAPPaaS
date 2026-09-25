# coturn — Upgrade Guide

## Routine upgrade

```bash
cd /home/tappaas/TAPPaaS/src/apps/coturn
update-module.sh coturn
```

`update-module.sh` runs the safe pipeline: snapshot → pre-test → `nixos-rebuild switch` →
`update.sh` → post-test → auto-rollback on failure. coturn is the `pkgs.coturn` package
pinned via nixpkgs. `update.sh` itself only re-persists `publicDomain` and its split-horizon
record on the site resolver; the NixOS/package update runs before it, via the
`templates:nixos` dependency updater.

## Connector and consumer state after upgrade

The Talk TURN connector (sharing `COTURN_SECRET` with Nextcloud) is owned by Nextcloud
(triggered by `config["nextcloud:fileservice"].connector = "talk"`). No
connector action runs here on upgrade.

Each consumer's `turnHost`/`turnHostInternal` and its entry in coturn's allow-list
(`/var/lib/coturn/allowed-peers`) are refreshed when *that consumer* updates (for example
`update-module.sh nextcloud-hpb`), not when coturn itself updates. If a consumer's internal
IP changes, updating coturn alone does not re-converge it — update the consumer.

## Rollback / verify

```bash
snapshot-vm.sh coturn --restore 1     # manual rollback
./test.sh coturn                    # verify: coturn.service active, TURN port 3478 reachable
```

---

## Maintainer: bumping the pin

coturn tracks `pkgs.coturn` (nixpkgs) via the `versions` block in `coturn.nix`. To move it,
bump the pinned nixpkgs rev (engine-side) and update `appVersion` in `coturn.json` to match.
Test on a test environment first.
