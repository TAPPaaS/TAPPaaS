# nextcloud-hpb

Primary audience: Nextcloud Talk users (installed by the TAPPaaS admin alongside Nextcloud).

Nextcloud Talk High-Performance Backend — a dedicated
[nextcloud-spreed-signaling](https://github.com/strukturag/nextcloud-spreed-signaling) server
that offloads Talk's WebSocket signaling from the Nextcloud VM, plus a
[Janus](https://janus.conf.meetecho.com/) SFU so group calls scale: every participant sends
**one** stream to Janus, which fans it out. Without the SFU Talk runs group calls as a full
mesh (each client uploads N−1 streams), which caps a video call at roughly 5-6 participants.

## What you get

| Capability | Access from | How |
|------------|-------------|-----|
| Talk signaling backend | Nextcloud Talk clients | `wss://<proxyDomain>/spreed` (via Caddy; internal zones unless opted in, see DESIGN.md) |
| Group-call SFU (Janus) | Talk calls | One uplink per participant; ~30-way video calls |
| High concurrency | Talk calls | Dedicated Go process, far lower latency than PHP signaling |
| TURN-credential distribution | Talk clients, Janus | Served over WebSocket / TURN REST API (from coturn's shared secret) |

## What is not included

- **Media relay** — that is coturn's job (`coturn:turn`). Participants Janus cannot reach
  directly (other client zones, the internet) relay through coturn.
- **Standalone use** — it only serves the Nextcloud instance it is wired to.
- **Recording**, SIP, streaming — Janus plugins other than `videoroom` are disabled.

## Requirements

- **The Nextcloud zone.** The pre-install hook places the HPB in the zone of the Nextcloud it
  serves, unless `zone0` is set explicitly. If the VM cannot get an address in its zone, the
  installer stops at "does not resolve" and names the zone and VLAN.
- VM sizing (defaults from `nextcloud-hpb.json`): 4 vCPU, 4 GB RAM, 16 GB disk on `tanka1`.
  Fine to ~30 video participants; for external attendees the **WAN uplink** is the ceiling
  (a 30-way call is 30 × 29 downstream streams out of Janus), not the CPU.
- `nextcloud` (`nextcloud:fileservice`) and `coturn` (`coturn:turn`) deployed.
- A public DNS record for the HPB proxy domain (external Talk clients).

## Dependencies

| Depends on | Purpose |
|------------|---------|
| `cluster:vm` | VM provisioning |
| `templates:nixos` | NixOS base image; ships the `.nix` + companion JSON and rebuilds with the platform pin |
| `backup:vm` | VM registered with Proxmox Backup Server |
| `network:proxy` | `wss://` reverse proxy via Caddy |
| `network:rules` | Firewall pass rules |
| `nextcloud:fileservice` | The Nextcloud whose Talk uses this backend; stamps `nextcloudPublicUrl`, wires the `hpb` connector |
| `coturn:turn` | TURN relay: shared secret via the management plane, `turnHost` stamped into this module's config |

For installation steps see [INSTALL.md](./INSTALL.md).
