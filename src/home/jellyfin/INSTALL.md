# Jellyfin — Installation

## Prerequisites

1. TAPPaaS foundation deployed: `cluster:vm`, `templates:nixos`, `backup:vm`,
   `pvehost:nfs`, `network:proxy`, `network:rules`
2. A cluster node with a `tankb` pool to serve the media share from — on the
   three-node reference cluster that is `tappaas2` (`tankb1`)
3. The `media` export declared on that node (below) — **before** the install:
   the install refuses a mount whose share the node does not declare

## Media share

The library lives on an NFS share the node serves (`pvehost:nfs`,
[ADR-029](../../../docs/ADR/ADR-029%20-%20NFS%20Service.md)). Two declarations,
both needed — the node grants, Jellyfin requests:

**1. The node** — add the export to the node's config, `config/tappaas2.json`:

```json
"nfs": { "exports": [
  { "name": "media", "pool": "tankb1", "quota": "4T",
    "properties": { "recordsize": "1M", "compression": "lz4" },
    "backup": { "enabled": true, "exclude": [ ".Trash-*" ] },
    "grants": [ { "consumer": "jellyfin", "access": "rw" } ] }
]}
```

Building it is optional — the Jellyfin install has the node build a declared
export that is not built yet — or do it now with the node's own update:

```bash
update-module.sh tappaas2
```

Either way the node creates `tankb1/tappaas-nfs/media` (quota 4T), allocates
its owner uid (64000–64999, written back into the file) and shares it to
Jellyfin's address only. `quota` is the library's size limit; `backup.enabled` must
be stated. Media is re-creatable: keep its backup infrequent and short-lived —
the per-export schedule and retention are not built yet (#772, WP6), so today
the choice is on or off.

**2. Jellyfin** — `jellyfin.json` already declares the mount:

```json
"config": { "pvehost:nfs": { "mounts": [
  { "path": "/media", "share": "tappaas2:media", "access": "rw" }
]}}
```

Serving the share from another node: change `tappaas2` in both places. `rw`
because Jellyfin writes `.nfo` files and artwork next to the media when
configured to; a site that keeps metadata inside the guest can grant and mount
`ro`.

## Configure

| Key | Default | Notes |
|---|---|---|
| `cores` / `memory` | 4 / 2048 | |
| `diskSize` / `storage` | 32G / `tanka1` | The VM only: OS and Jellyfin's own data. The media is on the share |
| `pvehost:nfs` `mounts` | `/media` ← `tappaas2:media`, `rw` | See Media share |
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
2. Assign network, VLAN and the firewall rules — including the derived
   Jellyfin → node tcp/2049 path for the share
3. Check the mount against the node's grant, share the export to Jellyfin's
   address, and write the mount into the guest (`pvehost:nfs`)
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

`delete-module.sh jellyfin` removes the VM and its mount. **The library stays**:
the data belongs to the node's export, not to Jellyfin (ADR-029 D6). Removing
the export from the node unshares it and keeps the dataset.

## Troubleshooting

**Jellyfin web UI not reachable**
```bash
ssh tappaas@jellyfin.<zone>.internal 'sudo journalctl -u jellyfin -n 50'
```

**/media empty or not mounted**
```bash
ssh tappaas@jellyfin.<zone>.internal 'ls /media; findmnt /media'
update-module.sh tappaas2         # is the export built and shared?
update-module.sh jellyfin         # re-checks the grant, rewrites the mount, rebuilds
```
The install refuses a mount the node does not declare or grant — the message
names the export entry to add.

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
