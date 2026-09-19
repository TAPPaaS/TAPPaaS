# Debian satellite (ADR-010 Option 3)

An **alternative to the NixOS satellite** (`../satellite.nix` + `nixos-anywhere`): the
satellite runs stock **Debian 12/13** instead. Selected per satellite with
`os: debian` in the instance's config (the **default**).

## Why Debian for the satellite

- **Trivial bootstrap** — Hetzner (and most providers) boot Debian directly, so there is
  **no `nixos-anywhere` kexec/reformat**. The module just SSHes into the booted host
  and runs `provision-debian.sh`.
- **OS diversity = a security win for the vault (§7.3).** The backup satellite is the one node
  that must survive a compromise of everything else. Running it on a *different, officially
  supported* base means a nixpkgs / `nixos-anywhere` / community-flake **supply-chain
  compromise hits the cluster but not the off-site vault**.
- **Official, supported PBS** for the backup role — `proxmox-backup-server` from the Proxmox
  Debian repo, not an unofficial Nix port or OCI image (see implementation-doc Q8).

## How it works

The satellite module (`module-manager module add satellite`, on `tappaas-cicd`) drives everything; the **home/OPNsense side is
identical** to the NixOS path (same `edge` tunnel, same `admin` WG server, same
`opnsense-wg.sh`/`admin-vpn.sh` tooling). Only the satellite half changes:

1. `sat_gen_debian_configs` (in `../lib/provision.sh`) renders the
   per-role config files from the same `SAT_*` derived defaults that generate
   `satellite-settings.nix`:

   | File | Role | Replaces (in satellite.nix) |
   | ---- | ---- | --------------------------- |
   | `wg-infra.conf` | always | `networking.wireguard.interfaces.wg-infra` |
   | `nftables.conf` | always (+admin-vpn NAT) | `networking.firewall` + `networking.nftables.tables.adminvpn` |
   | `nginx-stream.conf` | reverse-proxy | `services.nginx.streamConfig` |
   | `99-tappaas-ipforward.conf` | admin-vpn | `boot.kernel.sysctl."net.ipv4.ip_forward"` |
   | `20auto-upgrades` + `52tappaas-unattended-upgrades` | installed when unmanaged | `system.autoUpgrade` (Debian: security-only + reboot window) |
   | `roles.env` | always | `ROLES` and `MANAGEMENT` (managed \| unmanaged) |
   | `cicd_key.pub` | managed | the mothership's key, authorized so the sweep can patch the machine |

2. `sat_assemble_debian_deploy` adds **`provision-debian.sh`** (this dir) to the rendered set.
3. `sat_provision_debian` SSHes to `root@<ip>` (the operator key via a forwarded agent),
   ships the deploy dir, and runs `provision-debian.sh`, which `apt install`s the packages,
   installs the configs, generates the on-host WireGuard key (never leaves the host) and
   enables the services. `set-management.sh` then runs last and, by `MANAGEMENT`, either
   authorizes the mothership's key and leaves unattended-upgrades off (**managed**, the
   default: the sweep patches it), or turns unattended security upgrades on and removes that
   key (**unmanaged**, after `--lockdown`).
4. Back on cicd, the flow rejoins the shared path: read back the satellite's wg public key →
   wire the OPNsense peer → verify the handshake.

## Self-patching

Only a locked-down (unmanaged) satellite patches itself. `unattended-upgrades` applies
**security-origin updates only** (minimal churn — right for a set-and-forget vault) and
auto-reboots in a window (`SAT_REBOOT_TIME`, default `03:30`); keep that window outside the
pull-sync schedule so a reboot never interrupts a sync. A managed satellite is patched by the
nightly sweep instead (the `debianhost` update: `apt full-upgrade`, reboots per `rebootOk`),
so unattended-upgrades is off there — an unattended reboot would bypass that rule.

## Backup role (P6) — the vault

The `backup` role makes the Debian satellite an **off-site PBS that PULLS from home**
(ADR-010 §3, D8). This is the reason Debian was chosen (D19): it runs the **official
`proxmox-backup-server`** — no unofficial Nix/OCI port.

**Immutability = the pull model, NOT S3 Object Lock.** PBS does not support S3 Object Lock
(enabling it *corrupts* the datastore — [Bugzilla #6780](https://bugzilla.proxmox.com/show_bug.cgi?id=6780)).
Instead: the satellite pulls with `--remove-vanished false` and **owns prune/GC**, so a
compromised home cannot delete the off-site copies. The **client-side encryption key stays at
home** (§3.2) — the satellite stores only ciphertext.

`provision-backup.sh` (run after the base) installs PBS, creates the local datastore, and wires
the `remote` + pull `sync-job`. The module also adds the OPNsense **`edge → home-PBS:8007`**
rule and widens the satellite's wg `AllowedIPs` to reach home PBS — and nothing else in the cluster.

### Home side — set up by the lockdown

`module-manager module modify <instance> --lockdown` does what used to be operator steps:
it creates the read-only login on the Site's PBS (a `remote` peer, `DatastoreReader` on the
root namespace, not propagated), adds the OPNsense `edge → PBS:8007` rule and the PBS
address to the tunnel's AllowedIPs, reads the PBS certificate's fingerprint, and hands the
login's password to the satellite as the `0600` `pbs-remote-token` — never stored in a
config. The non-secret pull settings are recorded in the instance's `vault.pull`
(`homePbsHost`, `homeDatastore`, `authId`, `fingerprint`, optional `schedule`). See
[../INSTALL.md](../INSTALL.md), "Locking it down as the off-site vault".

## Files

| File | Purpose |
| ---- | ------- |
| `provision-debian.sh` | idempotent, role-gated on-host installer (base: tunnel/proxy/admin-vpn/patching) |
| `provision-backup.sh` | backup role: official PBS install + datastore + pull remote/sync-job (run at lockdown) |
| `set-management.sh` | runs last: `managed` authorizes the mothership's key, unattended-upgrades off; `unmanaged` turns self-patching on and removes that key, refusing if no operator key would remain |
| `README.md` | this file |

The rendered config files are **not committed** — they are generated per-deployment by
the satellite module from the instance's `~/config/<instance>.json`.
Design reference: [ADR-010](../../../../docs/ADR/ADR-010-vps-satellite-reverse-proxy-backup.md),
Q8 in the [implementation doc](../../../../docs/design/ADR-010-implementation.md).
