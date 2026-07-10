# nextcloud-hpb — Installation

Primary audience: TAPPaaS admin.

## Prerequisites

1. `nextcloud` is installed (`nextcloud:fileservice`) — Talk registers this HPB as its
   signaling backend.
2. `coturn` is installed (`coturn:turn`) — HPB distributes TURN credentials from coturn's
   shared secret (`/home/tappaas/secrets/coturn.env` must exist on tappaas-cicd).

> To deviate from the defaults in `./nextcloud-hpb.json` (target node, storage,
> zone/VLAN, sizing), copy the json to `/home/tappaas/config` and edit it
> before installing.

## Install

    install-module.sh nextcloud-hpb

The installer automates all wiring: it saves the auto-generated `HPB_SECRET` to the management
plane, syncs the coturn TURN secret to the HPB VM, points the signaling backend allow-list and
TURN advertise host at the real deployment (via `nixos-rebuild`), writes `/etc/secrets/hpb.env`
to the Nextcloud VM, registers the signaling backend in Talk, and adds the internal
split-horizon DNS override in OPNsense.

## Post-install

One manual step — public DNS only. Create a public DNS record for the HPB proxy domain so
external clients (e.g. on 5G) can reach the signaling server:

    <proxyDomain> → <WAN IP>

The internal DNS override is already added to OPNsense by the installer.

## Verification

    test-module.sh nextcloud-hpb

| Check | Expected |
|-------|----------|
| `nextcloud-spreed-signaling` service | active |
| Secrets in `/var/lib/nextcloud-hpb/secrets/` | all six files present (hpb-secret, session keys, internalsecret, turn-secret, turn-apikey) |
| Port 8080 from tappaas-cicd | open |
| `http://<vm>:8080/api/v1/welcome` | JSON naming `nextcloud-spreed-signaling` |
| `turn-secret` | ≥ 16 bytes (synced from coturn) |
| Nextcloud Talk `signaling_servers` config | contains the HPB proxy domain |
| Nextcloud Talk (spreed) app | enabled |

## Troubleshooting

**`install-module.sh` exits with a dependency error**
`nextcloud` or `coturn` is not installed. Install both first, then retry.

**Talk does not use the HPB (still PHP signaling)**
The shared secret is not on the Nextcloud VM, or the backend is not registered. Inspect the
signaling server:

    ssh tappaas@nextcloud-hpb.srv.internal \
      "sudo systemctl status nextcloud-spreed-signaling; \
       sudo journalctl -u nextcloud-spreed-signaling -n 30"

Confirm `HPB_SECRET` in `/etc/secrets/hpb.env` on the Nextcloud VM matches
`/var/lib/nextcloud-hpb/secrets/hpb-secret` on the HPB VM, then restart
`nextcloud-configure-hpb.service` on the Nextcloud VM (or re-run the install).

**Talk rejects the backend with `invalid_backend`**
The signaling backend allow-list must contain Nextcloud's PUBLIC base URL. If the installer
could not determine Nextcloud's proxy domain, the allow-list stays at the nix placeholder.
Check `urls = [ ... ]` in `/etc/nixos/nextcloud-hpb.nix` on the HPB VM — see DESIGN.md for how
this is wired.

For upgrades see [UPGRADE.md](./UPGRADE.md).
