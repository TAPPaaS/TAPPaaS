# coturn

Primary audience: Nextcloud Talk users (audio/video calls); TAPPaaS admin.

TURN/STUN relay for Nextcloud Talk. It lets audio and video calls connect when someone is
behind a firewall, on mobile data, or calling in from outside the site.

## What you get

| Capability | Access from | How |
|------------|-------------|-----|
| Calls connect across NATs and firewalls | Talk users anywhere — in the office, on mobile data, or off-site | Automatic: Nextcloud Talk uses this relay for every call |
| Internal calls skip the internet | Users on the site's client network | Reachable directly, no detour through the WAN |
| Call credentials | Every Talk call, one-to-one or group | Issued automatically; nothing for you to enter |

## What is not included

- No call recording — coturn only relays live audio and video; it never stores anything.
- No public DNS record — the admin creates the `turn.<domain>` record; see [INSTALL.md](./INSTALL.md).

## Requirements

- A Nextcloud instance with Talk — coturn has nothing to relay without it.
- The site's firewall reachable from the internet — calls from outside the site need the
  relay's ports open (see [INSTALL.md](./INSTALL.md)).

## Dependencies

| Depends on | Purpose |
|------------|---------|
| `cluster:vm` | VM provisioning on Proxmox |
| `templates:nixos` | NixOS base image for the VM |
| `network:nat` | WAN port-forwards for the relay |
| `network:rules` | Firewall pass rules |
| `backup:vm` | VM registered with Proxmox Backup Server |
| `nextcloud:fileservice` | The Nextcloud instance whose Talk uses this relay |

For installation steps see [INSTALL.md](./INSTALL.md).
