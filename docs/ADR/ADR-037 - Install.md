# ADR-037 — Install: one disk, a hosted server, and a bootstrap that hands over to the console

| | |
|---|---|
| **Status** | **Accepted** (operator, 2026-10-26) — P1 in progress |
| **Version** | 1.1 |
| **Date** | 2026-10-25 |
| **Author** | Lars Rossen |
| **Deciders** | @LarsRossen |
| **Closes / addresses** | #403 (install on the root disk; smarter placement — D1's fallback is a first step of #884, dynamic placement), #377 (the installer cannot restart; the management-network question), the 2.4 install theme. Builds on [ADR-034](<ADR-034 - TAPPaaS User Interface.md>) D10 (the Setup wizard), [ADR-030](<ADR-030 - IPv6.md>) (IPv6), [ADR-010](ADR-010-vps-satellite-reverse-proxy-backup.md) (the admin VPN), ADR-012 (backup placement), #692 (storage resolved against the node). |
| **Changelog** | v1.1 (2026-10-26) — D1: the fallback takes any other ZFS data pool before the boot pool (found building P1b: a node whose only pool is `tankc1` built there before, and would otherwise have been refused). · v1.0 (2026-10-26) — **Accepted** by the operator, with the boot-pool reserve at 20 %. D1: a mirrored `rpool` boots from either disk — every member's EFI system partition registered with `proxmox-boot-tool`, checked after the install and by the health check, re-initialised on a replaced disk; P1 tests booting from each disk alone. · v0.4 (2026-10-26) — **D1 reworked (operator):** one pool per disk — ZFS on the boot disk is the default and required without a data disk; a module's `storage` is a preference: the same class, any `tanka<N>`, then the boot pool (`local-zfs`), warned and recorded; any zfspool by its storage name (readers look the dataset up). The partition layout (v0.2–v0.3) and D1b become A0b and A2b. P2 is tested on the operator's spare machine on the WAN. · v0.3 (2026-10-25) — **D1:** a pool on a partition: alignment, `ashift=12`, by-id names, one layout on every boot disk, and the runbook that replaces a failed disk for both pools; P1 rehearses it. · v0.2 (2026-10-25) — **D1:** `tanka1` is a real pool on the free part of the boot disk(s) (`hdsize`), not a dataset of `rpool` (the installer cannot name its pool, and storage names are pool names in TAPPaaS). **D2:** one IP — the firewall takes the server's address and MAC at the cut-over, with a rollback and a boot watchdog; two servers meet on a vSwitch; the virtual-MAC design becomes A5. · v0.1 (2026-10-25) — first draft. |

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
refusal, because a declaration is taken as the operator's word; and in some 18 places a storage's
name is taken for its pool's name. A node with one disk therefore has no pool any module can use:
the most common small machine, and every rented server with two NVMe and nothing else, cannot
run TAPPaaS.

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

### D1 — One disk is a site: ZFS on the boot disk, and `storage` is a preference

A node keeps one pool per disk. Instead of making room for `tanka1` on the boot disk, the boot
disk's own pool carries the guests when the node has nothing else, and placement takes a pool the
node has rather than refusing the one it lacks:

- **ZFS on the boot disk is the default for every new install**, and **required for a node with
  no data disk**: `raid0` on one boot disk, `raid1` on two of the same size. The installer's pool
  is `rpool`, and Proxmox registers its `rpool/data` as the storage `local-zfs`, which TAPPaaS
  then builds guests on like any other zfspool. ext4/LVM on the boot disk stays possible for a
  node *with* data disks (`--boot-filesystem ext4`); the auto-ISO refuses it for a node without.
  The answer file caps ZFS's memory (`arc-max`) so the ARC does not compete with the guests. The
  data pools (`tanka1`, `tankb1`, …) on further disks are built as today.
- **A module's `storage` is a preference, not a requirement.** A guest goes to the storage its
  config names when the node has it; when the node does not, to the first that it has of:
  1. a pool of the same class with another number (`tanka2` for `tanka1`),
  2. any `tanka<N>` (for a `tankb…` or `tankc…` that is missing),
  3. any other ZFS data pool the node has (`tankc1`, or a pool named otherwise), so a node with
     a data disk keeps its guests off the boot disk — and a node whose only pool is `tankc1`
     builds there, as it did before,
  4. the boot pool (`local-zfs`), while the guest leaves it a reserve — 20 % of the pool free —
     since the root filesystem lives in the same pool; past that the create is refused.
  The move is a warning that names the storage asked for and the one used, and the storage
  used is written to the module's config, so the guest stays where it is on the next update.
  This reverses #692's refusal of a declared pool the node lacks: the module still runs, and
  the operator sees where.
- **Any zfspool, by its storage name.** A module may name any zfspool storage the node has, not
  only the `tank` pattern. TAPPaaS takes a storage's name for its pool's name in some 18 places
  (`zfs list $STORAGE/vm-…`, `zpool status`, the storage inventory, PBS placement); those learn
  the storage's dataset from Proxmox (`pool` in `/etc/pve/storage.cfg`: `local-zfs` →
  `rpool/data`, `tanka1` → `tanka1`) and its pool from that, so the boot pool and any other
  pool work everywhere a `tank` pool does.
- **Backups go off the node.** A PBS datastore on the same disk protects against nothing that
  matters here. A one-disk site's backup target is off-node: a second machine, a backup buddy
  ([ADR-031](<ADR-031 - Site Liveness from the Backup Buddy.md>)), or an off-site box. `backup:vm`
  warns, rather than fails, while none is set.
- **The node boots from either disk of the mirror.** ZFS mirrors only `rpool`'s partition; each
  disk also has its own EFI system partition (part 2) with the bootloader and the kernels, outside
  the pool and not mirrored by it. `proxmox-boot-tool` keeps every ESP it has registered in step
  — the kernel hook copies each new kernel to all of them — so TAPPaaS makes sure every disk of the
  mirror is registered: after the install it checks `proxmox-boot-tool status` lists an ESP on
  each `rpool` member, and initialises the one that is missing (`proxmox-boot-tool init`). The
  health check reports a mirror member without a registered ESP, since the node would then not
  boot when the other disk fails.
- **A failed disk.** A two-disk node replaces one by Proxmox's own procedure for a mirrored
  `rpool`: copy the partition table from the healthy disk (`sgdisk -R`, then `-G`), `zpool
  replace` the `rpool` partition, then `proxmox-boot-tool format` and `init` on the new disk's
  ESP, so it is bootable before the old one is gone for good. A one-disk node is reinstalled and
  its guests restored from the off-node backup.

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
- New installs boot from ZFS. An existing site's nodes keep their ext4/LVM boot disks; nothing
  is migrated, and a node added later takes the new default.
- `storage` stops being a promise: a guest can land on another pool than its module names, said
  in a warning and recorded in its config. #692's refusal goes; the operator still sees where
  every guest is (`module-manager module show`, the console's Physical view).
- The readers of pool names change once, to look a storage's dataset up; after that every
  zfspool works, the boot pool included. The module JSONs do not change.
- The boot pool and the guests share one disk's I/O and space. The root filesystem is a dataset
  in the same pool, so a guest that fills the pool can fill `/`: the pool's free space is a
  health gate (the disk-threshold check reads `rpool` too), and D1's placement leaves a reserve.

## Alternatives considered

- **A0 — `tanka1` as a dataset of the boot pool** (`rpool/tanka1`, registered as storage
  `tanka1`). v0.1. Rejected: a storage named like a pool that is not one misleads every reader.
- **A0b — `tanka1` as a pool on the boot disk's free part** (the installer limited by `hdsize`, a
  partition after it). v0.2–v0.3. Rejected (operator, 2026-10-26): two pools on one disk, a
  partition layout to keep and a disk replacement that must rebuild both, where one pool per
  disk needs none of it.
- **A1 — Build guests on `local-lvm`** (the stock ext4/LVM boot disk). Keeps the installer as it
  is, but every zvol assumption — snapshots, replication, the stale-ZFS pre-flight, `cluster:ha`
  replication — would need an LVM twin. Rejected: ZFS on the boot disk is one installer choice.
- **A2 — Rename the pools** (`root`, `data`) and teach every module a placement list. #403's
  first idea. Rejected: D1's fallback gives the same result without touching 42 modules.
- **A2b — Keep `storage` a requirement for the operator's own choice** (refuse a pool the
  operator set with `--set`, recorded since #488; fall back only for the release's). v0.1–v0.3
  (D1b). Rejected (operator, 2026-10-26): `storage` is a preference either way; a guest that runs
  elsewhere with a warning beats one that does not run.
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
| **P1 — ZFS boot** | answer file: ZFS on the boot disk by default (`raid0` on one, `raid1` on two equal), `arc-max`; ext4 only with data disks (`--boot-filesystem ext4`), refused for a node without; `config-storage.sh` with no data disk builds no pool and says the boot pool carries the guests; `backup:vm`'s warning without an off-node target | M | M | a VM on hrossen with one virtual disk installed from the auto-ISO; a VM with two equal disks: `proxmox-boot-tool status` lists both ESPs, and it boots with either disk detached; one disk replaced by the runbook and the node booted from the new one alone; the spare machine on one of its two disks |
| **P1b — placement** | `resolve_storage` (VM and LXC): the declared storage, else the same class, else any `tanka<N>`, else `local-zfs`, warned and written to the module's config; the storage → dataset lookup in every reader of pool names; the boot pool in the disk-threshold gate | M | M | unit cases in the VM-creation tests; on the one-disk node: `cluster/test.sh --deep` and one module per stack, each placed on `local-zfs` with its warning |
| **P2 — a hosted server** | the MAC handover at the cut-over (generated MAC on the NIC, the real one on the firewall's WAN, the `ebtables` rule), its rollback and boot watchdog, the first admin-VPN peer from the bootstrap, the rescue-system QEMU install documented as `INSTALL-HOSTED.md` | H | H | the spare machine on the WAN with its own public IP (a hosted server's edge): the whole install, the cut-over's rollback and the watchdog (a BMC power cycle with the firewall stopped), `site-manager test --deep`, then a teardown; Hetzner's own MAC filter, rescue install and vSwitch on a rented server later |
| **P3a — the bootstrap ends at the console** | `install.sh` stops after the console is up and prints its address, the token and the VPN config; `--all` keeps the scripted path | M | M | a fresh install on the hosted server, the rest done in the wizard |
| **P3b — the bootstrap runs again** (#377) | the bootstrap's steps decide from their records; a second run continues | M | M | a bootstrap killed at each step and run again, on a scratch VM |
| **P3c — INSTALL.md** | steps 3–6 as the wizard's pages, the scripts as the headless path | L | L | a read-through by the operator |

2.4 target: this ADR decided, P1 and P1b built and live, P2 standing on the spare machine and
torn down, P3a designed with its first page (certificates) in the wizard. P3b and P3c in 2.5.
