# Jellyfin

Open-source media server for personal movie, TV, music, and photo libraries.

Status: Testing — installed and live-tested on the reference site with its media on an NFS share (ADR-029). See
[INSTALL.md](INSTALL.md) for installation and for the media share a site's
server declares — before or after Jellyfin is installed.

## Overview

| Field | Value |
|---|---|
| VM name | `jellyfin` |
| Zone | the environment's zone (`zone0` from `config/environments/<env>.json`) |
| Port | 8096 |
| VM ID | 360 |
| App version | 10.11.11 |
| VM disk | 32G on `tanka1` — OS and Jellyfin's own data (`/var/lib/jellyfin`, metadata, cache) |
| Media | `/media` — subdir `jellyfin` of the NFS share `media` (`storage:nfs`); a local directory while the share is pending |

## Storage

The media library is **not** in the VM. `/media` is the subdirectory `jellyfin`
of the NFS share named **`media`**, served by a cluster node from its `tankb`
pool through `storage:nfs`
([ADR-029](../../../docs/ADR/ADR-029%20-%20NFS%20Service.md) v0.9):

- **Jellyfin names the share, not a machine.** `jellyfin.json` mounts
  `share: "media"`, `subdir: "jellyfin"` at `/media`, `rw` — the same file on
  every site. The guest mounts `nfs-media.mgmt.internal:/tappaas-nfs/media/jellyfin`;
  the alias follows the share, so moving it to another node or pool changes
  nothing here.
- **The operator declares the share** with `storage-manager` (kept in
  `config/shares.json`): name `media`, server node, pool, quota, backup policy,
  and a grant to `jellyfin`. A consumer never creates a share.
- **The service joins them:** it shares the dataset to Jellyfin's address only,
  opens the one firewall path (Jellyfin → the share, tcp/2049) and writes the
  mount into the guest (`/etc/nixos/tappaas-nfs.nix`, imported by the
  baseline). The mount is `nofail` + automount: Jellyfin starts even while the
  server is down.

**No share yet?** Jellyfin installs and works anyway, but the media then lives
in `/media` **on the VM's own 32G disk** (on `tanka1`) — a stopgap, not a home
for a library. Declare the `media` share for real use. When it arrives, the next
update **moves** what `/media` holds into it — copied while Jellyfin runs,
`jellyfin.service` stopped for the final pass, the old directory kept as
`/media.pre-nfs` until the next healthy update — and mounts it. The module ships
with `rebootOk: true`, so that happens without anyone present; Jellyfin is down
for the final copy only.

Why: media is large and can be re-ripped or re-downloaded. It does not belong on
the replicated `tanka` tier or in the VM's backup, and it should outlive the VM
— deleting or rebuilding Jellyfin leaves the library where it is. For the same
reason Jellyfin is deliberately **not** HA (no `cluster:ha`).

Every request is squashed to the share's owner (ADR-029 D7), so the `jellyfin`
user reads and writes the share although the files on the server belong to one
reserved uid.

## Media Folders

`update.sh` creates the library folders — on the share, or on the VM's disk while
the share is pending:

```
/media/
  Movies/           Jellyfin library: Movies
  TV/               Jellyfin library: Shows
  Music/            Jellyfin library: Music
  Photos/           Jellyfin library: Photos
  Audiobooks/       Jellyfin library: Books/Audiobooks
```

Another module that needs the library — a download client writing new media,
say — gets its own grant on the share `media` and mounts it itself. It never
goes through Jellyfin. `subdir` is organisation, not isolation: every consumer
granted `media` can reach all of it (ADR-029 D15).

## Module dependencies & traffic flow

```mermaid
graph LR
    jellyfin["jellyfin (zone: env zone, VM :8096)"]
    cluster["cluster:vm"]
    templates["templates:nixos"]
    backup["backup:vm"]
    nfs["storage:nfs"]
    netproxy["network:proxy / network:rules"]
    idac["identity:accessControl"]
    idoidc["identity:identity (OIDC, SSO-Auth plugin)"]
    node["share media — nfs-media.mgmt.internal (tankb pool on a node)"]
    caddy["Caddy reverse proxy (on the OPNsense firewall, :443)"]
    authentik["Authentik (identity) — forward-auth"]
    homeclients["home-zone clients (LAN)"]
    vpnpeers["netbird VPN peers (remote devices)"]
    internet["internet (public)"]

    jellyfin -->|dependsOn| cluster
    jellyfin -->|dependsOn| templates
    jellyfin -->|dependsOn| backup
    jellyfin -->|dependsOn| nfs
    jellyfin -->|dependsOn| netproxy
    jellyfin -->|dependsOn| idac
    jellyfin -->|dependsOn| idoidc

    jellyfin -.->|"NFSv4 tcp/2049 — /media = media/jellyfin"| node
    homeclients -.->|"https://jellyfin.&lt;domain&gt;"| caddy
    vpnpeers -.->|"same vhost, via WireGuard overlay"| caddy
    internet -.->|"proxyAllowedZones includes internet"| caddy
    caddy -.->|"forward-auth: logged in?"| authentik
    caddy -.->|"upstream :8096, after Authentik"| jellyfin
```

Solid arrows are declared `dependsOn` edges (install-order dependencies). Dashed
arrows are traffic: `network:proxy` creates the `jellyfin.<domain>` vhost on the
Caddy reverse proxy, and `proxyAllowedZones` (`home`, `netbird`, `internet`)
controls which source zones that vhost accepts. `identity:accessControl` puts
Authentik forward-auth on that vhost, so the zone list only filters; the gate is
Authentik. The NFS path to the share is the one rule `network:rules` derives
from the mount (none while it is pending).

## Access: browser only, behind Authentik

Every request to `https://jellyfin.<domain>` goes through Authentik first, from
home, from netbird and from the internet alike (home clients resolve the same
name to Caddy, ADR-021). Only members of the Authentik group `users` get through
(#805).

Jellyfin's login page then offers **Sign in with Authentik** (the SSO-Auth plugin,
#806). With the Authentik session already open it is one click. The Jellyfin tile
in Authentik's app list goes straight through
(`/sso/OID/start/authentik`).

- **Accounts:** the first Authentik sign-in creates the Jellyfin account, named
  after the Authentik username, with access to every library.
- **Admins:** members of the Authentik group `jellyfin-admins` become Jellyfin
  administrators, and that is re-checked at every sign-in.
- **Local accounts:** `admin`, `stream` and `local` (from the install) keep working
  with their passwords on the same page. `admin` is the break-glass account.
- **Name collisions:** the plugin links an Authentik user to an EXISTING Jellyfin
  account of the same name. Don't give an Authentik user the name `admin`,
  `stream` or `local`, or it gets that local account.
- **Plugin version:** 9p4/jellyfin-plugin-sso 4.0.0.4, pinned in `jellyfin.nix`.
  Upstream is archived, and this is its last release (for Jellyfin 10.11). It's a
  store path of its own (`jellyfin-plugin-sso-4.0.0.4`), so the security scan
  lists it.

**Native TV and mobile apps do not work.** They log in to Jellyfin's API with a
username and password, and cannot pass forward-auth. There is no direct route
either: Jellyfin sits in a Service zone that accepts connections from the
proxy (`dmz`) only. Apps come back with an ADR-023 path bypass
(`proxyAccess` / `identityGate: false`), which is not built yet.

## Quick Start

```bash
# installs with or without a media share — see INSTALL.md → Media share
cd "${TAPPAAS_REPO:-/home/tappaas/TAPPaaS}"/src/home/jellyfin
install-module.sh jellyfin
```

See [INSTALL.md](INSTALL.md) for full instructions.
