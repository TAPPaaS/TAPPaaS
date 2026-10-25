# ADR-037 — Install: one disk, a hosted server, and a bootstrap that hands over to the console

| | |
|---|---|
| **Status** | **Proposed** (draft for the operator) |
| **Version** | 0.3 |
| **Date** | 2026-10-25 |
| **Author** | Lars Rossen |
| **Deciders** | @LarsRossen |
| **Closes / addresses** | #403 (install on the root disk; smarter placement), #377 (the installer cannot restart; the management-network question), the 2.4 install theme. Builds on [ADR-034](<ADR-034 - TAPPaaS User Interface.md>) D10 (the Setup wizard), [ADR-030](<ADR-030 - IPv6.md>) (IPv6), [ADR-010](ADR-010-vps-satellite-reverse-proxy-backup.md) (the admin VPN), ADR-012 (backup placement), #692 (storage resolved against the node). |
| **Changelog** | v0.3 (2026-10-25) — **D1:** a pool on a partition: alignment, `ashift=12`, by-id names, one layout on every boot disk, and the runbook that replaces a failed disk for both pools; P1 rehearses it. · v0.2 (2026-10-25) — **D1:** `tanka1` is a real pool on the free part of the boot disk(s) (`hdsize`), not a dataset of `rpool` (the installer cannot name its pool, and storage names are pool names in TAPPaaS). **D2:** one IP — the firewall takes the server's address and MAC at the cut-over, with a rollback and a boot watchdog; two servers meet on a vSwitch; the virtual-MAC design becomes A5. · v0.1 (2026-10-25) — first draft. |

Three changes to how a TAPPaaS site comes into being, in the order they are built: a node with
**one disk** (or one mirrored pair) is a complete site; a site can be stood up on a **rented
server** with nothing but a public address and the provider's rescue system; and the installer
**stops after the bootstrap**, handing the rest of the install to the console's Setup wizard.

## Context

**Storage assumes data disks.** The Proxmox install formats only the boot disk, ext4 on LVM
(`node-provisioner/answer.py`). The data pools — `tanka1`, `tankb1`, `tankc1` — are whole-disk
ZFS pools that `cluster/config-storage.sh` builds on the *other* disks. TAPPaaS builds every
guest on ZFS zvols (`Create-TAPPaaS-VM.sh`: a directory or LVM storage is not a substitute).
42 module JSONs declare `"storage": "tanka1"`, and since #692 a declared pool the node lacks is a
refusal, because a declaration is taken as the operator's word. A node with one disk therefore
has no pool any module can use: the most common small machine, and every rented server with two
NVMe and nothing else, cannot run TAPPaaS.

**The install assumes a local network.** The first node is installed from a USB stick or PXE on
the site's own network, with a client on the upstream network driving it (INSTALL.md step 2:
"run from a client that is NOT on `10.0.0.0/24`"). A rented server has none of that: one public
IPv4 bound to the server's MAC, a routed IPv6 `/64`, no second network, no physical console —
only the provider's rescue system (SSH into a RAM Linux) and, on request, a remote KVM.

**The install is one long script.** `install.sh` runs the six steps of INSTALL.md (Proxmox, the
bootstrap, nodes, certificates, the rest of the foundation, switches) as scripts that ask
questions. ADR-034 D10 decided — and `ui/src/setup.ts` built — a Setup wizard in the console
that drives every step after the mothership exists, over the same verbs, resuming from the
records. But the installer still runs those steps itself, so the wizard is a second path, not the
path. And a bootstrap that fails half-way cannot simply be run again: a second run takes the node
for a second node (#377).

## Decision

### D1 — One disk is a site: the installer leaves room, and `tanka1` is a real pool on it

The Proxmox installer cannot name its ZFS pool — it is always `rpool` — and TAPPaaS treats a
storage's name as its pool's name in some 18 places (`zfs list $STORAGE/vm-…`, `zpool status`,
PBS placement, the storage inventory). So `tanka1` stays a pool of its own, on the free part of
the boot disk(s):

- **The install leaves space.** The answer file's `hdsize` limits what the installer uses
  (`disk-setup.lvm.hdsize` for ext4/LVM, `disk-setup.zfs.hdsize` for ZFS, honoured for the
  bootable disk or mirror). A node with no further disk is installed into a fixed system size
  (64 GiB), the rest of the disk left unpartitioned:
  - **one disk:** ext4/LVM, as today, in the first 64 GiB;
  - **two disks of the same size** (the usual rented server): ZFS `raid1` in the first 64 GiB of
    each, so the system itself is mirrored.
- **`tanka1` is created on the rest**: `config-storage.sh` adds a partition in the free space of
  each boot disk and builds `tanka1` there — a single vdev on one disk, a mirror on two — and
  registers it as the Proxmox storage `tanka1` as today. Every module that declares `tanka1`, and
  every place that takes a storage name for a pool name, works unchanged. What is new is a pool on
  partitions rather than whole disks, which `config-storage.sh` and the free-disk test learn.
- **A pool on a partition is as good as one on a disk.** Proxmox's own ZFS install puts `rpool`
  on partition 3; on Linux a whole disk adds only ZFS writing the partition table itself and
  setting the I/O scheduler to `none`, the default on NVMe and SSDs anyway. Three rules make the
  difference not matter:
  - **aligned:** the `tanka1` partition starts on a 1 MiB boundary (`sgdisk`'s default) and runs to
    the end of the disk, and the pool is created with `ashift=12`;
  - **named by id:** the pool is built on `/dev/disk/by-id/<disk>-part<N>`, never on a kernel
    name such as `nvme0n1p4`, which can name another disk after a reboot;
  - **one layout on every boot disk:** the disks of a mirror carry the same partition table, so a
    replacement disk is a copy of its partner's.
- **A failed disk is replaced for both pools at once.** The runbook, in `cluster/README.md` and
  rehearsed in P1:
  1. `sgdisk -R /dev/disk/by-id/<new> /dev/disk/by-id/<healthy>` and `sgdisk -G
     /dev/disk/by-id/<new>`: the partner's partition table, with new GUIDs;
  2. `zpool replace rpool <old>-part3 <new>-part3`, then `proxmox-boot-tool format` and `init` on
     `<new>-part2`, so the node boots from either disk (two-disk ZFS installs only);
  3. `zpool replace tanka1 <old>-part<N> <new>-part<N>`, and wait for both resilvers
     (`zpool status`) before anything else;
  4. on a one-disk node there is no partner: the new disk is installed as in D1 and the guests are
     restored from the off-node backup.
- **The system pool and `tanka1` share the disk's I/O.** The system part is small and quiet; the
  disk's throughput is in practice the guests'. A node that needs more gets a data disk, and is
  then a node like any other.
- **`tankb1` is optional and absent** on such a node; a module that declares `tankb1` is
  placed by D1b.
- **Backups go off the node.** A PBS datastore on the same disk protects against nothing that
  matters here. A one-disk site's backup target is off-node: a second machine, a backup buddy
  ([ADR-031](<ADR-031 - Site Liveness from the Backup Buddy.md>)), or an off-site box. `backup:vm`
  warns, rather than fails, while none is set.

**D1b — A release's pool choice falls back; an operator's does not (#403).** A pool a module's
*release* declares is a default, not the operator's word: when the node lacks it, the guest goes
to the first of `tanka1`, `tankb1` that the node has, with a warning, and the placement is written
to the module's config so it stays put. A pool the *operator* set (`module modify --set
storage=…`, recorded in `<module>.json.operator` since #488) remains a refusal, as #692 decided.

### D2 — A hosted server with one IP: the firewall takes the server's address

A rented dedicated server (Hetzner Robot is the reference) has one public IPv4 and a routed
IPv6 `/64`, both bound to the MAC of its NIC: the provider's switch answers that MAC only. The
site uses that one address — no additional IP is rented:

- **It installs, and boots, as a plain server.** After the install the node holds the public
  address on its NIC, and the operator runs the bootstrap over SSH to it.
- **The cut-over hands the address to the firewall.** The node's NIC takes a generated,
  locally administered MAC and no address; the firewall VM's WAN NIC, on the `wan` bridge over
  that NIC, takes the server's real MAC and the public IPv4 and IPv6; an `ebtables` rule on the
  bridge rewrites the source MAC of anything leaving to the real one, so no other MAC ever reaches
  the provider's switch (the cause of the MAC-abuse notices others report). From then on `lan`
  is what it is at home — the node's management address, behind the firewall — except that it has
  no physical port: the node reaches the internet through the firewall, like every guest.
- **It is the cut-over TAPPaaS already makes, with a way back.** As with `node network set`, the
  change runs under a rollback: unless the operator confirms through the new path within a few
  minutes, the node takes its MAC and address back. And at every boot a watchdog on the node
  gives the address back to the node — firewall VM stopped first — when the firewall has not
  answered for a set time, so a broken firewall leaves the server reachable over SSH, and the
  provider's rescue system is the last resort, not the plan.
- **The operator reaches the site through the admin VPN.** The bootstrap creates the first
  admin-VPN peer (ADR-010 P5) and prints its WireGuard config; the console and the node are
  reached through it. SSH to the public address lands on the firewall, which forwards nothing.
- **IPv6 starts off for the zones.** ADR-030 gives each zone a `/64` out of a delegated prefix;
  one routed `/64` is the firewall's WAN. The site starts with `ipv6: false` (O2).
- **Two servers meet on the provider's vSwitch.** Only a site of two or more hosted servers gives
  `lan` a port: a vSwitch VLAN (Hetzner: a VLAN ID 4000–4091 on the same NIC, MTU 1400), which
  becomes the `lan` bridge's uplink on each node and carries corosync and the zones between them
  (O5). A single server's `lan` has no port.
- **Installed from the rescue system.** The rescue system boots the TAPPaaS auto-install ISO in
  QEMU with the server's disks passed through, so the same answer file installs it as at home;
  after a reboot the node's NIC is pinned by MAC (`pve-network-interface-pinning`), since QEMU's
  NIC names are not the server's. The provider's own image installer and its remote KVM are
  alternatives (A3, A4), not the path.

### D3 — The installer ends at the console; the Setup wizard is the rest of the install

- **`install.sh` runs the bootstrap and stops**: Proxmox prepared, the firewall, the network
  cut-over, the mothership, and the console with its setup token (ADR-034 D10). Its last screen is
  the console's address with the token, and — on a hosted server, or with `--admin-vpn` — the
  first admin-VPN peer's config.
- **Steps 3 to 6 of INSTALL.md are the Setup wizard's**: certificates, the rest of the foundation
  (backup, identity, logging, the identity bootstrap), more nodes, switches and access points,
  stacks. INSTALL.md describes them as the wizard's pages; each names the verbs it runs.
- **The scripts stay, behind `install.sh --all`**, for headless installs and the test sites'
  automation, running the same verbs in the same order as the wizard. One sequence, two drivers.
- **The bootstrap can be run again (#377).** It decides what is left from the records it writes —
  the firewall VM, the cut-over marker, the mothership VM, the console unit — not from whether a
  cluster exists, so a second run after a failure continues where the first stopped, and only
  `pvecm` membership with another node makes a node a second node.

## Consequences

- A €40-a-month rented server, or a mini-PC with one SSD, is a site. Tests and demos no longer
  need hardware at home; a hosted site is also the off-site test bed #671 waits for.
- A one-disk site has no redundancy below the guest: a disk failure is a restore. A two-disk
  server mirrors its boot pool, which D1 makes the default for two equal disks.
- The install's questions move from a terminal into forms. The terminal path stays for
  automation, so the scripts cannot rot: the hrossen and makerfloss automation keeps using them.
- `config-storage.sh` learns a pool on partitions of the boot disk(s), and the answer file a
  system size; the module JSONs, `resolve_storage` and every reader of pool names do not change
  for D1.
- D1b changes #692's behaviour for release-declared pools only, which needs the #488 ledger to
  tell the two apart; a site whose operator set `storage` before #488 has no record, and its
  module is treated as release-declared (it falls back with a warning, never fails).

## Alternatives considered

- **A0 — `tanka1` as a dataset of the boot pool** (`rpool/tanka1`, registered as storage
  `tanka1`). The first draft. Rejected: TAPPaaS takes a storage name for a pool name in some 18
  places, which would all have to learn the difference.
- **A1 — Build guests on `local-lvm`** (the stock ext4/LVM boot disk). Keeps the installer as it
  is, but every zvol assumption — snapshots, replication, the stale-ZFS pre-flight, `cluster:ha`
  replication — would need an LVM twin. Rejected: ZFS on the boot disk is one installer choice.
- **A2 — Rename the pools** (`root`, `data`) and teach every module a placement list. #403's
  first idea. Rejected for D1: the dataset named `tanka1` gives the same result without touching
  42 modules; D1b keeps the useful half (fall back instead of fail).
- **A3 — The provider's image installer** (Hetzner `installimage`, Debian + Proxmox packages). A
  second install path to maintain, with a layout of the provider's choosing.
- **A4 — The provider's remote KVM** with our ISO as virtual media. Needs a support request and a
  time-limited session; fine as a fallback, not as the documented path.
- **A5 — An additional IP with a virtual MAC** for the firewall, the node keeping the main IP.
  Simpler — no MAC handover, no watchdog — but a second address to rent per site, and the node
  stays on the internet. The operator wants one address (2026-10-25).
- **A6 — A routed WAN** (the node keeps the public IP and routes to the firewall). The node is the
  internet-facing host and the firewall is no longer the edge.

## Open questions

- **O1 — Which providers.** Hetzner Robot is the reference. Do OVH/SoYouStart (virtual MAC: yes)
  and Hetzner Cloud (no bridging; a different edge) belong in D2, or in a later ADR?
- **O2 — IPv6 on a hosted site.** A routed `/64` cannot be split into zones. Ask the provider for
  a `/56` (Hetzner offers additional subnets for some products), NPTv6 from ULA zones, or stay
  IPv4-only. Decided when the first hosted site exists.
- **O5 — The zones between two hosted servers.** A vSwitch is one VLAN; whether it carries the
  zones' own VLAN tags inside it (QinQ) is not documented. If not: one vSwitch per zone (an account
  has a limited number), or VXLAN over the one vSwitch (Proxmox SDN), at an MTU of 1350.
- **O6 — The provider's tolerance.** Others report MAC-abuse notices from this pattern, explained
  by MACs leaking past the bridge, and one a setup that stopped working after a year. Ask
  Hetzner support before the first hosted site is a production one.
- **O3 — The QEMU install's network.** The answer file takes DHCP; on a hosted server the public
  address is static. Bake it in at build time (`--fqdn`, address, gateway), or let the first boot
  take DHCP from the provider (Hetzner answers DHCP for the main IP)?
- **O4 — The wizard's order for a hosted site.** Certificates before identity needs the public DNS
  record; the hosted site's domain may not exist yet. A step for the DNS record (#830) first?

## Implementation plan

| Step | What | Ease | Risk | Test |
|------|------|:-:|:-:|------|
| **P1 — one disk** | answer file: a 64 GiB system (`hdsize`), ext4/LVM on one disk, ZFS `raid1` on two, when there is no data disk (`--single-disk`, auto-detected for the auto-ISO); `config-storage.sh`: the aligned partition on each boot disk and `tanka1` on them by id, `ashift=12`; the disk-replacement runbook; `backup:vm`'s warning without an off-node target | M | M | VMs on hrossen with one and with two virtual disks, installed from the auto-ISO; `cluster/test.sh --deep` and one module per stack on them; on the two-disk VM, one disk replaced by the runbook and the node rebooted from the new one |
| **P1b — D1b** | `resolve_storage`: a release-declared pool falls back with a warning and the placement is written; an operator-declared one (ledger) refuses | L | M | unit cases in the VM-creation tests; one live create on a node without `tankb1` |
| **P2 — a hosted server** | the MAC handover at the cut-over (generated MAC on the NIC, the real one on the firewall's WAN, the `ebtables` rule), its rollback and boot watchdog, the first admin-VPN peer from the bootstrap, the rescue-system QEMU install documented as `INSTALL-HOSTED.md` | H | H | a scratch Hetzner server, the whole install, `site-manager test --deep`, then a teardown (the server cancelled) |
| **P3a — the bootstrap ends at the console** | `install.sh` stops after the console is up and prints its address, the token and the VPN config; `--all` keeps the scripted path | M | M | a fresh install on the hosted server, the rest done in the wizard |
| **P3b — the bootstrap runs again** (#377) | the bootstrap's steps decide from their records; a second run continues | M | M | a bootstrap killed at each step and run again, on a scratch VM |
| **P3c — INSTALL.md** | steps 3–6 as the wizard's pages, the scripts as the headless path | L | L | a read-through by the operator |

2.4 target: this ADR decided, P1 built and live, P2 standing on a scratch hosted server and torn
down, P3a designed with its first page (certificates) in the wizard. P3b and P3c in 2.5.
