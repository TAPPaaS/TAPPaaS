# coturn

Primary audience: Nextcloud Talk users (audio/video calls); TAPPaaS admin.

TURN/STUN relay for Nextcloud Talk — relays WebRTC audio/video between peers behind
different NATs, so calls connect even when a direct peer-to-peer path fails.

## What you get

| Capability | Access from | How |
|------------|-------------|-----|
| TURN/STUN relay for Talk calls | Talk clients anywhere | UDP/TCP `coturn.dmz.internal:3478` |
| Short-lived per-call credentials | Nextcloud Talk | HMAC from shared `COTURN_SECRET`, per call |

## What is not included

- No HTTP/reverse proxy — coturn is reached directly on port 3478, not via Caddy.
- No media storage — coturn only relays live streams, it never records.
- Credentials are issued by Nextcloud (from the shared secret), not by coturn itself.
- WAN NAT rules and the public DNS record are not configured automatically
  (see [INSTALL.md](./INSTALL.md)).

## Requirements

- `dmz` zone (the VM is placed there; only port 3478 UDP/TCP is exposed).
- Internet egress from the `dmz` zone — the installer detects the public IP from the VM.
- A Nextcloud instance (`nextcloud:fileservice`) — Talk is the consumer of this relay.
- For calls from external networks: a WAN IP and OPNsense NAT rules (manual post-install).

## Dependencies

| Depends on | Purpose |
|------------|---------|
| `cluster:vm` | VM provisioning on Proxmox |
| `templates:nixos` | NixOS base image for the VM |
| `network:rules` | Firewall/zone pass rules (`dmz`) |
| `backup:vm` | VM registered with Proxmox Backup Server |
| `nextcloud:fileservice` | The Nextcloud instance whose Talk uses this relay (connector `talk`) |

For installation steps see [INSTALL.md](./INSTALL.md).
