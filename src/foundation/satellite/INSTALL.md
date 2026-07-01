# Installing a TAPPaaS satellite

> **When do I need this?** Only if your site has **no usable public IP** (CGNAT, dynamic IP,
> no inbound port-forwarding) and you want to publish services, reach the management plane
> remotely, or hold an off-site backup. A site with a real public IP does **not** need a satellite.
>
> This step is **optional and conditional** — it is *referenced* from the TAPPaaS install, never
> run automatically. Do it **after** the foundation is up (`network`, `tappaas-cicd`, and — for the
> backup role — `backup`).
>
> **Status:** runbook scaffold (ADR-010 P1). The `satellite-manager` flow it describes is built in
> packages P2–P6; steps below are the target procedure.

Design reference: [ADR-010](../../../docs/ADR/ADR-010-vps-satellite-reverse-proxy-backup.md).

---

## 0. Prerequisites

- A running TAPPaaS foundation (`network` + `tappaas-cicd`; plus `backup` if you want the backup role).
- Decide which **roles** you need: `reverse-proxy`, `admin-vpn`, `backup` (any combination).
- A host with a **stable public IPv4** and root SSH. The reference is a **Hetzner Cloud** VPS.

## 1. Allocate the host

### Tier A — portal (default)

1. In the Hetzner Cloud console create a server: image **Debian 12**, type **`cx23`** (x86 Intel,
   cheapest current line; bump to cx33+ for a backup-heavy node — `cax11` is the ARM alternative).
2. **SSH key — attach your OPERATOR key (your workstation), NOT a `tappaas-cicd` key.** The key you
   attach becomes the satellite's standing root. Per ADR-010 §7.3 the satellite must NOT be rootable
   from `tappaas-cicd` (a compromised mothership must never own the off-site vault). So the standing
   key is your out-of-band operator key; `tappaas-cicd` gets only an **ephemeral** provisioning
   credential during install, which is revoked afterwards.
3. Note its **public IP**.

> Tier B (opt-in, fully automated): instead of the portal, store a Hetzner **API token** as a TAPPaaS
> secret and let `satellite-manager` create the server via the `hcloud` API. The token can create
> **and destroy** servers — see ADR-010 §7.3 before enabling it.

### Backup role only — create the S3 bucket **with Object Lock**

If you want the `backup` role on the **S3 backend** (the default):

1. Create a Hetzner **Object Storage** bucket **with Object Lock enabled at creation** — this cannot
   be added later. Object Lock is what makes the off-site copy immutable (WORM), so it survives even a
   satellite compromise.
2. Create S3 credentials scoped to that bucket.

> Alternative backend: a dedicated block **Volume** with a local ZFS datastore (set
> `backup.backend = "volume"`). Weaker immutability (ZFS snapshots) and must be pre-sized.

## 2. Register the satellite

On `tappaas-cicd`, copy the example config and edit it:

```bash
cp ~/src/foundation/satellite/satellite.json ~/config/satellite-<name>.json
# edit: roles, provider, host.publicIp + host.operatorSshKeys, and (backup role) backup.s3.{endpoint,bucket}
# (everything else — tunnel /31, ports, per-role tuning, backup mechanics, update mode — is a sensible default)
```

## 3. Install

```bash
satellite-manager install <name>
```

`satellite-manager` will:

1. Deploy NixOS onto the host with `nixos-anywhere` (kexec from the stock image — no rescue mode).
2. Bring up the WireGuard listener; the **home (OPNsense) end dials out** with keepalive.
3. Read back the satellite's WireGuard **public** key (its private key never leaves the host).
4. Add the `edge` (+ `admin`, for admin-vpn) overlay zone and the **least-privilege, role-gated**
   firewall rules; run `zone-manager reconcile --apply`.
5. Point the public DNS record at the satellite (`dns-manager`).
6. **Revoke the provisioning credential** and switch the host to pull-based `autoUpgrade`.
7. For the backup role: register the home PBS as a **pull remote** and configure the S3 (or volume)
   datastore + Object-Lock retention.

## 4. Verify

```bash
satellite-manager status <name>
```

- **reverse-proxy:** browse a published name from off-LAN → it resolves to the satellite and serves
  via Caddy at home; confirm Caddy logs show the **real client IP** (PROXY-protocol).
- **admin-vpn:** bring up your admin WireGuard peer → reach a node `:8006`, OPNsense UI, PBS `:8007`,
  and SSH to a host.
- **backup:** `satellite-manager status <name>` shows the pull sync converged; run a **test restore**
  *with* the encryption key (it must fail *without* it).

## 5. Update

Pull-based and automatic — the satellite `autoUpgrade`s from a pinned/signed ref (a satellite-manager default, not a config field).
`tappaas-cicd` never SSHes in to push (ADR-010 §7.3).

## 6. Decommission

```bash
satellite-manager remove <name>
```

Tears down the OPNsense WireGuard peer, removes the `edge`/`admin` zones (reconcile), reverts DNS, and
forgets the secrets — falling back cleanly to the prior reachability model. **Destroying the VPS
itself stays manual** (your cloud account), unless the Tier-B API token is configured.

---

## Where this fits in the TAPPaaS install

The main install does **not** run this. At the *"does this site need a satellite?"* decision point
(after `network`/`tappaas-cicd`/`backup`), the install guide points here. Keeping it conditional is by
design — the satellite is the first **optional** foundation module (ADR-010 §5.7).
