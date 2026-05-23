# Cluster Foundation Module

The Proxmox VE layer of TAPPaaS. It turns a freshly-installed Proxmox node into
a TAPPaaS cluster member: it configures the post-install environment, the
network bridges, the cluster membership, and the ZFS storage pools, and
provides the VM/LXC/HA capabilities the rest of the platform builds on.

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
| `install.sh` | Node bootstrap — run once per node from the Proxmox shell. Orchestrates the post-install + the three config phases below. |
| `config-network.sh` | Phase 2 — build the `lan`/`wan` bridges from the physical ports (issue #141). |
| `config-storage.sh` | Phase 3 — build the `tankXY` ZFS pools from the disks. |
| `Create-TAPPaaS-VM.sh` / `Create-TAPPaaS-LXC.sh` | Guest provisioners, distributed to every node and invoked by the `cluster:vm` / `cluster:lxc` services. |
| `setup-ssd-lifecycle.sh` | Autotrim + TRIM/SMART cron jobs (#152). |
| `update.sh` | Cluster module update — apt upgrade on all nodes and re-distribute the provisioners + `zones.json`. |
| `test.sh` | Cluster regression tests. |

---

## Installing a node

### 1. Install Proxmox VE

Boot the Proxmox VE 9 installer and install to the boot disk. During install set:

| Setting | Value |
|---------|-------|
| Hostname | `tappaas1.mgmt.internal` (subsequent nodes: `tappaas2`, `tappaas3`, …) |
| IP / Netmask / Gateway / DNS | From your planned management subnet (e.g. `10.0.0.10/24`, gw `10.0.0.1`) |

The hostname matters: the first node **must** be `tappaas1` for the cluster to
be created automatically (see [Cluster](#cluster-phase-1)).

### 2. Run the bootstrap

From the Proxmox shell (web console or physical console — **not** SSH, because
the network phase may reconfigure the interface your SSH session uses):

```bash
REPO="https://raw.githubusercontent.com/TAPPaaS/TAPPaaS/"
BRANCH="stable"
curl -fsSL ${REPO}${BRANCH}/src/foundation/cluster/install.sh >install.sh
chmod +x install.sh
./install.sh $REPO $BRANCH
```

> Download-then-run (not `curl | bash`): the script is interactive, so it needs
> a real terminal on stdin.

`install.sh` then runs, in order:

1. **Base post-install** (first run only): disable enterprise repos, enable
   `pve-no-subscription`, remove the subscription nag, enable HA services,
   install helper scripts + `powertop`/`smartmontools` + SSD lifecycle, and
   `apt dist-upgrade`. Recorded by `/var/log/tappaas.step1`.
2. **Network phase** → `config-network.sh`
3. **Cluster phase** (create or join)
4. **Storage phase** → `config-storage.sh`
5. A **summary** of bridges, pools (with redundancy warnings) and cluster state.

The base step is skipped on re-runs (delete `/var/log/tappaas.step1` to force
it); the three config phases run every time and are individually idempotent, so
you can safely re-run `install.sh` to finish or change configuration.

### `install.sh` flags

```
install.sh [REPO] [BRANCH] [--cluster|--join|--no-cluster]
                           [--skip-network] [--skip-storage] [--non-interactive]
```

| Flag | Effect |
|------|--------|
| `REPO` `BRANCH` | Positional; default `https://raw.githubusercontent.com/TAPPaaS/` + `stable`. |
| `--cluster` | Force-create the `TAPPaaS` cluster on this node. |
| `--join` | Force this node to join an existing cluster (interactive). |
| `--no-cluster` | Leave the node standalone (no create, no join). |
| `--skip-network` | Skip the network phase. |
| `--skip-storage` | Skip the storage phase. |
| `--non-interactive` | Never prompt. Phases that need choices do nothing unless given via the helper-script flags; cluster join prints the manual command instead of prompting. |

Default cluster behaviour (no flag) is **auto**: `tappaas1` creates the cluster,
every other node joins it.

---

## Network (phase 2)

`config-network.sh` (issue #141) establishes the TAPPaaS bridge model:

- **`lan`** — VLAN-aware bridge (`bridge-vids 2-4094`) carrying the management
  network (untagged) plus every TAPPaaS VLAN as a trunk to the managed switch.
  Holds this node's management IP. The OPNsense firewall VM and all guest VLAN
  interfaces attach here.
- **`wan`** — plain bridge for the upstream/ISP uplink (the firewall VM's WAN).

It lists the physical ports with MAC / link state / speed so you can tell them
apart, you pick which port is LAN and which is WAN, and it rewrites
`/etc/network/interfaces` accordingly. The management IP/gateway default to the
values already on the node (set during the Proxmox install).

**Lockout protection:** applying the change arms a **90-second auto-rollback**.
After it applies you must type `keep` to make it permanent; if you get
disconnected or do nothing, the node reverts to the previous working config.

It is also the script behind the firewall **"Swap cables"** step and can be
re-run any time to reassign ports.

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

---

## Cluster (phase 1)

Runs **before** storage — a ZFS pool created on a standalone node (before it is
a cluster member) is not usable as HA-failover storage in Proxmox, so pools must
be created while the node already belongs to the cluster.

| Situation | Behaviour |
|-----------|-----------|
| Already a member | Detected via `pvecm status` and skipped. |
| `tappaas1` (or `--cluster`) | `pvecm create TAPPaaS`. |
| Any other node (or `--join`) | **Interactive join**: prompts for an existing node's address (default `tappaas1.mgmt.internal`) and runs `pvecm add`, which prompts for that node's root password. |
| `--no-cluster` | Skipped; node stays standalone. |

In `--non-interactive` mode a join cannot supply the password, so the script
prints the `pvecm add tappaas1.mgmt.internal` command for you to run.

---

## Storage (phase 3)

`config-storage.sh` builds the TAPPaaS ZFS data pools and registers them with
PVE storage. Naming convention (`CLAUDE.md`): `tankXY` where `X` is the
tier/type (`a` = primary/fast, `b`, `c`, …) and `Y` a sequence number.

Disk selection rules:

- The **boot disk** (the disk backing `/` and `/boot/efi`) is never offered and
  never touched. ZFS zvols and device-mapper/loop devices are excluded.
- **Every other disk is offered, including disks already in an existing
  `tanka1/b1/c1`** — tagged `[in zpool …]` — so a machine that used to belong to
  another TAPPaaS cluster can be wiped and re-provisioned.
- Any disk that **already contains data** requires an explicit confirmation
  before it is wiped. Pools are created with `ashift=12`, `autotrim=on`,
  `compression=lz4`, `atime=off`.

```
config-storage.sh [--pool <name>=<topology>:<disk>[,<disk>...]] [--list]
                  [--yes] [--non-interactive] [--no-pve-register]
```

| Flag | Effect |
|------|--------|
| `--list` | Print the selectable disks (with pool tags) and exit. |
| `--pool name=topology:disks` | Define a pool non-interactively (repeatable). `topology` ∈ `single`, `mirror`, `raidz`, `raidz2`. e.g. `--pool tanka1=mirror:nvme0n1,nvme1n1`. |
| `--yes` | Assume "yes" to wipe confirmations — **destructive**; unattended use only. |
| `--non-interactive` | Fail rather than prompt (requires `--pool`). |
| `--no-pve-register` | Create the pools but do not add them to PVE storage. |

Interactively, it offers to build `tanka1`, `tankb1`, `tankc1` in turn; for each
you pick disks and a topology (existing pools are skipped).

---

## Adding more nodes

1. Install Proxmox VE with hostname `tappaasN` and a management IP.
2. Run the bootstrap (section 2). The network phase builds `lan`/`wan`; the
   cluster phase prompts to join `tappaas1.mgmt.internal`; the storage phase
   builds that node's pools as a member.

`update.sh` (run from the mothership) keeps the provisioners and `zones.json` in
sync across all nodes.

## Related issues

- #140 — automate cluster create/join in `install.sh`
- #141 — `config-network.sh` (lan/wan bridge setup, swap-cables step)
- #175 — robust downloads (`fetch()`): a failed download is now fatal, never a
  silent 0-byte file reported as success
