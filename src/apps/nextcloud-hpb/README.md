# nextcloud-hpb

Primary audience: Nextcloud Talk users (installed by the TAPPaaS admin alongside Nextcloud).

Nextcloud Talk High-Performance Backend — a dedicated
[nextcloud-spreed-signaling](https://github.com/strukturag/nextcloud-spreed-signaling) server
that offloads Talk's WebSocket signaling from the Nextcloud VM, so calls scale to hundreds of
concurrent connections.

## What you get

| Capability | Access from | How |
|------------|-------------|-----|
| Talk signaling backend | Nextcloud Talk clients | `wss://<proxyDomain>/spreed` (via Caddy) |
| High concurrency | Talk calls | Dedicated Go process, far lower latency than PHP signaling |
| TURN-credential distribution | Talk clients | Served over WebSocket (from coturn's shared secret) |

## What is not included

- **Media relay** — that is coturn's job (`coturn:turn`); HPB only does signaling.
- **Standalone use** — it only serves the Nextcloud instance it is wired to.
- **Public reachability for external calls** — multi-party calls with external participants
  additionally require a publicly reachable coturn (WAN endpoint).

## Requirements

- `srv` zone
- VM sizing (defaults from `nextcloud-hpb.json`): 4 vCPU, 4 GB RAM, 16 GB disk on `tanka1`
- `nextcloud` (`nextcloud:fileservice`) and `coturn` (`coturn:turn`) deployed
- A public DNS record for the HPB proxy domain (external Talk clients)

## Dependencies

| Depends on | Purpose |
|------------|---------|
| `cluster:vm` | VM provisioning |
| `templates:nixos` | NixOS base image |
| `backup:vm` | VM registered with Proxmox Backup Server |
| `network:proxy` | `wss://` reverse proxy via Caddy |
| `network:rules` | Firewall pass rules (incl. callback egress to the Nextcloud proxy) |
| `nextcloud:fileservice` | The Nextcloud instance whose Talk uses this backend |
| `coturn:turn` | TURN relay whose credentials HPB distributes |

For installation steps see [INSTALL.md](./INSTALL.md).
