# logging

Primary audience: TAPPaaS admin.

Centralized log aggregation for the whole TAPPaaS system — a Loki + Grafana + Alloy
VM that collects logs from every TAPPaaS VM, the Proxmox nodes and the OPNsense firewall.

## What you get

| Capability | Access from | How |
|------------|-------------|-----|
| Grafana UI (dashboards, LogQL Explore) | mgmt zone (via Caddy) | `https://logging.<tappaas.domain>` |
| Loki log store (30-day retention) | mgmt zone | `logging.mgmt.internal:3100`, admin credential (`~tappaas/.loki-admin-password`, user `tappaas`) |
| Journal shipping from TAPPaaS VMs | any zone, per VM | `logging:logs` — the baseline's Alloy client pushing to the push-only receiver `:3101` |
| OPNsense firewall logs | firewall | syslog RFC 5424 → `tcp/1514` (`source=opnsense`) |
| Proxmox node logs | nodes | rsyslog forwarder → `tcp/1515` (`source=proxmox`) |
| CLI queries on the VM | mgmt admins (SSH) | `logcli` installed on the VM |
| Alert mails from the logs | site owner (`site.json` `email`) | Grafana rules over every host's logs — quorum lost, fencing, a silent host, a stuck HA service, a lost network leg, failed replication or backup, an out-of-memory kill, disk errors, a changed root key or firewall certificate — mailed by the mothership's `tappaas-alert-receiver` as `ALERT: …`. One that clears is mailed again as `RESOLVED: …`, a reply to the alert. The ones about the cluster, backups and memory carry a support bundle (the cluster's state and the anonymized configuration) to forward to `site.json` `supportEmail`. A watchdog on the mothership mails when the alerting itself stops |

## What is not included

- Metrics, Prometheus or Alertmanager — logs only (metrics-side alerting is v2 backlog).
- TLS on Loki's ports — credentials are basic auth over HTTP inside the site network.
- Syslog over TLS — plain TCP inside mgmt today (v2 backlog).
- Journal shipping from Debian, HAOS, LXC and Windows guests — `logging:logs` covers
  NixOS guests (see [services/logs](services/logs/README.md)).

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

## Availability

Logging is not an HA module by default. When its node is down, the senders
keep what they can and deliver it when it is back: NixOS guests from their
journal, the firewall and the Proxmox nodes from their syslog buffers (in
memory, so a long outage loses the oldest lines). Alert rules evaluated by Loki
do not fire while it is down.

On a site with two or more nodes an operator may make it HA, like any module:
add `cluster:ha` to its `dependsOn` with an `HANode` (see
[cluster:ha](../cluster/services/ha/README.md)); its disk then replicates to
that node.

For installation steps see [INSTALL.md](./INSTALL.md).

Design and implementation detail: [DESIGN.md](./DESIGN.md). Test coverage:
[TEST.md](./TEST.md).
