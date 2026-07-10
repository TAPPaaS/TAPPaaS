# logging

Primary audience: TAPPaaS admin.

Centralized log aggregation for the whole TAPPaaS system — a Loki + Grafana + Promtail
VM that collects logs from every TAPPaaS VM, the Proxmox nodes and the OPNsense firewall.

## What you get

| Capability | Access from | How |
|------------|-------------|-----|
| Grafana UI (dashboards, LogQL Explore) | mgmt zone (via Caddy) | `https://logging.<tappaas.domain>` |
| Loki log store (30-day retention) | mgmt zone | HTTP push/query on `logging.mgmt.internal:3100` |
| Journal shipping from TAPPaaS VMs | each VM | Promtail client pushing to `:3100` |
| OPNsense firewall logs | firewall | syslog RFC 5424 → `tcp/1514` (`source=opnsense`) |
| Proxmox node logs | nodes | rsyslog forwarder → `tcp/1515` (`source=proxmox`) |
| CLI queries on the VM | mgmt admins (SSH) | `logcli` installed on the VM |

## What is not included

- Metrics, Prometheus or Alertmanager — logs only (metrics-side alerting is v2 backlog).
- Loki authentication — the mgmt zone is the trust boundary (v2 backlog).
- Syslog over TLS — plain TCP inside mgmt today (v2 backlog).
- A consumable `logging:*` service for other modules — `provides` is empty in v1;
  consumer VMs add their own Promtail block (see [DESIGN.md](./DESIGN.md)). Firewall
  pinholes for non-mgmt-zone senders are also not yet automated.

## Requirements

- Foundation bootstrap complete: cluster, templates, network and backup modules
  installed (this module is part of the `rest-of-foundation.sh` sequence).
- Defaults (from `logging.json`): VM 150 in zone `mgmt`, 2 cores, 2 GB RAM, 32 GB disk
  on `tanka1`. Grow the disk or shorten retention as clients are added.

## Dependencies

| Depends on | Purpose |
|------------|---------|
| `cluster:vm` | Creates the VM (clone of the NixOS template) |
| `templates:nixos` | NixOS base image + OS configuration hooks |
| `backup:vm` | PBS snapshot backup of the VM (Loki state included) |
| `network:proxy` | Caddy entry `logging.<domain>` → Grafana `:3000`, mgmt-only |

For installation steps see [INSTALL.md](./INSTALL.md).

Design and implementation detail: [DESIGN.md](./DESIGN.md). Test coverage:
[TEST.md](./TEST.md).
