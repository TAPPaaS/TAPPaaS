# coturn

TURN/STUN relay for Nextcloud Talk — relays WebRTC audio/video between peers that are behind different NATs, so calls connect when a direct peer-to-peer path fails.

## What you get

| Capability | Access from | How |
|---|---|---|
| TURN/STUN relay | Talk clients (any network) | UDP/TCP `coturn.dmz.internal:3478` |
| Short-lived call credentials | Nextcloud Talk | HMAC-derived from a shared secret, per call |

## What is not included

- No HTTP/reverse proxy — coturn is reached directly on port 3478, not via Caddy.
- No media storage — coturn only relays live streams, it never records.
- Credentials are issued by Nextcloud (from the shared secret), not by coturn itself.

## Architecture

```
Client A (NAT) ─[UDP 3478]─▶ coturn (DMZ) ─[UDP 3478]─▶ Client B (NAT)
                                  ▲
                  Nextcloud (srv) │ issues per-call credentials (shared HMAC secret)
```

Custom systemd `coturn` service (not the NixOS `services.coturn` module). Only port 3478 (UDP+TCP) is exposed; coturn sits in the `dmz` zone.

## Requirements

- `dmz` zone
- `nextcloud` deployed (`nextcloud:nextcloud` dependency) — Talk is the consumer
- NixOS template (`templates:nixos`)

## Dependencies

| Depends on | Purpose |
|---|---|
| `cluster:vm` | VM provisioning |
| `templates:nixos` | NixOS base image |
| `backup:vm` | VM registered with Proxmox Backup Server |
| `nextcloud:nextcloud` | The Nextcloud instance whose Talk uses this relay |

For installation, the shared-secret wiring, and troubleshooting see [INSTALL.md](./INSTALL.md).

## Deploy notes & known limitations (0.1.0)

- Validated as a `dmz` test variant (test.sh 10/0/2). For real external Talk calls, set the public TURN endpoint (WAN IP / publicDomain:3478 + NAT) — the test variant has no WAN IP.
- The shared TURN secret is published to the management plane and consumed by Nextcloud/HPB (the connector is owned by Nextcloud, ADR-COM-0002).
