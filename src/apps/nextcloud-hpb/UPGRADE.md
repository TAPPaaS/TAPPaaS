# nextcloud-hpb — Upgrade Guide

## Routine upgrade

```bash
cd /home/tappaas/TAPPaaS/src/apps/nextcloud-hpb
update-module.sh nextcloud-hpb
```

`update-module.sh` runs the safe pipeline: snapshot → pre-test → `nixos-rebuild switch` →
`update.sh` → post-test → auto-rollback. The HPB is `services.nextcloud-spreed-signaling`
(Go, from nixpkgs) + NATS, plus Janus (`pkgs.janus-gateway`). Neither package carries a
version pin in this module — both move with whatever nixpkgs revision the platform pin
resolves to at rebuild time.

## Connector after upgrade

The Talk HPB signaling backend (sharing `HPB_SECRET` with Nextcloud, `wss://<domain>/spreed`)
is owned by Nextcloud (`config["nextcloud:fileservice"].connector = "hpb"`).
`dependsOn coturn:turn` supplies the TURN secret. No connector action here on upgrade.

## Known issues

Talk's admin page may warn that this signaling server lacks the feature `changed-users`. It
is optional — calls still work. The warning goes away once a signaling-server release ships
that feature; there is nothing to fix on this module's side.

## Rollback / verify

```bash
snapshot-vm.sh nextcloud-hpb --restore 1
./test.sh nextcloud-hpb            # verify: nextcloud-spreed-signaling active, wss reachable
```

---

## Maintainer: bumping the pin

Neither the signaling server nor Janus has a package-specific pin in this module — both track
whatever nixpkgs revision the platform pin resolves to. `appVersion` in `nextcloud-hpb.json`
is a manually-maintained label, not something the build wires in automatically: after a
platform nixpkgs bump, update it to record the signaling-server version actually deployed,
and test on a test environment first.
