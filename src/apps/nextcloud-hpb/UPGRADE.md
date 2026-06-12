# nextcloud-hpb — Upgrade Guide

## Routine upgrade

```bash
cd /home/tappaas/TAPPaaS/src/apps/nextcloud-hpb
update-module.sh nextcloud-hpb
```

`update-module.sh` runs the safe pipeline: snapshot → pre-test → `nixos-rebuild switch` → `update.sh`
→ post-test → auto-rollback. The HPB is `services.nextcloud-spreed-signaling` (Go, from nixpkgs) + NATS.

## Connector after upgrade

The Talk HPB signaling backend (sharing `HPB_SECRET` with Nextcloud, `wss://<domain>/spreed`) is owned
by Nextcloud (ADR-COM-0002, `config["nextcloud:fileservice"].connector = "hpb"`). `dependsOn coturn:turn`
for the TURN secret. No connector action here on upgrade.

## Rollback / verify

```bash
snapshot-vm.sh nextcloud-hpb --restore
./test.sh nextcloud-hpb            # verify: nextcloud-spreed-signaling active, wss reachable
```

---

## Maintainer: bumping the pin

The signaling backend tracks `nextcloud-spreed-signaling` (nixpkgs). To move it, bump the pinned
nixpkgs rev (engine-side) and set `appVersion` in `nextcloud-hpb.json` to the new signaling version.
Test on a variant first.
