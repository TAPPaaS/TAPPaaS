# cluster — Installation

Primary audience: TAPPaaS admin.

The cluster module is **not** installed with `install-module.sh` — it is the node step of
the foundation bootstrap. The full first-node story is in the repo-root
[INSTALL.md](../INSTALL.md); this page covers the cluster part.

## Prerequisites

1. **Proxmox VE 9.1** installed on the node (9.2 is not yet supported). Either build a
   preconfigured USB stick with `make-install-media.sh` (asks only for the boot disk on
   the target), or use the stock ISO. During install set:
   - Hostname (FQDN): `tappaas1.mgmt.internal` — subsequent nodes `tappaas2`, `tappaas3`, …
     The first node **must** be `tappaas1` (it creates the cluster).
   - A working email address (Proxmox health notifications; reused as the admin email).
   - IP/netmask/gateway/DNS valid for your **existing** network, so the node has internet.
2. Both NICs wired: one to the upstream router (becomes WAN), one to the downstream
   switch (becomes LAN).
3. Drive the install from the node **console** (xterm.js) or from an SSH client that is
   **not** on `10.0.0.0/24` — the network phase moves the management net onto the node.
4. A strong root password for Proxmox (asked several times).

> There is no `cluster.json` sizing to copy/edit — deviations from the defaults
> (management subnet, NIC roles, pool layout) are passed as flags to
> `install.sh` / `config-network.sh` / `config-storage.sh`. See
> [DESIGN.md](./DESIGN.md) for the full flag reference.

## Install

**First node** — run the one-shot foundation bootstrap from the Proxmox shell. It runs
this module's `install.sh` as step [1/5], then chains firewall, gateway cutover, sanity
check and platform:

    REPO="https://codeberg.org/TAPPaaS/TAPPaaS/raw/branch/"; BRANCH="main"
    curl -fsSL ${REPO}${BRANCH}/src/foundation/install.sh >install.sh
    chmod +x install.sh
    ./install.sh "$REPO" "$BRANCH" --name <orgname> --domain "yourdomain.com"

The node step alone (no firewall/platform chain) is `src/foundation/cluster/install.sh`
with the same positional `REPO BRANCH` arguments.

**Additional nodes** — after the first node's bootstrap has finished, add each node from
the mothership with one command (network-boot, fully unattended):

    site-manager node add tappaas2 --pxe

then fold the new topology into HA + replication with `update-tappaas --force`.

Download-then-run (not `curl | bash`): the script is interactive and needs a real
terminal on stdin. `install.sh` is safe to re-run — the base post-install step is skipped
on re-runs (delete `/var/log/tappaas.step1` to force it) and the network / cluster /
storage phases are individually idempotent.

## Post-install

- **Network phase confirmation** — applying the bridge change arms a 90-second
  auto-rollback; you must type `keep` at the prompt to make it permanent.
- **Storage wipe confirmations** — any disk that already contains data must be explicitly
  confirmed before it is wiped.
- **Cluster join password** — a joining node's `pvecm add` prompts for the existing
  node's root password (in `--non-interactive` mode the command is printed for you
  to run manually).
- **Minisforum MS-S1 MAX (Realtek RTL8127 10GbE) only** — two steps the OS cannot do
  (issue #308, detected and instructed by `setup-realtek-nic.sh`):
  1. Disable Secure Boot in the BIOS (the unsigned DKMS module will not load otherwise).
  2. One full **power cycle** (not a warm reboot) the first time, to switch from `r8169`
     to the `r8127` driver.
- Optional hardening, once you manage via the mgmt net: `config-network.sh
  --drop-upstream` removes the node's upstream IP so Proxmox is reachable only behind
  the firewall.

## Verification

From the mothership:

    test-module.sh cluster                      # fast (~seconds)
    TAPPAAS_TEST_DEEP=1 test-module.sh cluster  # deep: creates/deletes real guests

On a freshly bootstrapped node, `sanity-check.sh` verifies gateway, DNS and internet.

| Check | Expected |
|-------|----------|
| `pvecm status` on a node | Cluster named `<orgname>`; all nodes listed with quorum |
| `zpool list` on a node | The `tankXY` pools you defined, ONLINE |
| `ip link show lan` / `ip link show wan` | Both bridges up; `lan` is VLAN-aware |
| Proxmox UI `https://10.0.0.10:8006` | Reachable; node visible in the datacenter tree |
| `test-module.sh cluster` | All fast tests pass (see [TEST.md](./TEST.md)) |

## Troubleshooting

**Locked out during the network phase**
The 90-second auto-rollback reverts to the previous working config if you do not type
`keep` — reconnect and re-run. Only use `--no-rollback` when you have console access.

**Cluster join fails / was skipped**
Re-run `install.sh` (idempotent) or run the printed `pvecm add tappaas1.mgmt.internal`
manually. Pools must be created **after** joining — a pool made on a standalone node is
not usable as HA-failover storage.

**10GbE NIC missing after a warm reboot (MS-S1 MAX)**
The Realtek RTL8127 drops off the PCIe bus under the in-tree `r8169` driver. Do a full
power cycle, ensure Secure Boot is disabled, and let `setup-realtek-nic.sh` (run by
`install.sh` and re-asserted by `update.sh`) install the vendored `r8127` DKMS driver.
See [DESIGN.md](./DESIGN.md#node-hardware-quirks).

**A download failed during bootstrap**
Downloads are fatal by design (issue #175) — a failed fetch never leaves a silent 0-byte
file. Fix connectivity and re-run `install.sh`.
