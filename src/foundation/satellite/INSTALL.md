# satellite — Installation

Primary audience: TAPPaaS admin.

> **When do I need this?** Only if your site has **no usable public IP** (CGNAT, dynamic
> IP, no inbound port-forwarding) and you want to publish services, reach the management
> plane remotely, or hold an off-site backup. A site with a real public IP does **not**
> need a satellite. This step is **optional and conditional** — it is *referenced* from
> the TAPPaaS install, never run automatically.
>
> **Status:** runbook scaffold (ADR-010 P1). The `satellite-manager` flow it describes is
> built in packages P2–P6; steps below are the target procedure.

The satellite is **not** installed with `install-module.sh` — the operator front door is
the `satellite-manager` CLI on `tappaas-cicd`. The module's `install.sh` merely delegates
to it. Design reference:
[ADR-010](../../../docs/ADR/ADR-010-vps-satellite-reverse-proxy-backup.md).

## Prerequisites

1. A running TAPPaaS foundation (`network` + `tappaas-cicd`; plus `backup` if you want
   the backup role). Do this **after** the foundation is up.
2. Decide which **roles** you need: `reverse-proxy`, `admin-vpn`, `backup` (any
   combination).
3. Allocate a host with a **stable public IPv4** and root SSH (Tier A — portal, default):
   1. In the Hetzner Cloud console create a server: image **Debian 12**, type **`cx23`**
      (x86 Intel, cheapest current line; bump to cx33+ for a backup-heavy node —
      `cax11` is the ARM alternative).
   2. **SSH key — attach your OPERATOR key (your workstation), NOT a `tappaas-cicd`
      key.** The key you attach becomes the satellite's standing root. Per ADR-010 §7.3
      the satellite must NOT be rootable from `tappaas-cicd` (a compromised mothership
      must never own the off-site vault). `tappaas-cicd` gets only an **ephemeral**
      provisioning credential during install, which is revoked afterwards.
   3. Note its **public IP**.
4. Backup role only — create the S3 bucket **with Object Lock**:
   1. Create a Hetzner **Object Storage** bucket **with Object Lock enabled at
      creation** — this cannot be added later. Object Lock makes the off-site copy
      immutable (WORM), so it survives even a satellite compromise.
   2. Create S3 credentials scoped to that bucket.

> Tier B (opt-in, fully automated): instead of the portal, store a Hetzner **API token**
> as a TAPPaaS secret and let `satellite-manager` create the server via the `hcloud`
> API. The token can create **and destroy** servers — see ADR-010 §7.3 before enabling.

> Alternative backup backend: a dedicated block **Volume** with a local ZFS datastore
> (set `backup.backend = "volume"`). Weaker immutability (ZFS snapshots), must be
> pre-sized.

> Unlike other modules you do **not** hand-edit a json override: `satellite-manager`
> **owns the config** — you pass parameters and it writes
> `~/config/satellite-<name>.json` itself. `src/foundation/satellite/satellite.json` is
> the operator-facing template of that file.

## Install

Run over `ssh -A` so your operator key is available for the post-provision pubkey
read-back (§7.3: cicd holds no standing key on the satellite):

    satellite-manager install <name> \
        --public-ip <satellite-ip> \
        --sshkey ~/.ssh/<operator-key>.pub \
        [--bucket <s3-object-lock-bucket>]   # provide → enables the backup role
        [--provider hetzner] [--s3-endpoint <url>] [--roles reverse-proxy,admin-vpn]

- **Sensible defaults:** roles = `reverse-proxy,admin-vpn` (+ `backup` automatically when
  you pass `--bucket`). `--sshkey` takes a key string or a path to a `.pub` file.
  Add `--dry-run` to preview.
- Re-running `satellite-manager install <name>` with no flags re-provisions from the
  saved config.

`satellite-manager` then:

1. Writes `~/config/satellite-<name>.json` from your parameters (the manager owns the
   JSON).
2. Deploys the OS onto the host — stock Debian provisioning by default, or NixOS via
   `nixos-anywhere` (kexec from the stock image — no rescue mode); see `debian/README.md`.
3. Brings up the WireGuard listener; the **home (OPNsense) end dials out** with
   keepalive.
4. Reads back the satellite's WireGuard **public** key (its private key never leaves the
   host).
5. Adds the `edge` (+ `admin`, for admin-vpn) overlay zone and the least-privilege,
   role-gated firewall rules; reconciles.
6. Points the public DNS record at the satellite; **revokes the provisioning credential**
   (leaving only your operator key) and switches the host to pull-based `autoUpgrade`.
7. For the backup role: registers the home PBS as a **pull remote** + configures the S3
   datastore + Object-Lock.

## Post-install

None. Updates are pull-based and automatic — the satellite `autoUpgrade`s from a
pinned/signed ref (a satellite-manager default, not a config field); `tappaas-cicd`
never SSHes in to push (ADR-010 §7.3). `update.sh` / `satellite-manager update <name>`
only reconciles the home-side wiring and config.

## Verification

    satellite-manager status <name>

(The module's `./test.sh` runs fast contract checks; a live reverse-proxy end-to-end
test gates behind `TAPPAAS_TEST_DEEP=1` and self-skips when no satellite is present.)

| Check | Expected |
|-------|----------|
| reverse-proxy: browse a published name from off-LAN | resolves to the satellite, served via Caddy at home; Caddy logs show the **real client IP** (PROXY protocol) |
| admin-vpn: bring up your admin WireGuard peer | can reach a node `:8006`, the OPNsense UI, PBS `:8007`, and SSH to a host |
| backup: `satellite-manager status <name>` | pull sync converged |
| backup: test restore **with** the encryption key | succeeds — and **fails without** the key |

## Troubleshooting

**Do I still need the satellite?**
Decommission with `satellite-manager remove <name>` — it tears down the OPNsense
WireGuard peer, removes the `edge`/`admin` zones (reconcile), reverts DNS, and forgets
the secrets, falling back cleanly to the prior reachability model. **Destroying the VPS
itself stays manual** (your cloud account), unless the Tier-B API token is configured.

**Where does this fit in the TAPPaaS install?**
The main install does **not** run this. At the *"does this site need a satellite?"*
decision point (after `network`/`tappaas-cicd`/`backup`), the install guide points here.
Keeping it conditional is by design — the satellite is the first **optional** foundation
module (ADR-010 §5.7).
