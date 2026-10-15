# cluster

Primary audience: TAPPaaS admin.

The Proxmox VE layer of TAPPaaS — turns commodity nodes into a cluster that provides the
VM, LXC and HA services every other TAPPaaS module builds on.

## What you get

| Capability | Access from | How |
|------------|-------------|-----|
| Proxmox VE cluster (`tappaas1`, `tappaas2`, … — `.10`+, up to the mgmt DHCP pool) | mgmt zone | `https://tappaas1.mgmt.internal:8006` (`10.0.0.10`) |
| VM provisioning (`cluster:vm`) | consumer modules | `dependsOn: ["cluster:vm"]` → `services/vm/` hooks |
| LXC provisioning (`cluster:lxc`) | consumer modules | `dependsOn: ["cluster:lxc"]` → `services/lxc/` hooks |
| HA placement + replication (`cluster:ha`) | consumer modules | `dependsOn: ["cluster:ha"]` → `services/ha/` hooks. `haCpu` picks the CPU model the guest runs: `common` (default) — the richest x86-64 level its node and HANode share, so every move between them is live; `host` — the node's full CPU, moved by stop and start. See [services/ha/README.md](services/ha/README.md) |
| CPU inventory of the nodes | TAPPaaS admin | `update.sh` Step 9 runs `proxmox-controller cpu-inventory --apply`: each node's x86-64 level as KVM reports it, the level all nodes share, and which live moves of a `cpu: host` guest are safe — `config/cluster-cpu.md` (and `.json`, which `haCpu` reads) |
| Automatic disk growth (VMs) | consumer modules | every module update grows a VM disk whose `/` is 80% full by 50% when its pool has room — `services/vm/auto-grow.sh`, settings in `site.json` `diskAutoGrow`; see [services/vm/README.md](services/vm/README.md) |
| `lan`/`wan` bridge model (VLAN-aware trunk) | nodes | built by `config-network.sh` at install |
| ZFS data pools (`tankXY`) | nodes | built by `config-storage.sh` at install |
| Controlled node/cluster reboots | TAPPaaS admin | `reboot-node.sh` / `reboot-cluster.sh`. A node is drained only when every running HA guest on it can move live to the node HA would choose; otherwise it is left for a window (`DEFERRED:`) and nothing moves. `haCpu: host` guests are moved off by stop and start first, and back afterwards |
| Key-only SSH on every node (#19) | TAPPaaS admin | enforced by `update.sh` Step 5 (`tappaas-cicd/scripts/ssh-key-only.sh`, shared with the machine modules' `sshKeyOnly`, #756). No password SSH for any user; root by key only. The web GUI, its node Shell and the physical console still take the root password |
| Guests wait for the firewall before they start (#127) | TAPPaaS admin | enforced by `update.sh` Step 5d (`setup-guest-hook.sh`). Guests take their address by DHCP from the firewall VM, and after a cold start of the site (a power cut) each node starts its guests at once while the HA firewall waits for quorum. Every guest but the firewall carries a pre-start hookscript (`local:snippets/tappaas-guest-hook.sh`) that waits until the firewall answers DNS, at most 180 s, then starts the guest anyway; with the firewall up it costs one probe. In Grafana: `{source="proxmox"} \|= "tappaas-guest-hook"`. A guest's own hookscript is kept, and reported |
| Microcode and an audit trail on every node (#128) | TAPPaaS admin | enforced by `update.sh` Step 5b (`setup-host-hardening.sh`). The CPU vendor's microcode package; auditd records changes **made from a login session** (SSH, the sweep, the console, the GUI node Shell) to `/etc/pve`, `/etc/ssh`, `/root/.ssh` and `/etc/network`, and forwards them to the logging module. In Grafana: `{source="proxmox"} \|= "tappaas-pve"` (or `tappaas-ssh`, `tappaas-network`). Changes made through the web GUI or API are PVE's own task log lines, already in Loki. A key added to or removed from root's `authorized_keys` is logged as `tappaas-rootkeys-changed:` (a 5-minute fingerprint check) and alerts as RootKeyChanged; a rewrite with the same keys does not |
| Proxmox's own notification mails off (#126) | TAPPaaS admin | `update.sh` Step 5c disables PVE's built-in `default-matcher` (cluster-wide), so smartd/ZED system mail, backup-job mails, replication, fencing and update notices no longer go to root@pam's address. Alerts come from the logging module instead, through `site-notify.sh` (see `logging/DESIGN.md`, *Alerting from the logs*). Disabled, not deleted: `pvesh set /cluster/notifications/matchers/default-matcher --disable 0` brings PVE's mails back until the next cluster update; a matcher of the site's own is left alone |
| Every node on the site's timezone (#837) | TAPPaaS admin | `update.sh` Step 5e sets each node's timezone to `site.json` `.location.timezone` when it differs, and says so. Only the timezone; keyboard and locale stay as installed. The `site-timezone` health gate reports a node or guest still on another zone |

A guest is **either** a VM **or** an LXC container, never both.

## Architecture

```mermaid
flowchart TB
    subgraph Capabilities
        Compute[Compute Capability]
        HA[High Availability Capability]
    end

    subgraph ClusterModule["cluster module"]
        PVE[Proxmox Virtual Environment]
        VMService([vm service])
        LXCService([lxc service])
        HAService([ha service])
        VMService -.->|provided by| PVE
        LXCService -.->|provided by| PVE
        HAService -.->|provided by| PVE
    end

    Compute -.->|realized by| PVE
    HA -.->|realized by| PVE
```

The Compute and High Availability capabilities are realized by Proxmox VE, which
provides the `vm`, `lxc` and `ha` services (the module's `provides` in
`cluster.json`) that every other TAPPaaS module builds on.

## What is not included

- The firewall/router itself — that is the [`network`](../network/README.md) module
  (its VM runs on this cluster).
- The VM base images — the [`templates`](../templates/README.md) module.
- Backup, identity, logging — separate foundation modules.
- General Proxmox administration guidance beyond the TAPPaaS conventions.

## Requirements

- One node (or three for a cluster) capable of running **Proxmox VE 9.1** (9.2 is not
  yet supported), each with **two NICs** (one WAN, one LAN).
- A dedicated **boot disk** (ext4/LVM) plus separate data disks for the `tankXY` pools.
- An existing network with a free IP, DHCP and internet for the bootstrap.
- Multi-node: a switch between the nodes — unmanaged works out of the box; a managed
  switch needs VLAN trunking configured first (see the repo-root
  [INSTALL.md](../INSTALL.md)).

## Two-node clusters

Two nodes are two votes, and Proxmox needs a majority — two — to stay quorate.
When one node is down the other is not quorate, and HA fences it: the whole site
goes down, the firewall with it. `site-manager node add` warns when a cluster
reaches two nodes, and the health check (`quorum`) keeps saying so.

The fix is a third vote: a **QDevice** — `corosync-qnetd` on a small always-on
Debian machine that is not a node (a `debianhost`, or the satellite). It holds no
guests and needs almost no resources; it must reach the nodes on TCP 5403.

1. On that machine: `apt install corosync-qnetd`
2. On every node: `apt install corosync-qdevice`
3. On one node: `pvecm qdevice setup <machine's address>` — it asks once for the
   machine's root password, to exchange certificates.
4. Check: `pvecm status` lists the Qdevice, and *Expected votes* is 3.

A third node does the same and adds capacity. A QDevice with three nodes is not
needed (and Proxmox advises against it on an odd number of nodes).

## Alternatives considered

- XCP-ng — seems less polished and with fewer features (though it also seems more "free").
- FreeNAS/TrueNAS — good for storage (same ZFS underpinning) but not really a cloud
  platform: no clustering and HA like Proxmox.
- Dedicated SAN/NAS for storage — ZFS on commodity local disks delivers the redundancy
  without extra hardware (up to 50% cheaper in small/medium deployments); Ceph/Garage S3
  remain a roadmap option for synchronous cross-node replication.

Source: the TAPPaaS curation criteria (Design Principles, tappaas.org
What → Principles). Depth: see [DESIGN.md](./DESIGN.md).

## Dependencies

None — `cluster` is the bottom layer of the foundation (`dependsOn: []`). It provides
`vm`, `lxc` and `ha` to everything else.

For installation steps see [INSTALL.md](./INSTALL.md).

Design and implementation detail: [DESIGN.md](./DESIGN.md). Test coverage: [TEST.md](./TEST.md).
