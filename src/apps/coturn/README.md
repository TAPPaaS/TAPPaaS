# coturn

Primary audience: Nextcloud Talk users (audio/video calls); TAPPaaS admin.

TURN/STUN relay for Nextcloud Talk — relays WebRTC audio/video between peers behind
different NATs, so calls connect even when a direct peer-to-peer path fails. With the
`nextcloud-hpb` module's Janus SFU it also carries the legs between Janus and every
participant Janus cannot reach directly.

## What you get

| Capability | Access from | How |
|------------|-------------|-----|
| TURN/STUN relay for Talk calls | Talk clients anywhere | `turn.<domain>:3478` UDP/TCP — one name in every horizon (`publicDomain`) |
| WAN port-forwards | Internet | Declared in `coturn.json` (`network:nat`): 3478 TCP/UDP + 49152-50151 UDP |
| Relay for internal clients | The `home` client zone | Declared `ingress`, so internal clients reach the relay without hairpinning via the WAN IP |
| Short-lived per-call credentials | Nextcloud Talk, the HPB, Janus | HMAC from shared `COTURN_SECRET`, per call |
| Talk wiring | Nextcloud | The `talk` connector: Nextcloud registers this relay as Talk's STUN/TURN server |

## What is not included

- No HTTP/reverse proxy — coturn is reached directly on port 3478, not via Caddy.
- No media storage — coturn only relays live streams, it never records.
- Credentials are issued by Nextcloud / the HPB (from the shared secret), not by coturn.
- No TURN-over-TLS listener (`turns:`): the site's single WAN IP already serves 443 through
  Caddy, so a 443 fallback is not possible; a 5349 listener would need a certificate on the
  VM and is a follow-up.
- The public DNS A record (`publicDomain → WAN IP`) — see [INSTALL.md](./INSTALL.md).

## Requirements

- `dmz` zone (the VM is placed there; 3478 TCP/UDP and the relay range are exposed).
- Internet egress from the `dmz` zone — the installer detects the public IP from the VM.
- A Nextcloud instance (`nextcloud:fileservice`) — Talk is the consumer of this relay.
- `home` listed in `dmz.pinhole-allowed-from` (zones.json) for the internal-client pinhole —
  the shipped zones template has it. A site with further client zones adds them there and to
  coturn's `ingress`.

## Dependencies

| Depends on | Purpose |
|------------|---------|
| `cluster:vm` | VM provisioning on Proxmox |
| `templates:nixos` | NixOS base image for the VM |
| `network:nat` | WAN port-forwards for 3478 and the relay range |
| `network:rules` | Firewall pass rules (`dmz`, plus the `home` client pinhole) |
| `backup:vm` | VM registered with Proxmox Backup Server |
| `nextcloud:fileservice` | The Nextcloud instance whose Talk uses this relay (connector `talk`) |

Provides `coturn:turn` — consumers (nextcloud-hpb) get the shared secret via the
management plane and the advertised `turnHost` stamped into their config.

For installation steps see [INSTALL.md](./INSTALL.md).
