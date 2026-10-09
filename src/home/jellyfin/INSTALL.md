# Jellyfin — Installation

## Prerequisites

1. TAPPaaS foundation deployed: `cluster:vm`, `templates:nixos`, `backup:vm`,
   `storage:nfs`, `network:proxy`, `network:rules`, and the `identity` module
   (Authentik): `identity:accessControl` gates the published name and
   `identity:identity` gives Jellyfin's login a Sign in with Authentik button
2. For the media share (now or later): a cluster node with a `tankb` pool to
   serve it from

## Media share

The library lives on the NFS share named **`media`** (`storage:nfs`,
[ADR-029](../../../docs/ADR/ADR-029%20-%20NFS%20Service.md) v0.9). Jellyfin mounts
it by name — `jellyfin.json` is the same on every site and never names a node:

```json
"config": { "storage:nfs": { "mounts": [
  { "path": "/media", "share": "media", "subdir": "jellyfin", "access": "rw",
    "stopUnits": ["jellyfin.service"] }
]}}
```

**Installing without a share** works, but the media then lives in `/media` **on
the VM's own 32G disk** — enough to try Jellyfin, not for a library. The mount
is *pending*, the library folders are created locally, and `validate` notes
that the share `media` is not declared.

### Setting up the media share

Run on the tappaas-cicd mothership. The share is declared with `storage-manager`
(kept in `config/shares.json`); Jellyfin's side needs no edit.

**1. Pick the node** — one with a `tankb` pool (second-tier storage, no HA
replication):

```bash
for n in tappaas1 tappaas2 tappaas3; do echo "== $n"; ssh root@$n.mgmt.internal 'zpool list -H -o name,size,free'; done
```

**2. Declare the share and grant it to Jellyfin** — each verb writes
`shares.json` and converges the node at once:

```bash
storage-manager nfs share add media --server tappaas1 --pool tankb1 --quota 4T \
  --prop recordsize=1M --prop compression=lz4 --backup true --backup-exclude '.Trash-*'
storage-manager nfs grant media jellyfin rw
```

The node creates `tankb1/tappaas-nfs/media` (mounted at `/tappaas-nfs/media`,
quota 4T, owned by the uid `share add` allocated, 64000–64999), the alias
`nfs-media.mgmt.internal` → the node is created, and the dataset is shared to
Jellyfin's address. `grant` then runs Jellyfin's mount update, if Jellyfin is
installed (which moves any local media in, see below).

- The name must be `media` — that is the share Jellyfin mounts. Share names are
  unique across the Site.
- `--quota` is the library's size limit; `--backup` must be stated. Media is
  re-creatable: keep its backup infrequent and short-lived — per-share schedule
  and retention are not built yet (#772, WP6), so today the choice is on or off.
- `rw` because Jellyfin writes `.nfo` files and artwork next to the media when
  configured to; a site that keeps metadata inside the guest can grant `ro` (and
  set the mount to `ro`).

**3. Check it:**

```bash
storage-manager nfs show                                            # share, owner, grants
getent hosts nfs-media.mgmt.internal                                # alias → the node
ssh root@tappaas1.mgmt.internal 'zfs get -H quota,used,sharenfs tankb1/tappaas-nfs/media'
module-manager validate jellyfin                                    # no "pending" warning
module-manager test jellyfin                                        # once Jellyfin is installed
```

**Later changes:**

| Change | Command |
|---|---|
| Grow the library | `storage-manager nfs share modify media --set quota=6T` |
| Let another module use the share | `storage-manager nfs grant media <module> ro`; that module mounts `share: "media"` itself |
| Stop serving it | remove Jellyfin's mount, then `storage-manager nfs share delete media`: unshared, the dataset and its data are **kept**; `storage-manager nfs share purge media --server tappaas1 --yes` destroys it |

`server`, `pool` and the allocated owner cannot change in place — moving the
share to another node or pool is a data migration (a `share move` verb comes
later).

**When the share arrives after Jellyfin**, the update `grant` triggers moves
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

The order of `dependsOn` in `jellyfin.json` is deliberate — install and update
apply dependencies in that order:

- `identity:accessControl` right after `network:proxy`: it turns on forward-auth
  for the route that `network:proxy` has just created. An update that recreates
  the route therefore gets the gate back in the same run;
- `identity:identity` last: it registers Jellyfin's OIDC app (after
  accessControl has moved the gate to `jellyfin-gate`), writes the client
  config to `/etc/secrets/jellyfin.env` and restarts `jellyfin-configure-oidc`,
  which `templates:nixos` has built by then;
- `network:rules` before `storage:nfs`, so the firewall path to the share exists
  before a migration tries to mount it (in the other order the migration timed
  out and every update rolled back);
- `storage:nfs` before `templates:nixos`, so the mount the service writes into
  the guest (`/etc/nixos/tappaas-nfs.nix`) is applied by the OS build that
  follows — the platform's pinned build (`update-os.sh`). Jellyfin's `update.sh`
  does not rebuild NixOS itself.

If the share later lives on another node, only its alias changes — Jellyfin's
config, mount and firewall rule stay as they are.

## Configure

| Key | Default | Notes |
|---|---|---|
| `cores` / `memory` | 4 / 2048 | |
| `diskSize` / `storage` | 32G / `tanka1` | The VM only: OS and Jellyfin's own data. The media is on the share — or on this disk while the share is pending |
| `storage:nfs` `mounts` | `/media` ← share `media`, subdir `jellyfin`, `rw` | See Media share |
| `rebootOk` | `true` | Lets an unattended update restart Jellyfin — to move `/media` into a newly declared share, or for a change that needs a reboot. `false`: such changes wait for `--allow-disruption` |
| `proxyAllowedZones` | `home, netbird, internet` | Which zones Caddy accepts at all; Authentik forward-auth gates every one of them. Drop `internet` for a private-only deployment |

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
   record it as pending when `media` is not declared (`storage:nfs`)
4. Apply `jellyfin.nix` via `update.sh` — the rebuild mounts `/media` — and
   create the library folders (on the share, or on the VM's disk while it is
   pending)
5. Bootstrap the admin, `stream` and `local` accounts and print the web UI URL

## First-Time Setup

1. Open `https://jellyfin.<your-domain>`, or the Jellyfin tile in Authentik. Log in
   to Authentik (any member of the `users` group gets through), then click
   **Sign in with Authentik**. For administration, be in `jellyfin-admins`, or use
   the printed `admin` account on the same page. Browser only: TV and mobile apps
   cannot pass forward-auth — see
   [README.md](README.md#access-browser-only-behind-authentik)
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

The NixOS configuration is built and applied by `templates:nixos`
(`update-os.sh`, the release's pinned nixpkgs, built on the mothership) — after
`storage:nfs` has written the share's mount; `update.sh` only makes sure the
library folders exist.

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
`update-module.sh jellyfin`. LAN clients and `netbird` VPN peers keep access,
still through Authentik.
