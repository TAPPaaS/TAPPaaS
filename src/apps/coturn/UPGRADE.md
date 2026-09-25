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

## What an existing site gets with the Talk stack (#723, #735)

- **coturn opens its own WAN port-forwards.** Installing or updating coturn now declares, through
  `network:nat`, forwards for 3478 TCP/UDP and the relay range. This used to be a manual step on
  the firewall; the internet can reach those ports once coturn is installed.
- **The relay range shrinks to UDP 49152–50151** (1,000 ports, was 49152–65535). Each relayed
  media stream holds a port, which caps concurrent relayed calls; widen `min-port`/`max-port`
  and the forward together if a site needs more.
- **One-time cleanup on a site that ran an earlier build of #723:** the 3-way merge keeps a
  field the release moved at its old value, so the relay range would stay at 49152–65535.
  Delete the top-level `natRules` and `config["network:rules"].ports` from
  `config/coturn.json` once, then run `update-module.sh coturn`.
- **Relayed media is UDP only** (`no-tcp-relay`). coturn may relay to the HPB's private address
  (its `allowed-peers` entry); TCP relaying would have opened the HPB's TCP ports to any TURN
  user, including guests of public Talk conversations. Deleting a consumer now removes its
  entry too.
- **`home` may open pinholes into `dmz`** (`zones.json`), for Talk clients at home reaching
  coturn; this applies to every module in `dmz`, not only coturn.

## Rollback / verify

```bash
snapshot-vm.sh coturn --restore 1     # manual rollback
./test.sh coturn                    # verify: coturn.service active, TURN port 3478 reachable, UDP-only relay
```

---

## Maintainer: bumping the pin

coturn tracks `pkgs.coturn` (nixpkgs) via the `versions` block in `coturn.nix`. To move it,
bump the pinned nixpkgs rev (engine-side) and update `appVersion` in `coturn.json` to match.
Test on a test environment first.
