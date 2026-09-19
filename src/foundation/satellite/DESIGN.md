# satellite — Design notes

Design and implementation detail displaced from README/INSTALL during the Diataxis
restructure (issue #247). Catalog info: [README.md](./README.md); runbook:
[INSTALL.md](./INSTALL.md). Full rationale:
[ADR-010](../../../docs/ADR/ADR-010-vps-satellite-reverse-proxy-backup.md); plan/tracker:
[ADR-010-implementation.md](../../../docs/design/ADR-010-implementation.md).

## Trust model — blind relay + blind vault

The satellite sits off-premises on someone else's hardware and is treated as
**semi-trusted and seizable**. Every role is structured so a compromise of the satellite
yields only **ciphertext** and the ability to *disrupt* — never to read, impersonate, or
decrypt:

| Role | What it does | What it never sees |
| ---- | ------------ | ------------------ |
| `reverse-proxy` | L4 TCP passthrough of `:443`/`:80` to Caddy-on-OPNsense over the WireGuard tunnel (nginx `stream`, PROXY-protocol v2) | TLS plaintext or cert keys — Caddy at home terminates |
| `admin-vpn` | Blind UDP relay of an admin WireGuard session that terminates on OPNsense | admin keys/traffic — admin↔OPNsense is end-to-end |
| `backup` | An off-site PBS datastore the home PBS is **pulled** into (S3 Object-Lock by default) | backup plaintext or the decryption key — client-side encrypted at home |

For the relay roles that is the whole protection, and it needs nothing from the trust
direction: a relay sees only ciphertext, so the mothership may hold root on it. A satellite
is therefore **managed** by default — its key authorized, patched by the sweep (ADR-010
§8.4.2). The vault is different: it must survive a compromised home. **Lockdown** (§8.4.4)
removes the mothership's key, closes home-initiated administration and turns on
self-patching; from then on the cluster holds **no standing root** over it and nothing at
home can reach out to destroy the off-site copy (ADR-010 §7.3).

## Connectivity

- **Tunnel:** WireGuard, **home dials out, satellite listens** (PersistentKeepalive keeps
  the CGNAT pinhole open). Dedicated `edge` overlay zone, `/31` link (`10.255.0.0/31`).
- **Admin VPN:** terminates on OPNsense into a dedicated `admin` overlay zone → mgmt
  plane; the satellite only UDP-relays it.
- **Least privilege:** the `edge` zone may reach *only* the endpoints its active roles
  require (Caddy ingress / OPNsense admin-WG / home PBS `:8007`) — never broad `mgmt`.

## Module contract (files)

| File | Purpose |
| ---- | ------- |
| `satellite.json` | The template `module add` copies to `config/<instance>.json`: kind, OS, `management: managed`, `zone0: edge`, default roles. Nothing the operator supplies (address, key, location) is pre-filled. All derived values (tunnel `/31` + ports, per-role tuning, backup mechanics) are `lib/provision.sh`'s defaults. Field reference: `schemas/satellite-fields.json`. |
| `install.sh` / `update.sh` / `test.sh` / `delete.sh` | The module contract, thin wrappers over `lib/satellite-lib.sh`: provision + wire; re-ensure edge rules + the `debianhost` update (managed only); config, OPNsense, machine checks (`test.sh <instance>`) or the offline suite (`test.sh`); decommission (only `module delete --decommission` runs it). |
| `lockdown.sh` | Run by `module modify <instance> --lockdown`: the one-way step to the unmanaged vault (§8.4.4). |
| `pbs-path.sh` | `<instance> open\|close`: the nodes' path to a PBS on the satellite (§8.4.3) — an OPNsense rule `mgmt → 10.255.0.0:8007`, and the satellite re-provisioned with the mgmt subnet admitted to `:8007` through the tunnel only. The backup module calls it (a PBS Host's module may ship one); the satellite's update converges it. |
| `lib/satellite-lib.sh` | Loading an instance (a legacy `satellite-<name>.json` too), install, lockdown, decommission, the operator-key and role rules. |
| `lib/provision.sh` | Renders what goes onto the machine (Debian config files, or the NixOS flake), and the edge firewall rules. |
| `lib/tunnel.sh` | Reads the satellite's tunnel key and handshake over SSH. |
| `debian/` | The on-host installers, run in order from one deploy dir — `provision-debian.sh` (base + relay roles), `provision-backup.sh` (the vault, at lockdown), `set-management.sh` (last: authorizes the mothership's key and turns self-patching off, or the reverse); see `debian/README.md`. |
| `satellite.nix` | The NixOS option (`os: nixos`, via `nixos-anywhere`); such a satellite patches itself and is recorded `unmanaged`. |
| `test-vm-creation/` | Deep-test fixture: installs `sat-hello`, probes end-to-end via the satellite public IP, tears down. |

The OPNsense side is `tappaas-cicd/lib/opnsense-wg.sh`, shared with the admin VPN
(`network-manager wgvpn`). Every satellite has a DNS entry `<name>.mgmt.internal` at its
tunnel end (`10.255.0.0`) — the address the Site reaches it at, and what the PBS name
aliases when the satellite is the PBS Host; the mothership itself logs in at `address`. The instance's `name` (default: the instance name) names its
OPNsense objects: server `tappaas-edge-<name>`, peer `tappaas-<name>`.

## Updates and decommissioning

- **Managed** (default): the sweep runs `update.sh`, which re-ensures the edge rules and
  runs the `debianhost` update against `address` — `apt full-upgrade`, a reboot only when
  authorized (`rebootOk` in the scheduled pass, or `--allow-disruption`), else `DEFERRED:`.
  Unattended-upgrades is off, so no reboot bypasses that rule.
- **Lockdown** (`lockdown.sh`): a read-only `remote` login on the Site's PBS (ADR-012 §1.4,
  non-propagating), the `edge → PBS:8007` rule, then on the machine `provision-debian.sh`,
  `provision-backup.sh` and — last — `set-management.sh`, which removes the mothership's key.
  Recorded `unmanaged` only once the mothership is verifiably shut out; a failure before that
  leaves it managed and retryable. The pull syncs the root namespace only (`--max-depth 0`),
  matching the grant.
- **Unmanaged** (locked down): the sweep skips it; it runs security-only unattended-upgrades
  with a reboot window. `test.sh` checks it from OPNsense only.
- `module delete <instance>` unregisters. `module delete <instance> --decommission` runs
  `delete.sh`: the OPNsense peer and tunnel server go, and the edge rules when no other
  satellite needs them. The machine itself is never touched (ADR-026: delete never wipes a
  machine); destroying it is the operator's, in the provider's console.

## Status / roadmap

Implemented on Debian; the module form (ADR-010 §8.4) is #670, its live test #671. See the
[implementation tracker](../../../docs/design/ADR-010-implementation.md#stage-tracker).
