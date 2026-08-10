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
| Switch / WiFi-AP / Proxmox VLAN reconciliation (ADR-008) | TAPPaaS admin | `network-manager reconcile`, `switch-controller`, `ap-controller` — see [scripts/README.md](scripts/README.md) |
| Isolated test network on a spare NIC (#225) | TAPPaaS admin | `test-network.sh` — see [docs/test-network-setup.md](docs/test-network-setup.md) |

## Architecture

```mermaid
flowchart TB
    subgraph Capabilities
        NetSec[Network Security Capability]
        RevProxy[Reverse Proxy Capability]
    end

    subgraph NetworkModule["network module"]
        OPNsense[OPNsense]
        subgraph SubComponents["Sub-Components"]
            Rules[Firewall Rules]
            DNS["DNS: Unbound + Dnsmasq"]
            DHCP[DHCP]
            Zones[Zones / VLANs]
            Caddy[Caddy]
        end
        FirewallService([firewall service])
        NATService([nat service])
        RulesService([rules service])
        DNSService([dns service])
        DiscoveryService([discovery service])
        ProxyService([proxy service])
        OPNsense --> Rules
        OPNsense --> DNS
        OPNsense --> DHCP
        OPNsense --> Zones
        OPNsense --> Caddy
        FirewallService -.->|provided by| OPNsense
        NATService -.->|provided by| OPNsense
        RulesService -.->|provided by| Rules
        DNSService -.->|provided by| DNS
        DiscoveryService -.->|provided by| DNS
        ProxyService -.->|provided by| Caddy
    end

    subgraph ClusterModule["cluster module"]
        VMService([vm service])
        HAService([ha service])
    end

    NetSec -.->|realized by| OPNsense
    RevProxy -.->|realized by| Caddy
    OPNsense -->|depends on| VMService
    OPNsense -->|depends on| HAService
```

The Network Security and Reverse Proxy capabilities are realized by the OPNsense VM
and its Caddy plugin. The module provides the `firewall`, `proxy`, `rules`,
`discovery`, `dns` and `nat` services (the `provides` in `network.json`) that
consumer modules depend on; the VM itself is created and kept highly available by the
`cluster` module.

## What is not included

- TLS certificate issuance — run `acme-setup.sh` on the mothership after bootstrap
  (repo-root [INSTALL.md](../INSTALL.md) §2.3).
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

## Alternatives considered

- pfSense — the original, but going more and more commercial.
- OpenWRT — seems less scalable and less feature-rich.
- Proxmox built-in firewall — would be easier (already built in), but less secure.

Source: the TAPPaaS curation criteria (Design Principles, tappaas.org
What → Principles). Depth: see [DESIGN.md](./DESIGN.md).

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
