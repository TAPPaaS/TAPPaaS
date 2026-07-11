# network

Primary audience: TAPPaaS admin.

The TAPPaaS network VM (OPNsense) — routing, zones/VLANs, DNS, DHCP, NAT, per-module
firewall rules and the Caddy reverse proxy for every published service.

## What you get

| Capability | Access from | How |
|------------|-------------|-----|
| OPNsense firewall/router at `10.0.0.1` | mgmt zone | `https://10.0.0.1` (GUI), root password set at bootstrap |
| Zones/VLANs from `zones.json` | whole platform | `zone-manager` (driven by tappaas-cicd) |
| Internal DNS `<vmname>.<zone>.internal` | all zones | Unbound + Dnsmasq on the firewall |
| Reverse proxy (`network:proxy`) | consumer modules | `dependsOn: ["network:proxy"]` → Caddy entry `<service>.<domain>` |
| Per-module firewall rules (`network:rules`) | consumer modules | `dependsOn: ["network:rules"]` → `rules-manager` compiles `ports`/`ingress`/`egress` |
| Public HTTPS entry (Caddy :80/:443) | internet | for services with `proxyAllowedZones: ["internet"]` |
| Switch / WiFi-AP / Proxmox VLAN reconciliation (ADR-008) | TAPPaaS admin | `zone-reconcile`, `switch-controller`, `ap-manager` — see [scripts/README.md](scripts/README.md) |
| Isolated test network on a spare NIC (#225) | TAPPaaS admin | `test-network.sh` — see [docs/test-network-setup.md](docs/test-network-setup.md) |

## What is not included

- TLS certificate issuance — run `acme-setup.sh` on the mothership after bootstrap
  (repo-root [INSTALL.md](../../../INSTALL.md) §2.3).
- Managing a non-OPNsense firewall: with `firewallType: "NONE"` the tooling only prints
  the rules for manual entry into your own firewall.
- Vendor automation for switches/APs beyond the shipped plugins (UniFi; `manual.sh` is
  the by-hand fallback for everything else).
- The admin VPN / satellite ingress — see the `satellite` module and
  [../tappaas-cicd/ADMIN-VPN.md](../tappaas-cicd/ADMIN-VPN.md).

## Requirements

- A cluster node with the `lan`/`wan` bridges built (`cluster` module, `config-network.sh`).
- Internet on the WAN side to download the prebuilt firewall image at bootstrap.
- Defaults (from `network.json`): VM 110, 4 cores, 8 GB RAM, 32 GB disk on `tanka1`,
  `net0→lan` (trunk ALL), `net1→wan`.

## Dependencies

| Depends on | Purpose |
|------------|---------|
| `cluster:vm` | Creates the OPNsense VM from the prebuilt image |
| `cluster:ha` | High-availability placement of the firewall VM |
| `network:proxy` | Registers the firewall's own GUI (`:8443`) behind Caddy |

For installation steps see [INSTALL.md](./INSTALL.md).

Design and implementation detail: [DESIGN.md](./DESIGN.md). Test coverage:
[TEST.md](./TEST.md). Troubleshooting: the
[Unbound / DNSBL section of DESIGN.md](./DESIGN.md#troubleshooting-unbound--dnsbl).
