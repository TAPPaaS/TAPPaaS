# nextcloud-hpb

Nextcloud Talk High-Performance Backend — a dedicated [nextcloud-spreed-signaling](https://github.com/strukturag/nextcloud-spreed-signaling) server that offloads Talk's WebSocket signaling, ICE coordination, and TURN-credential distribution from the Nextcloud VM, so Talk scales to hundreds of concurrent connections.

> **Status: Development** — the VM provisions, but the NixOS signaling config is still being finalised.

## What you get

| Capability | Access from | How |
|---|---|---|
| Talk signaling backend | Nextcloud Talk | `wss://hpb.<domain>/spreed` (via Caddy) |
| High concurrency | Talk calls | Dedicated Go process, far lower latency than PHP signaling |
| TURN-credential distribution | Talk clients | Served over WebSocket (from coturn's shared secret) |

## What is not included

- No media relay — that is coturn's job (`coturn:turn`); HPB only does signaling.
- No standalone use — it only serves the Nextcloud instance it is wired to.
- No PHP — signaling runs entirely in the Go process, off the Nextcloud workers.

## Architecture

```
Browser/Phone ─wss://hpb.<domain>/spreed─▶ Caddy (OPNsense) ─▶ nextcloud-hpb :8080 (srv)
                                                                   │ TURN creds from coturn (dmz)
                                              Nextcloud (srv) ◀────┘ registers HPB as Talk signaling server
```

## Requirements

- `srv` zone
- `nextcloud` (`nextcloud:nextcloud`) and `coturn` (`coturn:turn`) deployed
- NixOS template (`templates:nixos`)

## Dependencies

| Depends on | Purpose |
|---|---|
| `cluster:vm` | VM provisioning |
| `templates:nixos` | NixOS base image |
| `backup:vm` | VM registered with Proxmox Backup Server |
| `firewall:proxy` | `wss://` reverse proxy via Caddy |
| `nextcloud:nextcloud` | The Nextcloud instance whose Talk uses this backend |
| `coturn:turn` | TURN relay whose credentials HPB distributes |

For installation, the shared-secret wiring, and troubleshooting see [INSTALL.md](./INSTALL.md).

## Deploy notes & known limitations (0.1.0)

- Validated via test variant (test.sh 14/0/0); the Talk HPB signaling connection check is confirmed green.
- The signaling backend allow-list (Nextcloud public URL) and the TURN advertise host are injected by install.sh into the deployed nix and applied via `nixos-rebuild -I nixos-config=` — the nix ships placeholder defaults.
- External multi-party calls require a publicly reachable coturn (WAN endpoint).
