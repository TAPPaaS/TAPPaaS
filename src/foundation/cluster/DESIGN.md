# cluster — Design notes

Implementation and reference detail for the cluster module. For the catalog entry see
[README.md](./README.md); for installation see [INSTALL.md](./INSTALL.md); for test
coverage see [TEST.md](./TEST.md).

Canonical online instructions: <https://tappaas.org/installation/foundation/cluster/>

## Capabilities

| Capability | Entry point | Purpose |
|------------|-------------|---------|
| `cluster:vm`  | `services/vm/*.sh` → `Create-TAPPaaS-VM.sh`   | Create/manage a VM guest for a consumer module |
| `cluster:lxc` | `services/lxc/*.sh` → `Create-TAPPaaS-LXC.sh` | Create/manage an LXC container guest |
| `cluster:ha`  | `services/ha/*.sh`                            | High-availability placement for a guest |

A consumer module opts in via `dependsOn`, e.g. `["cluster:vm", "cluster:ha"]`.
A guest is **either** a VM **or** a container, never both.

## Files

| File | Role |
|------|------|
| `install.sh` | Node bootstrap — run once per node from the Proxmox shell. Orchestrates the post-install + the three config phases below. Step [1/5] of `foundation/install.sh`. |
| `config-network.sh` | Phase 2 — build the `lan`/`wan` bridges from the physical ports (issue #141); also `--swap-gateway` / `--drop-upstream`. |
| `config-storage.sh` | Phase 3 — build the `tankXY` ZFS pools from the disks. |
| `sanity-check.sh` | Post-firewall health checks (gateway, DNS, internet) once the node is on the management network. |
| `install-platform.sh` | Run once on the first node after all nodes + firewall are up — imports the prebuilt NixOS template (vmid 8080) and builds the `tappaas-cicd` mothership (vmid 130). |
| `make-install-media.sh` | Build a preconfigured Proxmox install USB stick on your laptop (answers baked in; only the boot disk is asked on the target). |
| `Create-TAPPaaS-VM.sh` / `Create-TAPPaaS-LXC.sh` | Guest provisioners, distributed to every node and invoked by the `cluster:vm` / `cluster:lxc` services. |
| `reconcile-storage-nodes.sh` | Reconcile PVE storage node lists with reality. |
| `setup-ssd-lifecycle.sh` | Autotrim + TRIM/SMART cron jobs (#152). |
| `setup-realtek-nic.sh` | Realtek RTL8127 10GbE driver fix for MS-S1 MAX nodes (#308) — hardware-gated, idempotent. See [Node hardware quirks](#node-hardware-quirks). |
| `reboot-node.sh` / `reboot-cluster.sh` | Controlled HA node reboot (single node / orchestrated kernel-reboot pass) (#275). |
| `capture.sh` | Capture helper. |
| `update.sh` | Cluster module update — apt upgrade on all nodes and re-distribute the provisioners + `zones.json`; re-asserts the Realtek fix. |
| `test.sh` | Cluster regression tests (see [TEST.md](./TEST.md)). |
| `assets/` | Vendored binaries used at provision time (e.g. the pinned `r8127-dkms` `.deb`). |
| `lib/` | Shared helpers (`vm-net.sh` and its unit tests). |
| `snippets/` | Cloud-init snippets used by the provisioners. |

## install.sh — phases and flags

`install.sh` runs, in order:

1. **Base post-install** (first run only): disable enterprise repos, enable
   `pve-no-subscription`, remove the subscription nag, enable HA services, install helper
   scripts + `powertop`/`smartmontools` + SSD lifecycle, and `apt dist-upgrade`. Recorded
   by `/var/log/tappaas.step1`.
2. **Network phase** → `config-network.sh`
3. **Cluster phase** (create or join)
4. **Storage phase** → `config-storage.sh`
5. A **summary** of bridges, pools (with redundancy warnings) and cluster state. It also
   writes `~/tappaas/.cluster-role` (`created`/`joined`/`member`/`standalone`) for the
   `foundation/install.sh` orchestrator, which only chains the firewall + platform steps
   on the node that *created* the cluster.

The base step is skipped on re-runs (delete `/var/log/tappaas.step1` to force it); the
three config phases run every time and are individually idempotent.

```
install.sh [REPO] [BRANCH] --name <orgname>
           [--cluster|--join|--no-cluster] [--skip-network] [--skip-storage]
           [--lan-port <if>] [--wan-port <if>] [--pool <name=topo:disks>]...
           [--non-interactive]
```

| Flag | Effect |
|------|--------|
| `REPO` `BRANCH` | Positional; default `https://codeberg.org/TAPPaaS/TAPPaaS/raw/branch/` + `stable`. |
| `--name` | Org/system name → the Proxmox **cluster name** (falls back to `TAPPaaS` when run standalone without `--name`). |
| `--cluster` | Force-create the cluster on this node. |
| `--join` | Force this node to join an existing cluster (interactive). |
| `--no-cluster` | Leave the node standalone (no create, no join). |
| `--skip-network` / `--skip-storage` | Skip that phase. |
| `--lan-port` / `--wan-port` | NIC roles, forwarded to `config-network.sh` (needed for unattended runs). |
| `--pool name=topology:disks` | Pool specs, forwarded to `config-storage.sh` (repeatable). |
| `--non-interactive` | Never prompt. Phases that need choices do nothing unless given via flags; a cluster join prints the manual `pvecm add` command instead of prompting. |

`--skip-firewall`, `--skip-platform` and `--domain` are accepted for back-compat but
ignored here — those phases belong to `foundation/install.sh`.

Default cluster behaviour (no flag) is **auto**: `tappaas1` creates the cluster, every
other node joins it.

## Network (phase 2)

`config-network.sh` (issue #141) establishes the TAPPaaS bridge model:

- **`lan`** — VLAN-aware bridge (`bridge-vids 2-4094`) carrying the management network
  (untagged) plus every TAPPaaS VLAN as a trunk to the switch. Holds this node's
  management IP. The OPNsense firewall VM and all guest VLAN interfaces attach here.
- **`wan`** — plain bridge for the upstream/ISP uplink (the firewall VM's WAN).

It lists the physical ports with MAC / link state / speed so you can tell them apart,
you pick which port is LAN and which is WAN, and it rewrites `/etc/network/interfaces`
accordingly. The management IP/gateway default to the values already on the node (set
during the Proxmox install).

**Lockout protection:** applying the change arms a **90-second auto-rollback**. After it
applies you must type `keep` to make it permanent; if you get disconnected or do nothing,
the node reverts to the previous working config.

It is also the script behind the bootstrap's **gateway cutover** (`--swap-gateway`,
additive: keeps the upstream IP, points default route + DNS at the firewall) and the
later hardening step (`--drop-upstream`). It can be re-run any time to reassign ports.

```
config-network.sh [--lan-port <if>] [--wan-port <if>] [--mgmt-ip <CIDR>]
                  [--gateway <ip>] [--no-rollback] [--dry-run|--apply]
                  [--non-interactive]
```

| Flag | Effect |
|------|--------|
| `--lan-port` / `--wan-port` | Assign ports non-interactively. |
| `--mgmt-ip` / `--gateway` | Override the management IP / gateway (default: current). |
| `--dry-run` | Print the rendered config and exit without writing. |
| `--no-rollback` | Apply without the auto-rollback safety (not recommended). |
| `--non-interactive` | Fail rather than prompt (requires `--lan-port`). |

## Cluster (phase 3, runs before storage)

Runs **before** storage — a ZFS pool created on a standalone node (before it is a
cluster member) is not usable as HA-failover storage in Proxmox, so pools must be
created while the node already belongs to the cluster.

| Situation | Behaviour |
|-----------|-----------|
| Already a member | Detected via `pvecm status` and skipped. |
| `tappaas1` (or `--cluster`) | `pvecm create <orgname>` (fallback name `TAPPaaS`). |
| Any other node (or `--join`) | **Interactive join**: prompts for an existing node's address (default `tappaas1.mgmt.internal`) and runs `pvecm add`, which prompts for that node's root password. |
| `--no-cluster` | Skipped; node stays standalone. |

Node management IPs follow `tappaasN` → `10.0.0.<9+N>` (max 9 nodes — the firewall
reserves DNS + static IPs for `tappaas1`–`tappaas9` only; higher numbers abort).

In `--non-interactive` mode a join cannot supply the password, so the script prints the
`pvecm add tappaas1.mgmt.internal` command for you to run.

## Storage (phase 4)

`config-storage.sh` builds the TAPPaaS ZFS data pools and registers them with PVE
storage. Naming convention: `tankXY` where `X` is the tier/type (`a` = primary/fast,
`b`, `c`, …) and `Y` a sequence number.

Disk selection rules:

- The **boot disk** (the disk backing `/` and `/boot/efi`) is never offered and never
  touched. ZFS zvols and device-mapper/loop devices are excluded.
- **Every other disk is offered, including disks already in an existing
  `tanka1/b1/c1`** — tagged `[in zpool …]` — so a machine that used to belong to another
  TAPPaaS cluster can be wiped and re-provisioned.
- Any disk that **already contains data** requires an explicit confirmation before it is
  wiped. Pools are created with `ashift=12`, `autotrim=on`, `compression=lz4`,
  `atime=off`.

```
config-storage.sh [--pool <name>=<topology>:<disk>[,<disk>...]] [--list]
                  [--yes] [--non-interactive] [--no-pve-register]
```

| Flag | Effect |
|------|--------|
| `--list` | Print the selectable disks (with pool tags) and exit. |
| `--pool name=topology:disks` | Define a pool non-interactively (repeatable). `topology` ∈ `single` (1 disk), `stripe` (2+ disks, no redundancy), `mirror`, `raidz`, `raidz2`. E.g. `--pool tanka1=mirror:nvme0n1,nvme1n1` or `--pool tankc2=stripe:sdc,sdd`. |
| `--yes` | Assume "yes" to wipe confirmations — **destructive**; unattended use only. |
| `--non-interactive` | Fail rather than prompt (requires `--pool`). |
| `--no-pve-register` | Create the pools but do not add them to PVE storage. |

Interactively, it offers to build `tanka1`, `tankb1`, `tankc1` in turn; for each you pick
disks and a topology (existing pools are skipped).

## Storage design decisions

Migrated from the documentation site's solution-design "Storage" page; conceptual
background in [StorageDesign.md](../../../docs/Architecture/StorageDesign.md).

**ZFS as the storage manager.** ZFS meets the criteria for an efficient, scalable,
redundant, flexible and trustworthy storage solution, combined here with a standard
setup of snapshots and replication across cluster nodes. It gives TAPPaaS
enterprise-grade storage on commodity disks without dedicated (costly) SAN/NAS
hardware — in small to medium deployments this can cut storage hardware cost by up to
50%. The design stays hardware-agnostic on SSD vs HDD and caching layout. Growth paths:
add disks to a pool, add pools to a node, add nodes to the cluster. Redundancy is
layered: ZFS RAID within a node, snapshot + replication across nodes (`cluster:ha`),
and backup between local and remote installations (the `backup` module).

**Known limitation — no synchronous cross-node replication.** The `cluster:ha` service
uses asynchronous ZFS replication (default schedule `*/15`, i.e. up to 15 minutes of
data loss on failover; a module can tighten this via its `replicationSchedule`).
Providing a synchronous option (Ceph, Garage S3) is a roadmap item, recommended only
for large installations.

### Pool tiers

`tankXY`: `X` is the tier, `Y` a sequence number. Pools mount at `/<poolname>`
(e.g. `/tanka1`). The tier meanings (also printed by `config-storage.sh`):

| Tier | Purpose | Typical build |
|------|---------|---------------|
| `tanka` | Primary VM storage — VM virtual disks and HA replication live here | fast + redundant (mirrored SSDs) |
| `tankb` | Second-tier data: less-important services, S3 buckets, logging | no RAID redundancy, cheaper disks, no HA replication |
| `tankc` | Backup — the PBS datastore | cost-optimized, mostly single-stream write; typically on one node only (`tappaas3` in a 3-node cluster) |

Letters `d`, `e`, … remain free for specialized storage characteristics.

## Adding more nodes

The supported flow is `site-manager node add tappaasN --pxe` from the mothership (see
[INSTALL.md](./INSTALL.md) and the repo-root [INSTALL.md](../../../INSTALL.md) §2.2):
a TTL-limited PXE trap installs Proxmox unattended, then the node step runs served from
the mothership, joins the cluster and creates the declared pools. A manual install with
the stock ISO followed by `site-manager node add tappaasN` (no `--pxe`) is equivalent.

`update.sh` (run from the mothership) keeps the provisioners and `zones.json` in sync
across all nodes.

## Node hardware quirks

### Minisforum MS-S1 MAX — Realtek RTL8127 10GbE (issue #308)

The MS-S1 MAX's two 10GbE ports are Realtek **RTL8127** `[10ec:8127]`. The in-tree
**`r8169`** driver fails to re-initialise them across a **warm/soft reboot** — the NIC
drops off the PCIe bus and only a **full power cycle** brings it back. (Same chipset bug
seen on the NVIDIA DGX Spark.) Intel-`igc` nodes are unaffected.

The fix is codified in **`setup-realtek-nic.sh`** (run by `install.sh` at bootstrap and
re-asserted by `update.sh` every cycle; hardware-gated, idempotent): install Realtek's
**`r8127`** DKMS driver (vendored, SHA256-pinned, in `assets/`) and blacklist `r8169` —
but **only after** the `r8127` module is confirmed to build and load, so a future kernel
that can't build it never leaves the node driverless.

Two steps the OS cannot do for you (the script detects and instructs):

1. **Disable Secure Boot** in the BIOS — the unsigned DKMS module will not load
   otherwise (or MOK-sign it). The MS-S1 MAX ships with Secure Boot **enabled**.
2. **One power cycle** the first time — the node boots on `r8169`; only a full power
   cycle (drain), not a warm reboot, switches cleanly to `r8127`. After that, warm
   reboots (incl. the `#275` automated kernel-reboot pass) are safe.

Because `update.sh` re-runs the enforcer every cycle and DKMS rebuilds `r8127` for each
new kernel, ordinary updates **maintain** the fix rather than overwrite it; a
from-scratch reinstall re-applies it automatically via `install.sh`.

## Related issues

- #140 — automate cluster create/join in `install.sh`
- #141 — `config-network.sh` (lan/wan bridge setup, gateway cutover)
- #175 — robust downloads (`fetch()`): a failed download is now fatal, never a silent
  0-byte file reported as success
- #275 — controlled HA node reboots (`reboot-node.sh` / `reboot-cluster.sh`)
- #308 — Realtek RTL8127 NIC driver fix for MS-S1 MAX (`setup-realtek-nic.sh`)
