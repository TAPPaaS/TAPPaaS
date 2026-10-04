# Jellyfin — Installation

## Prerequisites

1. TAPPaaS foundation deployed: `cluster:vm`, `templates:nixos`, `backup:vm`, `network:proxy`, `network:rules`
2. A place for the media to live — see [Media Storage](#media-storage) for the three
   supported paths (module-allocated disk, a disk you attach, or a directly
   mounted network share)
3. For `mediaStorage: allocate`: sufficient free space on the chosen
   storage — at minimum the value of `mediaDiskSize` (default 2 TB)

## Configure

Edit `jellyfin.json` to match your environment:

```json
"config": {
  "cluster:vm": {
    "mediaStorage": "allocate",     ← allocate | attached | share (see Media Storage)
    "mediaDiskStorage": "tankb2",   ← allocate only: Proxmox storage name
    "mediaDiskSize": "4T"            ← allocate only: size of the new disk
  }
}
```

`mediaStorage` declares where the media lives and is the single source of truth
for the install and for recovery runs:

| Mode | Meaning | Path below |
|---|---|---|
| `allocate` (default) | The module creates and formats a fresh virtual disk on `mediaDiskStorage` | Path 1 |
| `attached` | You attach a disk (USB/iSCSI) at slot scsi2; the module only verifies, never formats | Path 2 |
| `share` | `/media` is a NAS share mounted directly; declared with the `mediaShare*` keys, no disk at all | Path 3 |

For `share` mode, add:

```json
"mediaStorage": "share",
"mediaShareHost": "synology.<zone>.internal",
"mediaShareExport": "/volume1/media",
"mediaShareType": "nfs"                ← nfs (default) or cifs
```

`update.sh` generates the `/media` mount in the deployed NixOS config from
these keys. `mediaShareOptions` (comma-separated) overrides the mount options
— optional for nfs, required for cifs (must include a `credentials=` file
that exists on the VM).

## Media Storage

The media disk is a second block device (scsi2), separate from the 32G OS disk.
Inside the VM it is addressed by its slot-stable path
`/dev/disk/by-id/scsi-0QEMU_QEMU_HARDDISK_drive-scsi2` (QEMU stamps the drive
id into the SCSI serial — this always means "the disk at scsi2" even when
additional disks, iSCSI LUNs, or multipath devices shuffle the `/dev/sdX`
letters). The NixOS config mounts whatever carries the ext4 label
**`jellyfin-media`** at `/media`. Jellyfin's libraries, the NFS export, and all
`jellyfin:storage` consumer mounts reference `/media` only — the backend behind
the label can be swapped at any time without touching Jellyfin.

How the scripts behave, per mode:

- **`install-service.sh`** (runs automatically, idempotent) acts on what
  `mediaStorage` declares. In `allocate` mode it creates and formats a fresh
  volume if slot scsi2 is empty — the only thing it ever formats is the blank
  volume it created seconds earlier; an existing disk is never touched. In
  `attached` and `share` modes it is verify-only and fails with instructions
  when something is missing, instead of acting.
- **`setup-media-disk.sh`** (interactive, for `attached` mode) inspects the
  disk you attached and offers the one preparation it needs: ext4 with the
  wrong label → **non-destructive relabel** (data kept); blank → format;
  foreign filesystem (possibly your media) → kept unless you type `erase`.
  Every change stops at a confirmation prompt — the default is No, cancelling
  (Ctrl+C or plain Enter) is always safe, and nothing is touched before you
  answer.

### One media store, many modules (the intended design)

The media store is meant to be **shared**: one filesystem that other modules
write media into and Jellyfin serves from. Two rules govern how that sharing
works:

1. **The block device has exactly one owner** — the Jellyfin VM (or the NAS, in
   Path 3). Never attach the same disk/LUN to a second VM, and never let the NAS
   keep using a LUN that is mapped into the VM: ext4 is not a cluster filesystem,
   and a second writer at the block layer corrupts it. No path supports
   block-level sharing, by design.
2. **All other modules share at the file layer, over NFS.** In Paths 1 and 2
   Jellyfin *is* the storage server: `/media` is NFS-exported to its own
   zone, and a consumer module declares `dependsOn: ["jellyfin:storage"]` to get
   it mounted at `/media-jellyfin`. In Path 3 the NAS is the storage server and
   every module (Jellyfin included) is just a client.

The flow this enables: a media-writing consumer writes into
`/media-jellyfin/downloads/complete`; the export's `all_squash,anonuid=993` maps
every write to the `jellyfin` user, so ownership is always right. And because
`downloads/` and `Movies/`/`TV/` live on the **same filesystem**, promoting a
finished file into the library is an instant rename — no cross-device copy
of a 50 GB file. This is the main argument for one shared store over separate
disks per module.

| | Multiple modules on the same media? | Highlight |
|---|---|---|
| Path 1 (`allocate`) | ✅ via this module's NFS export | Consumers depend on the Jellyfin VM being up |
| Path 2 (`attached`) | ✅ via this module's NFS export | Same; and the LUN/disk must stop being used by its previous host |
| Path 3 (`share`) | ✅ via the NAS itself | ⚠ `jellyfin:storage` does not apply — consumers mount the NAS, and realtime monitoring does not see their writes (see [below](#realtime-library-monitoring-and-shared-storage)) |
| Attaching one disk to several VMs | ❌ never | Filesystem corruption — this is not a supported option on any path |

Availability caveat for Paths 1–2: making Jellyfin the storage server couples
every consumer to this VM — when it is down or being rebuilt, `/media-jellyfin`
is gone everywhere (the `automount,nofail` options keep consumers from hanging,
but incoming transfers stall). A practical upside of serving from a local disk: writes
arriving through the NFS server still pass through the VM's filesystem layer, so
Jellyfin's realtime library monitoring picks up files written by consumers.

### Realtime library monitoring and shared storage

The upstream Jellyfin documentation describes realtime monitoring as
unsupported on network filesystems. The precise rule is narrower:

> **inotify's boundary is the kernel, not the storage.** Jellyfin's realtime
> monitoring uses inotify, which only sees file changes that pass through the
> VFS layer of the *same Linux kernel* Jellyfin runs on. Where the bytes
> physically live is irrelevant — what matters is *whose kernel the write went
> through*.

Consequences per path:

| Writer | Path 1–2 (VM-local disk, NFS-exported) | Path 3 (NAS mounted directly) |
|---|---|---|
| Jellyfin VM itself | ✅ seen | ✅ seen (local writes through an NFS/CIFS client mount still raise inotify events) |
| Consumer module (a VM writing new media) | ✅ seen — its NFS writes are served *by the Jellyfin VM's kernel* | ❌ invisible — the consumer mounts the NAS itself; its writes never touch Jellyfin's kernel, and NFS/CIFS push no change notifications to other clients |
| Any other machine / app on the NAS | (no such writer in Paths 1–2) | ❌ invisible, same reason |

Note that "same Proxmox cluster" or "same NAS share" does **not** help: every VM
is its own kernel. Two modules only share an inotify event stream if they share
a kernel — in TAPPaaS terms, only if the writer's traffic terminates *inside*
the Jellyfin VM, which is exactly what the Paths 1–2 NFS export arrangement does
and Path 3 does not.

When realtime monitoring can't see the writer (Path 3, or any out-of-band
writer), close the gap at the application layer instead:

1. **Best: the writer notifies Jellyfin on import.** Sonarr/Radarr ship this
   built-in (Settings → Connect → Emby/Jellyfin, enable "Update Library"); any
   other writer can call the Jellyfin API's library-refresh endpoint in a
   post-processing hook. This is a plain HTTP call, so VM/kernel/cluster
   boundaries don't matter — it is more reliable than inotify and recommended
   on all paths.
2. **Fallback: scheduled library scans** (Dashboard → Libraries). Incremental
   scans are cheap, so hourly/daily costs little and catches anything that
   slipped through (manual copies, NAS-side apps).

Unrelated to monitoring but often conflated with it: **hardlinks/instant renames
survive every path.** Promoting a newly added file into `Movies/`/`TV/` only
requires `downloads/` and the library to sit on the same filesystem/export — the kernel
performing the rename doesn't matter. Keeping the single shared store never
costs you that.

If realtime monitoring is enabled on a large library, the kernel's default
inotify watch limit can be exhausted (`Error in Directory watcher … user limit
(8192) … reached`). Raise it in `jellyfin.nix`:
`boot.kernel.sysctl."fs.inotify.max_user_watches" = 524288;` and run
`./update.sh jellyfin`.

### Choosing a path

**Checking what you have:**

```bash
# Proxmox storage type + content (pvesm alloc needs content 'images')
pvesm status
cat /etc/pve/storage.cfg
# Filesystem/label on a physical disk (USB, LUN)
lsblk -f
blkid /dev/sdX
```

### Path 1 — `mediaStorage: allocate` — new virtual disk (default)

Works on any storage `pvesm alloc` can allocate on: ZFS pools (`tankb1`/`tankb2`),
LVM, directory storage, or an NFS/CIFS storage with `images` content. Set
`mediaDiskStorage` and `mediaDiskSize` — the size is required for **all** of these
backends, not only ZFS. Nothing else to do: the install allocates and formats
the disk on first run and leaves it alone forever after.

- ZFS pool on a local disk: `config-storage.sh --pool tankb2=single:sdX`, then
  `"mediaDiskStorage": "tankb2"`.
- **Empty** iSCSI LUN: wrap it as a ZFS pool on the node first (attach the LUN,
  `zpool create` on it, register with `pvesm`), then use that pool name. A raw
  `iscsi`-type Proxmox storage will NOT work here — `pvesm alloc` cannot allocate
  on it. ⚠ `zpool create` wipes the LUN; only for LUNs without data. Note the
  iSCSI session must be up before pool import at node boot — do a deliberate
  reboot test.
- NFS/CIFS storage with `images`: works unchanged, but media then lives inside an
  opaque raw image file on the share — the NAS cannot see individual files.
  Usually Path 3 is the better fit for a NAS.

### Path 2 — `mediaStorage: attached` — a disk you provide (with or without media)

Set the mode, attach the disk as scsi2, then run
`./services/mediaserver/setup-media-disk.sh` to prepare it (relabel or format,
with confirmation). In this mode the module never allocates or formats anything
on its own — a recovery run on a VM missing its disk fails with instructions
instead of creating an empty disk.

```bash
# Populated iSCSI LUN, mapped directly:
pvesm add iscsi media-iscsi --portal <NAS-IP> --target <iqn>
qm set 360 --scsi2 media-iscsi:0.0.0.scsi-<lun>
# USB / local disk passthrough (use by-id so it survives reboots):
qm set 360 --scsi2 /dev/disk/by-id/<disk-id>
```

- Disk with existing media (ext4): `setup-media-disk.sh` offers the
  non-destructive relabel to `jellyfin-media` — all data kept. An empty disk is
  formatted instead, after confirmation.
- Other filesystems (e.g. an NTFS USB drive): edit `fileSystems."/media"` in
  `jellyfin.nix` — `fsType = "ntfs3"`, mount by UUID, and set
  `uid`/`gid` mount options (NTFS has no POSIX ownership, so the tmpfiles chown
  rules become no-ops). Works, but NTFS on a 24/7 exported mount is best treated
  as a transfer vehicle — prefer migrating the content to ext4.
- Fix ownership after first mount: `chown -R jellyfin:jellyfin /media`
  (uid/gid 993). Existing folder names are untouched — tmpfiles only creates the
  standard folders if missing; point your Jellyfin libraries at whatever layout
  the disk has.
- Ordering: the VM must exist before `qm set`. It's fine to run
  `install-module.sh` first — with `mediaStorage: attached` it stops at the
  disk step with instructions. Attach the disk, run `setup-media-disk.sh`,
  re-run `install-module.sh` — everything is idempotent. (Run
  `setup-media-disk.sh` without a disk attached and it prints the exact attach
  commands and exits without changing anything.)

### Path 3 — `mediaStorage: share` — network share mounted directly (no scsi2)

For media that should stay as native files on a NAS: set the mode and the
`mediaShare*` keys in `jellyfin.json` (see [Configure](#configure)) and run
`./update.sh jellyfin` — the `/media` mount is generated from the config; the
install skips all disk handling and only verifies the mount. NFS works out of
the box (the NAS's export list controls access, no password involved).

CIFS/SMB shares authenticate with a username/password, which must not go into
`jellyfin.json` — put it in a root-only file on the VM and reference it from
the mount options:

```bash
ssh tappaas@jellyfin.<zone>.internal
sudo sh -c 'printf "username=media\npassword=YOURPASSWORD\n" > /etc/nixos/smb-secrets && chmod 600 /etc/nixos/smb-secrets'
```

```json
"mediaShareType": "cifs",
"mediaShareOptions": "credentials=/etc/nixos/smb-secrets,uid=993,gid=993,nofail,_netdev,x-systemd.automount"
```

(`uid`/`gid` 993 = the `jellyfin` user; CIFS has no POSIX ownership, so the
mount sets it.)

This is the most naturally shared path — the NAS serves any number of clients —
but **the sharing role moves from this module to the NAS**, which changes three
things:

- ⚠ `jellyfin:storage` should not be used: re-exporting an NFS mount over this
  module's own NFS server is fragile. Consumer modules (media writers) must
  mount the NAS directly instead, and permission mapping (squash/uid rules) is
  configured on the NAS, not by this module.
- ⚠ **Realtime library monitoring does not see other writers.** Jellyfin will
  not notice files added by other modules, other machines, or apps on the
  NAS itself — only its own writes (see [Realtime library monitoring and shared
  storage](#realtime-library-monitoring-and-shared-storage) for why, and why
  this is a kernel boundary rather than a NAS limitation). Compensate with the
  Sonarr/Radarr → Jellyfin "Update Library" connection or an API-triggered scan
  after each completed import, plus a scheduled scan as a safety net.
- Keep `downloads/` and the library on the **same NAS filesystem/share** so that
  promoting a finished file into `Movies/`/`TV/` stays an instant rename
  rather than a full copy over the network.

### Changing storage after install

`/media` is the stable interface, so all of these are routine:

| Change | How |
|---|---|
| Grow the disk | `qm resize 360 scsi2 +2T`, then in the VM `sudo resize2fs /dev/disk/by-id/scsi-0QEMU_QEMU_HARDDISK_drive-scsi2` (the disk has no partition table) |
| Move to another storage | `qm disk move 360 scsi2 <storage>` — live, contents and label preserved, nothing changes in the VM |
| Replace the disk | stop jellyfin, `umount /media`, `qm set 360 --delete scsi2`, attach the new disk, run `./services/mediaserver/setup-media-disk.sh` to label/format it, `mount /media` |
| Switch to a NAS mount | copy data across, apply Path 3, then detach and `pvesm free` the old volume |

After any change, update `jellyfin.json` (including `mediaStorage` if the mode
changed) and re-run `install-module.sh jellyfin`. This refreshes the deployed
config copy in `/home/tappaas/config/` that recovery runs read. The mode is
what keeps recovery safe: `attached`/`share` never allocate anything, and
`allocate` recreates exactly what the config declares — so keep
`mediaDiskStorage`/`mediaDiskSize` accurate.

### Backups and reboot behaviour

- scsi2 is included in PBS backup jobs unless you set `backup=0`
  (`qm set 360 --scsi2 <volume>,backup=0`). Re-check `qm config 360` after disk
  moves/re-attachments — the flag can silently reset to default-on. For a
  multi-TB media disk backed by a NAS with its own protection you likely want it
  off.
- The `/media` mount uses `nofail` + automount: a missing disk fails *quietly*
  (Jellyfin starts over an empty mount point). Test one full node reboot after
  setting up whichever path you chose, especially with iSCSI in the chain.

## Install

Run from the tappaas-cicd mothership, in this module's directory:

```bash
ssh tappaas@tappaas-cicd.mgmt.internal
cd "${TAPPAAS_REPO:-/home/tappaas/TAPPaaS}"/src/home/jellyfin
install-module.sh jellyfin
```

Duration: ~5–10 minutes (NixOS clone + rebuild + disk provisioning).

`install-module.sh` will:
1. Clone the NixOS template VM (vmid 8080)
2. Assign network, VLAN, and firewall rules
3. Apply `jellyfin.nix` via `update.sh`
4. Run `services/mediaserver/install-service.sh` — acts on the `mediaStorage`
   mode: `allocate` creates and formats the disk on first run; `attached` and
   `share` only verify and, if something is missing, stop with instructions
5. Print the web UI URL

With `mediaStorage: attached`, prepare the disk once with
`./services/mediaserver/setup-media-disk.sh` (interactive; relabels or formats
with confirmation — cancelling with Ctrl+C or plain Enter is always safe), then
re-run the install.

## First-Time Setup

1. Open `https://jellyfin.<your-domain>` — the setup wizard appears on first visit
2. Create an admin account
3. Add libraries under **Dashboard → Libraries**:

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
To update the Jellyfin package version, change `appVersion` in `jellyfin.json` and re-run.

## Troubleshooting

**Jellyfin web UI not reachable**
```bash
ssh tappaas@jellyfin.<zone>.internal 'sudo journalctl -u jellyfin -n 50'
```

**/media not mounted**
```bash
ssh tappaas@jellyfin.<zone>.internal 'sudo mount /media'
# If that fails, re-run the mediaserver service (non-destructive verify + mount):
./services/mediaserver/install-service.sh
```

**NFS share not accessible from another VM**
```bash
# On the Jellyfin VM:
sudo exportfs -v      # Should list /media
sudo systemctl status nfs-server
# On the consumer VM:
showmount -e jellyfin.<zone>.internal
```

## Variants

Storage variants (dedicated pool, iSCSI, USB, NAS share) are covered in
[Media Storage](#media-storage).

### Hardware transcoding (Intel iGPU)

Add to `jellyfin.nix` inside the `{ ... }` block:
```nix
hardware.opengl = { enable = true; extraPackages = [ pkgs.intel-media-driver ]; };
environment.sessionVariables.LIBVA_DRIVER_NAME = "iHD";
```
Then enable in Jellyfin Dashboard → Playback → Hardware Acceleration → Intel QuickSync (QSV).

### Expose to internet (public access)

Add `"internet"` to `proxyAllowedZones` in `jellyfin.json` and run `./update.sh`.
This publishes the service on the platform's public HTTPS entry (Caddy :80/:443 on
the firewall) — review your TLS/certificate setup in the `network` foundation module
before enabling, and consider whether the `netbird` VPN overlay (already allowed)
covers your remote-access need without public exposure.
