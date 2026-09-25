# nextcloud-hpb — Installation

Primary audience: TAPPaaS admin.

## Prerequisites

1. `nextcloud` is installed (`nextcloud:fileservice`) — Talk registers this HPB as its
   signaling backend.
2. `coturn` is installed (`coturn:turn`) — the HPB and Janus use coturn's shared secret
   (`/home/tappaas/secrets/coturn.env` must exist on tappaas-cicd) and its `publicDomain`.
3. **Zone.** Copy `./nextcloud-hpb.json` to `/home/tappaas/config/` and set `zone0` to the
   zone Nextcloud is in. The module ships without a zone; the engine's
   default (the site's service zone) is only right if that zone actually carries guests on
   the HPB's node. Co-location also makes the HPB ↔ Nextcloud path need no extra egress.

> Other defaults to deviate from (target node, storage, sizing): same copy-and-edit.

## Install

    install-module.sh nextcloud-hpb

What happens, in order (`install-module.sh` Step 5 runs the dependency services first):

1. `cluster:vm` creates the VM; `coturn:turn` publishes the TURN secret and stamps
   `turnHost` into this module's deployed config; `nextcloud:fileservice` stamps
   `nextcloudPublicUrl`; `network:proxy` publishes `wss://<proxyDomain>`
   and the split-horizon record; `network:rules` applies the firewall rules.
2. `templates:nixos` ships `nextcloud-hpb.nix` **and the companion JSON** (with the two
   stamped facts) to the VM and rebuilds it against the platform's nixpkgs pin. The
   signaling server's backend allow-list and TURN servers, and Janus's TURN settings, are
   read from that JSON — nothing edits the deployed `.nix`, nothing runs `nixos-rebuild`
   by hand.
3. `install.sh` checks the VM resolves and answers ssh (a clear message names the zone and
   VLAN if not), syncs `COTURN_SECRET` into the signaling server, publishes `HPB_SECRET` to
   the management plane, and runs Nextcloud's fileservice converge so the `hpb` connector
   writes `/etc/secrets/hpb.env` on the Nextcloud VM and registers
   `wss://<proxyDomain>` in Talk.

## Post-install

One manual step — public DNS only. Create a public DNS record for the HPB proxy domain so
external clients (e.g. on 5G) can reach the signaling server:

    <proxyDomain> → <WAN IP>

The internal split-horizon record is registered by `network:proxy`.

Then make a **three-party test call** with one participant inside the site, one at
home and one on mobile data: in `chrome://webrtc-internals` each client shows a single
outbound video stream (the SFU is in use), and `journalctl -u coturn` on the coturn VM shows
allocations for the participants Janus cannot reach directly.

## Verification

    test-module.sh nextcloud-hpb

| Check | Expected |
|-------|----------|
| `nextcloud-spreed-signaling` service | active |
| Secrets in `/var/lib/nextcloud-hpb/secrets/` | hpb-secret, session keys, internalsecret, turn-secret, turn-apikey |
| Port 8080 from tappaas-cicd | open |
| `http://<vm>:8080/api/v1/welcome` | JSON naming `nextcloud-spreed-signaling` |
| `turn-secret` | ≥ 16 bytes (synced from coturn) |
| Nextcloud Talk `signaling_servers` | non-empty and contains the HPB proxy domain |
| Nextcloud Talk (spreed) app | enabled |
| `janus.service` | active; WebSocket API on 127.0.0.1:8188 only |
| Signaling ↔ Janus | journal shows the MCU connected |
| Companion JSON facts | `turnHost` and `nextcloudPublicUrl` present in `/etc/nixos/nextcloud-hpb.json` |

## Troubleshooting

**`install.sh` dies with "does not resolve — the VM has no DHCP lease in zone …"**
The VM is in a zone whose VLAN does not reach its node (switch trunk / firewall VM
`trunks=`), or a zone with no DHCP. Set `zone0` to Nextcloud's zone (Prerequisites 3),
`delete-module.sh nextcloud-hpb`, install again.

**Talk does not use the HPB (still PHP signaling)**
`signaling_servers` is empty: the `hpb` connector has not run with the secret present.
`update-module.sh nextcloud-hpb` (or `update-module.sh nextcloud`) re-converges it; it needs
`HPB_SECRET` in `/home/tappaas/secrets/nextcloud-hpb.env`. Inspect the signaling server:

    ssh tappaas@nextcloud-hpb.<zone>.internal \
      "sudo systemctl status nextcloud-spreed-signaling janus; \
       sudo journalctl -u nextcloud-spreed-signaling -n 30"

**Talk rejects the backend with `invalid_backend`**
The backend allow-list must be Nextcloud's PUBLIC base URL. Check `nextcloudPublicUrl` in
`/etc/nixos/nextcloud-hpb.json` on the VM (Test 11); if empty, `nextcloud:fileservice` did
not stamp it before the rebuild — `update-module.sh nextcloud-hpb` stamps and rebuilds.

**Group calls still behave like a mesh / Janus down**
`janus.service` failed: `sudo journalctl -u janus -n 50` on the VM. Usual causes: the plugin
or transport folder path of the `janus-gateway` package changed (see the `janus.jcfg`
rendering in `nextcloud-hpb.nix`), or `turn-apikey` is unreadable.

For upgrades see [UPGRADE.md](./UPGRADE.md).
