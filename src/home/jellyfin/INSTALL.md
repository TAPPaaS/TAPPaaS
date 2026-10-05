# Jellyfin — Installation

## Prerequisites

1. TAPPaaS foundation deployed: `cluster:vm`, `templates:nixos`, `backup:vm`,
   `pvehost:nfs`, `network:proxy`, `network:rules`
2. For the media share (now or later): a cluster node with a `tankb` pool to
   serve it from

## Media share

The library lives on the NFS share named **`media`** (`pvehost:nfs`,
[ADR-029](../../../docs/ADR/ADR-029%20-%20NFS%20Service.md) v0.8). Jellyfin mounts
it by name — `jellyfin.json` is the same on every site and never names a node:

```json
"config": { "pvehost:nfs": { "mounts": [
  { "path": "/media", "share": "media", "subdir": "jellyfin", "access": "rw",
    "stopUnits": ["jellyfin.service"] }
]}}
```

**Installing without a share** works: the mount is *pending*, `/media` is a
local directory on the VM's disk, and `validate` notes that the share `media`
is not declared.

**Declaring the share** — on the node that has the `tankb` pool, in its config
(`config/<node>.json`, e.g. `config/tappaas1.json`):

```json
"nfs": { "exports": [
  { "name": "media", "pool": "tankb1", "quota": "4T",
    "properties": { "recordsize": "1M", "compression": "lz4" },
    "backup": { "enabled": true, "exclude": [ ".Trash-*" ] },
    "grants": [ { "consumer": "jellyfin", "access": "rw" } ] }
]}
```

then `update-module.sh <node>`. The node creates `tankb1/tappaas-nfs/media`
(mounted at `/tappaas-nfs/media`, quota 4T), allocates its owner uid
(64000–64999, written back into the file), creates the alias
`nfs-media.mgmt.internal` → the node, shares the dataset to Jellyfin's address
and runs the mount's update for Jellyfin — before or after Jellyfin is
installed. `quota` is the library's size limit; `backup.enabled` must be stated.
Media is re-creatable: keep its backup infrequent and short-lived — per-share
schedule and retention are not built yet (#772, WP6), so today the choice is on
or off.

**When the share arrives after Jellyfin** and `/media` already holds media, the
update migrates it: copies `/media` into `media/jellyfin` while Jellyfin runs,
stops `jellyfin.service`, copies the difference, keeps the old directory as
`/media.pre-nfs`, mounts the share and starts Jellyfin. That stops Jellyfin, so
it runs only with consent — `rebootOk: true` on the module, or

```bash
update-module.sh jellyfin --allow-disruption
```

— otherwise the update reports *migration pending* and changes nothing. A share
that already holds data is never merged into. An empty `/media` needs no
migration: the share is simply mounted.

Moving the share to another node or pool later changes only the alias —
Jellyfin's config, mount and firewall rule stay as they are. `rw` because
Jellyfin writes `.nfo` files and artwork next to the media when configured to;
a site that keeps metadata inside the guest can grant and mount `ro`.

## Configure

| Key | Default | Notes |
|---|---|---|
| `cores` / `memory` | 4 / 2048 | |
| `diskSize` / `storage` | 32G / `tanka1` | The VM only: OS and Jellyfin's own data. The media is on the share — or on this disk while the share is pending |
| `pvehost:nfs` `mounts` | `/media` ← share `media`, subdir `jellyfin`, `rw` | See Media share |
| `rebootOk` | not set | Set `true` to let an update migrate `/media` into a newly available share without `--allow-disruption` |
| `proxyAllowedZones` | `home, netbird, internet` | Drop `internet` for a private-only deployment |

## Install

Run from the tappaas-cicd mothership, in this module's directory:

```bash
cd "${TAPPAAS_REPO:-/home/tappaas/TAPPaaS}"/src/home/jellyfin
install-module.sh jellyfin
```

Duration: ~5–10 minutes (NixOS clone + rebuild).

`install-module.sh` will:
1. Clone the NixOS template VM (vmid 8080) onto `tanka1`
2. Assign network, VLAN and the firewall rules — including, when the share is
   declared, the derived Jellyfin → `nfs-media` tcp/2049 path
3. Check the mount against the share's grant and write it into the guest — or
   record it as pending when no server declares `media` (`pvehost:nfs`)
4. Apply `jellyfin.nix` via `update.sh` — the rebuild mounts `/media` — and
   create the library folders on the share
5. Bootstrap the admin, `stream` and `local` accounts and print the web UI URL

## First-Time Setup

1. Open `https://jellyfin.<your-domain>` and log in with the printed admin account
2. Add libraries under **Dashboard → Libraries**:

   | Path | Library type |
   |---|---|
   | `/media/Movies` | Movies |
   | `/media/TV` | Shows |
   | `/media/Music` | Music |
   | `/media/Photos` | Photos |
   | `/media/Audiobooks` | Books/Audiobooks |

## Verification

```bash
cd "${TAPPAAS_REPO:-/home/tappaas/TAPPaaS}"/src/home/jellyfin
./test.sh jellyfin
```

## Updating Jellyfin

```bash
cd "${TAPPAAS_REPO:-/home/tappaas/TAPPaaS}"/src/home/jellyfin
./update.sh jellyfin
```

This pushes the current `jellyfin.nix` and runs `nixos-rebuild switch` on the VM.

## Deleting Jellyfin

`delete-module.sh jellyfin` removes the VM and its mount and takes its address
out of the share's client list. **The library stays**: the data belongs to the
share, not to Jellyfin (ADR-029 D6). Removing the export from the node unshares
it and keeps the dataset.

## Troubleshooting

**Jellyfin web UI not reachable**
```bash
ssh tappaas@jellyfin.<zone>.internal 'sudo journalctl -u jellyfin -n 50'
```

**/media empty or not mounted**
```bash
ssh tappaas@jellyfin.<zone>.internal 'ls /media; findmnt /media'
./test.sh jellyfin                 # pending, migration pending, or not mounted?
update-module.sh <node>            # is the share built and shared?
update-module.sh jellyfin          # re-checks the grant, rewrites the mount, rebuilds
```
A share that exists but does not grant `jellyfin` is refused — the message names
the grant to add. *Migration pending* means `/media` holds local data and the
update had no consent: run it with `--allow-disruption`.

## Variants

### Hardware transcoding (Intel iGPU)

Add to `jellyfin.nix` inside the `{ ... }` block:
```nix
hardware.opengl = { enable = true; extraPackages = [ pkgs.intel-media-driver ]; };
environment.sessionVariables.LIBVA_DRIVER_NAME = "iHD";
```
Then enable in Jellyfin Dashboard → Playback → Hardware Acceleration → Intel QuickSync (QSV).

### Private-only deployment

Remove `"internet"` from `proxyAllowedZones` in `jellyfin.json` and run
`update-module.sh jellyfin`. LAN clients and `netbird` VPN peers keep access.
