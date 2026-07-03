# Debian satellite (ADR-010 Option 3)

An **alternative to the NixOS satellite** (`../satellite.nix` + `nixos-anywhere`): the
satellite runs stock **Debian 12/13** instead. Selected per satellite with
`satellite-manager install <name> --os debian` (the **default**).

## Why Debian for the satellite

- **Trivial bootstrap** — Hetzner (and most providers) boot Debian directly, so there is
  **no `nixos-anywhere` kexec/reformat**. `satellite-manager` just SSHes into the booted host
  and runs `provision-debian.sh`.
- **OS diversity = a security win for the vault (§7.3).** The backup satellite is the one node
  that must survive a compromise of everything else. Running it on a *different, officially
  supported* base means a nixpkgs / `nixos-anywhere` / community-flake **supply-chain
  compromise hits the cluster but not the off-site vault**.
- **Official, supported PBS** for the backup role — `proxmox-backup-server` from the Proxmox
  Debian repo, not an unofficial Nix port or OCI image (see implementation-doc Q8).

## How it works

`satellite-manager` (on `tappaas-cicd`) drives everything; the **home/OPNsense side is
identical** to the NixOS path (same `edge` tunnel, same `admin` WG server, same
`opnsense-wg.sh`/`admin-vpn.sh` tooling). Only the satellite half changes:

1. `sat_gen_debian_configs` (in `manager/satellite-manager/lib/provision.sh`) renders the
   per-role config files from the same `SAT_*` derived defaults that generate
   `satellite-settings.nix`:

   | File | Role | Replaces (in satellite.nix) |
   | ---- | ---- | --------------------------- |
   | `wg-infra.conf` | always | `networking.wireguard.interfaces.wg-infra` |
   | `nftables.conf` | always (+admin-vpn NAT) | `networking.firewall` + `networking.nftables.tables.adminvpn` |
   | `nginx-stream.conf` | reverse-proxy | `services.nginx.streamConfig` |
   | `99-tappaas-ipforward.conf` | admin-vpn | `boot.kernel.sysctl."net.ipv4.ip_forward"` |
   | `20auto-upgrades` + `52tappaas-unattended-upgrades` | always | `system.autoUpgrade` (Debian: security-only + reboot window) |

2. `sat_assemble_debian_deploy` adds **`provision-debian.sh`** (this dir) to the rendered set.
3. `sat_provision_debian` SSHes to `root@<ip>` (operator key via a forwarded agent — cicd holds
   no standing key, §7.3), ships the deploy dir, and runs `provision-debian.sh`, which
   `apt install`s the packages, installs the configs, generates the on-host WireGuard key
   (never leaves the host), enables the services, and turns on unattended security upgrades.
4. Back on cicd, the flow rejoins the shared path: read back the satellite's wg public key →
   wire the OPNsense peer → verify the handshake.

## Self-patching

`unattended-upgrades` applies **security-origin updates only** (minimal churn — right for a
set-and-forget vault) and auto-reboots in a window (`SAT_REBOOT_TIME`, default `03:30`). For a
backup node, keep that window outside the pull-sync schedule so a reboot never interrupts a sync.

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
the `remote` + pull `sync-job`. `satellite-manager` also adds the OPNsense **`edge → home-PBS:8007`**
rule and widens the satellite's wg `AllowedIPs` to reach home PBS — and nothing else in the cluster.

### Home-side prerequisites (operator, one-time)

1. **Reachability:** home PBS must be reachable at `backup.pull.homePbsHost` over the tunnel
   (satellite-manager adds the `edge → PBS:8007` rule + AllowedIPs).
2. **Read-only token** on home PBS (so a compromised satellite can only *read* home's encrypted chunks):
   ```bash
   proxmox-backup-manager user generate-token satellite@pbs pull
   proxmox-backup-manager acl update /datastore/<home-store> DatastoreReader --auth-id 'satellite@pbs!pull'
   ```
   Provide the printed **secret** to satellite-manager out-of-band — `TAPPAAS_SAT_PBS_TOKEN=<secret>`
   (or `TAPPAAS_SAT_PBS_TOKEN_FILE=<path>`); it is shipped as a `0600` file and **never committed**.
3. Put the non-secret pull config in the satellite JSON: `backup.pull.{homePbsHost,homeDatastore,authId,fingerprint,schedule}`.

Without the token, `provision-backup.sh` still installs PBS + the datastore and prints this runbook;
provide the token and re-run to activate the pull.

## Files

| File | Purpose |
| ---- | ------- |
| `provision-debian.sh` | idempotent, role-gated on-host installer (base: tunnel/proxy/admin-vpn/patching) |
| `provision-backup.sh` | backup role: official PBS install + datastore + pull remote/sync-job |
| `README.md` | this file |

The rendered config files are **not committed** — they are generated per-deployment by
`satellite-manager` from `~/config/satellite-<name>.json` (the manager owns the config).
Design reference: [ADR-010](../../../../docs/ADR/ADR-010-vps-satellite-reverse-proxy-backup.md),
Q8 in the [implementation doc](../../../../docs/design/ADR-010-implementation.md).
