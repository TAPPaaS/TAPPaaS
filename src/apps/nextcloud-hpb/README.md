# nextcloud-hpb

Primary audience: Nextcloud Talk users (installed by the TAPPaaS admin alongside Nextcloud).

Nextcloud Talk High-Performance Backend — keeps group video calls smooth as more people
join, and lets people call in from outside the site, including on mobile data.

## What you get

| Capability | Access from | How |
|------------|-------------|-----|
| Reliable group video calls that scale well beyond a handful of people | Nextcloud Talk | Automatic once installed — Talk switches to it |
| Calls that work from outside the site (e.g. mobile data) | Nextcloud Talk | Once the admin turns on public access (see INSTALL.md) |

## What is not included

- **Media relay** — that is coturn's job (`coturn:turn`). Participants this backend cannot
  reach directly relay through coturn.
- **Standalone use** — it only serves the Nextcloud instance it is wired to.
- **Recording, SIP, streaming** — this module only runs the group-video part of Talk.

## Requirements

- `nextcloud` (`nextcloud:fileservice`) and `coturn` (`coturn:turn`) already deployed.
- Placed automatically in Nextcloud's own zone — no action needed unless it must run
  somewhere else.
- Calls from outside the site are off by default; the admin turns them on for this module
  and for Nextcloud together — see INSTALL.md.

## Dependencies

| Depends on | Purpose |
|------------|---------|
| `cluster:vm` | VM provisioning |
| `templates:nixos` | NixOS base image; ships this module's configuration and rebuilds it |
| `backup:vm` | VM registered with Proxmox Backup Server |
| `network:proxy` | Reverse proxy for the signaling connection |
| `network:rules` | Firewall pass rules |
| `nextcloud:fileservice` | The Nextcloud whose Talk uses this backend |
| `coturn:turn` | TURN relay for participants this backend cannot reach directly |

For installation steps see [INSTALL.md](./INSTALL.md).
