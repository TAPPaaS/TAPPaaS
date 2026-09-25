# nextcloud-hpb — Installation

Primary audience: TAPPaaS admin.

## Prerequisites

1. `nextcloud` is installed (`nextcloud:fileservice`) — Talk registers this HPB as its
   signaling backend.
2. `coturn` is installed (`coturn:turn`) — the HPB and Janus use coturn's shared secret
   (`/home/tappaas/secrets/coturn.env` must exist on tappaas-cicd) and its `publicDomain`.

> To deviate from the defaults in `./nextcloud-hpb.json` (target node, storage, zone/VLAN,
> sizing), copy the json to `/home/tappaas/config` and edit it before installing. The
> pre-install hook copies Nextcloud's own `zone0` into this module automatically when it is
> unset; only set it yourself to place the HPB somewhere else.

## Install

    install-module.sh nextcloud-hpb

What happens, in order (`install-module.sh` runs the dependency services before this
module's own `install.sh`):

1. `cluster:vm` creates the VM; `coturn:turn` publishes the TURN secret and stamps its host
   into this module's deployed config; `nextcloud:fileservice` stamps Nextcloud's public URL;
   `network:proxy` publishes `wss://<proxyDomain>` and the internal split-horizon record;
   `network:rules` applies the firewall rules.
2. `templates:nixos` ships `nextcloud-hpb.nix` **and the companion JSON** (with the two
   stamped facts) to the VM and rebuilds it against the platform's nixpkgs pin. Nothing edits
   the deployed `.nix` by hand, and nothing runs `nixos-rebuild` outside this step.
3. `install.sh` checks the VM resolves and answers ssh (naming the zone and VLAN if not),
   syncs the TURN secret into the signaling server, publishes the HPB's own secret to the
   management plane, and runs Nextcloud's fileservice converge so the `hpb` connector writes
   `/etc/secrets/hpb.env` on the Nextcloud VM and registers `wss://<proxyDomain>` in Talk.

## Post-install

1. Public DNS record for the HPB proxy domain, so external clients (e.g. on 5G) can reach the
   signaling server:

       <proxyDomain> → <WAN IP>

   The internal split-horizon record is registered automatically by `network:proxy`.

2. Calls from outside the site are opt-in. Set
   `config["network:proxy"].proxyAllowedZones` to include `"internet"` on **both**
   `nextcloud-hpb.json` and `nextcloud.json`, then run `update-module.sh nextcloud-hpb` and
   `update-module.sh nextcloud`. Until this is set, the route accepts internal zones only —
   the public DNS record alone does not open it up.

Then make a **three-party test call** with one participant inside the site, one at home, and
one on mobile data: in `chrome://webrtc-internals` each client shows a single outbound video
stream (the SFU is in use), and the participant on mobile data connects, through coturn.

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
`trunks=`), or a zone with no DHCP. Set `zone0` to Nextcloud's zone (Prerequisites),
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
`janus.service` failed: `sudo journalctl -u janus -n 50` on the VM shows why.

**Talk clients outside the site can't reach the HPB even though DNS resolves**
Public access is opt-in (Post-install, step 2) — check `proxyAllowedZones` on both
`nextcloud-hpb` and `nextcloud`.

For upgrades see [UPGRADE.md](./UPGRADE.md).
