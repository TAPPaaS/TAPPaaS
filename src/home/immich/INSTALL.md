# Immich — Installation

## Prerequisites

- TAPPaaS foundation installed (cluster, network, templates, tappaas-cicd,
  backup, identity)
- NixOS template `8080` available for cloning
- Free VMID `361` and capacity for the photo disk (default 500G on `tanka1`)
  on **both** the primary node and the HA node: it is replicated (`cluster:ha`)
- Run everything from the `tappaas-cicd` mothership as the `tappaas` user

## Configure

Edit `immich.json` before installing if the defaults don't fit:

| Key | Default | Notes |
|---|---|---|
| `cores` / `memory` | 4 / 8192 | With `machineLearning: false`, 4096 MB is enough |
| `diskSize` | 32G | OS disk (Postgres, ML model cache live here) |
| `mediaStorage` | `allocate` | `allocate` \| `attached` \| `share` — see Photo Storage |
| `mediaDiskStorage` / `mediaDiskSize` | `tanka1` / `500G` | Used in `allocate` mode. Keep it on `tanka`: only that tier is replicated for HA |
| `HANode` / `replicationSchedule` | next node / `*/15` | `cluster:ha` — failover node, and how much can be lost (minutes) |
| `machineLearning` | `true` | Smart search + face recognition (`immich-machine-learning`) |
| `proxyAllowedZones` | `home, netbird, internet` | Drop `internet` for a private-only deployment (mobile then needs Netbird) |

## Photo Storage

The photo library lives on a dedicated disk mounted at `/var/lib/immich`
(Immich's `mediaLocation`). Three paths, selected by `mediaStorage`:

### Path 1 — `allocate` — new virtual disk (default)

The module allocates `mediaDiskSize` on `mediaDiskStorage`, attaches it at
slot `scsi2`, formats it ext4 with label `immich-data`. Fully automatic,
consent is the config declaration; an existing disk at `scsi2` is never
touched.

### Path 2 — `attached` — a disk you provide

Attach a USB disk or iSCSI LUN at slot `scsi2` yourself, then prepare it
interactively (relabel is non-destructive; formatting always asks):

```bash
qm set 361 --scsi2 /dev/disk/by-id/<disk-id>        # USB/local disk
./services/photostorage/setup-media-disk.sh          # relabel/format with confirmation
```

### Path 3 — `share` — NAS share mounted directly (no scsi2)

Set in `immich.json`: `mediaShareHost`, `mediaShareExport`,
`mediaShareType` (`nfs`|`cifs`), optional `mediaShareOptions`. `update.sh`
generates the mount into the managed `media-mount` block of `immich.nix`.
Note: Immich runs as the `immich` user — the share must map that user's
writes correctly (NFS: `all_squash,anonuid=<uid>`; CIFS: `uid=` mount
option). Advanced path; prefer 1 or 2.

### Changing storage after install

Photos live under `/var/lib/immich`. To migrate, stop `immich-server`, copy
the full directory tree (preserving ownership), swap the disk/label, re-run
`./services/photostorage/install-service.sh` and `./update.sh`.

## Install

```bash
# on tappaas-cicd
install-module.sh immich
```

This resolves the dependencies (VM 361 from template 8080, PBS backup job,
Caddy proxy entry, firewall rules), provisions the photo disk, applies
`immich.nix`, waits for the API, and bootstraps the admin account. The
generated admin password is printed **once** — store it and change it after
first login. The admin sign-up endpoint is open until the first admin
exists; install.sh claims it in the same run, so do not interrupt the
install between "API ready" and the summary.

## First-Time Setup

1. Open `https://immich.<your-domain>` and log in as the printed admin.
2. Administration → Settings — review Storage Template, Backup, Jobs.
3. Install the **Immich mobile app** (iOS/Android), enter the same URL, log
   in — enable background backup for the camera roll.
4. Smart search / face recognition run automatically as photos arrive. The
   first ML job downloads models (~1–2 GB) to `/var/cache/immich` — the VM
   needs outbound internet (srvHome has it by default).

## Authentik OIDC (SSO for all users)

SSO is fully automatic — no manual configuration is required in either the
Authentik or the Immich admin UI. See [README.md → Authentication & SSO](README.md#authentication--sso)
for how the mechanism works; this section covers the parts an operator may
need to act on.

**Restricting access beyond "everyone with a TAPPaaS login"**:

```bash
authentik-manager app-bind-groups immich --group <narrower-group>
```

replaces the default `users` binding — see `identity-controller/README.md`.

**Per-user storage quota** (optional): create a Scope Mapping named e.g.
`immich` that returns `{"immich_quota": <GiB>}`, add it to `identity.scopes`
in `immich.json`, and set a *Storage quota claim* in Immich's admin settings
— the automation does not set this on its own, since there is no established
convention yet for passing it through the module JSON.

**Hardening for internet exposure**: after verifying OAuth works, disable
*password login* on Immich's OAuth settings page — authentication then goes
through Authentik's rate-limited, MFA-capable flows. Keep one browser
session logged in while testing; this step is **not** automated, since
enabling it before OAuth is confirmed working risks locking out the
operator entirely.

**Lockout recovery** (password login disabled and OAuth broken): the
`immich-admin` CLI ships on the VM:

```bash
# on the immich VM
sudo systemctl stop immich-server
sudo -u immich immich-admin enable-password-login   # or: reset-admin-password
sudo systemctl start immich-server
```

**If the admin API key is missing** (`immich-configure-oidc.service` logs
that `/etc/secrets/immich-admin-api-key` is absent): create one manually in
the admin UI (Account Settings → API Keys, permissions `systemConfig.read` +
`systemConfig.update`), place it at `/etc/secrets/immich-admin-api-key` on
the VM (mode 600), then `sudo systemctl restart immich-configure-oidc.service`.

**Verifying the automation**: `journalctl -u immich-configure-oidc` on the
VM shows the last run. `identity/test.sh` and `test.sh`'s OIDC/OAuth Status
check assert the Authentik side and the Immich-side `oauth.enabled` flag
respectively.

## Verification

```bash
./test.sh          # on tappaas-cicd — 10 checks incl. DB extensions, mounts, API, OIDC
```

## Updating Immich

```bash
update-module.sh immich      # or ./update.sh from the module directory
```

Immich versions come from the platform's pinned nixpkgs (template rev,
applied by the engine). Keep server and mobile app in step — Immich mobile
apps require a matching/newer server; update the module before the phone
apps auto-update, see <https://immich.app/docs/install/upgrading>.

## Troubleshooting

- **`immich-server` restart loop** — the data disk is missing/unmounted
  (this is the intended fail-fast via `RequiresMountsFor`). Check
  `lsblk`/`qm config 361`, then re-run
  `./services/photostorage/install-service.sh` (non-destructive verify +
  mount).
- **Smart search returns nothing** — first ML job still downloading models;
  check `journalctl -u immich-machine-learning`.
- **Mobile login bounces** — verify all three redirect URIs are on the
  Authentik provider (admin UI → Applications → Providers → immich):
  `/auth/login`, `/user-settings`, and `/api/oauth/mobile-redirect` — all
  three come from `immich.json`'s `identity.oidcRedirectPaths`, so a typo
  there means re-run `update-module.sh immich` after fixing it. Also check
  `journalctl -u immich-configure-oidc` on the VM for
  `oauth.mobileRedirectUri`/`IMMICH_PUBLIC_URL` — if `IMMICH_PUBLIC_URL`
  never got set, the mobile override stays off even though web login
  works fine.
- **Build fails with a pgvecto.rs/PostgreSQL 17 assertion** — do not remove
  `database.enableVectors = false` from `immich.nix`; with stateVersion
  25.05 the option defaults to the legacy extension, which is incompatible
  with PostgreSQL 17.

## Variants

### Disable machine learning (small VM)

```jsonc
// immich.json
"machineLearning": false,
"memory": "4096"
```

then `update-module.sh immich`. Re-enable any time; models download on the
next job run.

### Hardware transcoding (Intel iGPU)

Pass the GPU through to VM 361, then in `immich.nix`:

```nix
services.immich.accelerationDevices = [ "/dev/dri/renderD128" ];
hardware.graphics.enable = true;
```

and set the transcoding hardware acceleration API in Immich's admin
settings (Video Transcoding → QSV/VAAPI).

### Private-only deployment (no internet exposure)

Remove `"internet"` from `proxyAllowedZones` and re-run the proxy step
(`update-module.sh immich`). Mobile auto-upload away from home then requires
the Netbird VPN on the phone.
