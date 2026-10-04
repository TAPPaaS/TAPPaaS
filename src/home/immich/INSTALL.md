# Immich — Installation

## Prerequisites

- TAPPaaS foundation installed (cluster, network, templates, tappaas-cicd,
  backup, identity)
- NixOS template `8080` available for cloning
- Free VMID `361` and room for the VM disk on `tanka1` on **both** the
  primary node and the HA node (it is replicated, `cluster:ha`). The disk is
  thin (`thinDisk`), so it takes what the library uses, up to 500G
- Run everything from the `tappaas-cicd` mothership as the `tappaas` user

## Configure

Edit `immich.json` before installing if the defaults don't fit:

| Key | Default | Notes |
|---|---|---|
| `cores` / `memory` | 4 / 8192 | Sized for machine learning, which is always on |
| `diskSize` | 500G | The whole VM: OS, database, ML models **and the photos** — see Photo Storage |
| `thinDisk` | `true` | Thin-provisioned: takes pool space as photos arrive, on both nodes, instead of reserving 500G each up front (#773). Watch the pool — a thin disk can overcommit it |
| `storage` | `tanka1` | Keep it on `tanka`: only that tier is replicated for HA |
| `HANode` / `replicationSchedule` | next node / `*/15` | `cluster:ha` — failover node, and how much can be lost (minutes) |
| `proxyAllowedZones` | `home, netbird, internet` | Drop `internet` for a private-only deployment (mobile then needs Netbird) |

## Photo Storage

Photos live on the VM's own disk, in `/var/lib/immich` — there is no separate
photo disk and nothing to choose. `diskSize` is the room the library has:

- **More room:** `module-manager module modify immich --set diskSize=<size>`
  (config and cluster move together). It is grow-only; NixOS grows the filesystem on
  the next boot (`boot.growPartition`). The platform's disk-threshold check
  watches this disk and can grow it by 50% when it passes its threshold.
- **Where:** `storage` (`tanka1`). Keep it on `tanka` — only that tier is
  replicated for HA, and the photos cannot be re-created.

## Install

```bash
# on tappaas-cicd
install-module.sh immich
```

This resolves the dependencies (VM 361 from template 8080, PBS backup job,
Caddy proxy entry, firewall rules, HA and replication), applies
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
   needs outbound internet (the app zones have it by default).

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

- **Uploads fail, PostgreSQL errors about disk space** — the disk is full.
  Grow it with `module-manager module modify immich --set diskSize=<size>`
  (see Photo Storage).
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
- **Build fails with "`database.enableVectors`/`enableVectorChord` no longer
  has any effect"** — the pinned nixpkgs always uses VectorChord, so neither
  option may be set in `immich.nix`.

## Variants

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
