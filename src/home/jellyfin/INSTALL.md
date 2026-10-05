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

**Installing without a share** works, but the media then lives in `/media` **on
the VM's own 32G disk** — enough to try Jellyfin, not for a library. The mount
is *pending*, the library folders are created locally, and `validate` notes
that the share `media` is not declared.

### Setting up the media share on a node

Run on the tappaas-cicd mothership. The share is declared on the **node**, in its
`nfs` field; Jellyfin's side needs no edit.

**1. Pick the node** — one with a `tankb` pool (second-tier storage, no HA
replication):

```bash
for n in tappaas1 tappaas2 tappaas3; do echo "== $n"; ssh root@$n.mgmt.internal 'zpool list -H -o name,size,free'; done
```

**2. See what the node already serves** — the next step replaces the node's
whole `nfs` value, so existing exports must be carried over:

```bash
module-manager show tappaas1
jq '.nfs // "no exports"' ~/config/tappaas1.json
```

**3. Declare the share and build it** — one command; `modify` writes the field
and then converges the node:

```bash
module-manager modify tappaas1 --set nfs='{"exports": [
  { "name": "media", "pool": "tankb1", "quota": "4T",
    "properties": { "recordsize": "1M", "compression": "lz4" },
    "backup": { "enabled": true, "exclude": [ ".Trash-*" ] },
    "grants": [ { "consumer": "jellyfin", "access": "rw" } ] }
]}'
```

The node creates `tankb1/tappaas-nfs/media` (mounted at `/tappaas-nfs/media`,
quota 4T), allocates its owner uid (64000–64999, written back into the node's
config), creates the alias `nfs-media.mgmt.internal` → the node, shares the
dataset to Jellyfin's address — and, if Jellyfin is installed, runs its mount
update (which moves any local media in, see below).

- `name` must be `media` — that is the share Jellyfin mounts. Share names are
  unique across the Site.
- `quota` is the library's size limit; `backup.enabled` must be stated. Media is
  re-creatable: keep its backup infrequent and short-lived — per-share schedule
  and retention are not built yet (#772, WP6), so today the choice is on or off.
- `rw` because Jellyfin writes `.nfo` files and artwork next to the media when
  configured to; a site that keeps metadata inside the guest can grant `ro` (and
  set the mount to `ro`).

**4. Check it:**

```bash
jq '.nfs.exports[] | {name, quota, owner}' ~/config/tappaas1.json   # owner recorded
getent hosts nfs-media.mgmt.internal                                # alias → the node
ssh root@tappaas1.mgmt.internal 'zfs get -H quota,used,sharenfs tankb1/tappaas-nfs/media'
module-manager validate jellyfin                                    # no "pending" warning
module-manager test jellyfin                                        # once Jellyfin is installed
```

**Later changes** use the same command with the full value restated:

| Change | What to `--set` |
|---|---|
| Grow the library | the same entry with a larger `quota` |
| Let another module use the share | the same entry with one more `grants` item; that module mounts `share: "media"` itself |
| Stop serving it | `nfs='{"exports": []}'` (or the list without `media`): unshared, the dataset and its data are **kept** as an orphan; `pvehost nfs purge` is not built yet (#772) |

`name`, `pool` and the allocated `owner` cannot change in place — a rename or a
pool move is a data migration the reconcile does not attempt.

**When the share arrives after Jellyfin**, the update the node triggers moves
what `/media` holds into it: copies `/media` into `media/jellyfin` while
Jellyfin runs, stops `jellyfin.service`, copies the difference, keeps the old
directory as `/media.pre-nfs` (removed by the next healthy update), mounts the
share and starts Jellyfin. Jellyfin ships with `rebootOk: true`, which is the
consent a migration needs, so this happens unattended. A site that sets
`rebootOk: false` gets *migration pending* instead, and runs it when convenient:

```bash
update-module.sh jellyfin --allow-disruption
```

A share that already holds data is never merged into.

If the share later lives on another node, only its alias changes — Jellyfin's
config, mount and firewall rule stay as they are.

## Configure

| Key | Default | Notes |
|---|---|---|
| `cores` / `memory` | 4 / 2048 | |
| `diskSize` / `storage` | 32G / `tanka1` | The VM only: OS and Jellyfin's own data. The media is on the share — or on this disk while the share is pending |
| `pvehost:nfs` `mounts` | `/media` ← share `media`, subdir `jellyfin`, `rw` | See Media share |
| `rebootOk` | `true` | Lets an unattended update restart Jellyfin — to move `/media` into a newly declared share, or for a change that needs a reboot. `false`: such changes wait for `--allow-disruption` |
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
   create the library folders (on the share, or on the VM's disk while it is
   pending)
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
