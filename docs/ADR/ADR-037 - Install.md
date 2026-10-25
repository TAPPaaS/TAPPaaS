# ADR-037 — Install: one disk, a hosted server, and a bootstrap that hands over to the console

| | |
|---|---|
| **Status** | **Proposed** (draft for the operator) |
| **Version** | 0.1 |
| **Date** | 2026-10-25 |
| **Author** | Lars Rossen |
| **Deciders** | @LarsRossen |
| **Closes / addresses** | #403 (install on the root disk; smarter placement), #377 (the installer cannot restart; the management-network question), the 2.4 install theme. Builds on [ADR-034](<ADR-034 - TAPPaaS User Interface.md>) D10 (the Setup wizard), [ADR-030](<ADR-030 - IPv6.md>) (IPv6), [ADR-010](ADR-010-vps-satellite-reverse-proxy-backup.md) (the admin VPN), ADR-012 (backup placement), #692 (storage resolved against the node). |
| **Changelog** | v0.1 (2026-10-25) — first draft: D1 one disk, D2 a hosted server (Hetzner), D3 the bootstrap ends at the console. |

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

### D1 — One disk is a site: the boot pool carries `tanka1`

A node installed with **ZFS on its boot disk** gets `tanka1` as a dataset of that pool:

- **The install formats the boot disk(s) as ZFS** when the node has no further disk for a data
  pool: `raid0` on one disk, `raid1` (a mirror) on two of the same size. A node with data disks
  keeps today's layout (ext4/LVM boot disk, whole-disk tank pools), unchanged.
- **`rpool/tanka1` is created and registered as the Proxmox storage `tanka1`** (zfspool, images
  and rootdir) by `config-storage.sh`, which recognizes the case — the boot pool is the only
  pool — rather than offering to build pools from disks that do not exist. Every module that
  declares `tanka1` works unchanged; #692's rule stands; `resolve_storage` needs no new branch.
- **`tankb1` is optional and absent** on such a node; a module that declares `tankb1` is
  placed by D1b.
- **Backups go off the node.** A PBS datastore on the same disk protects against nothing that
  matters here. A one-disk site's backup target is off-node: a second machine, a backup buddy
  (ADR-031), or an off-site box. `backup:vm` warns, rather than fails, while none is set.
- **The boot pool's reserve.** `tanka1` gets a quota leaving the root filesystem a fixed reserve
  (20 % of the pool, at least 32 GB), so a full guest disk never stops the node itself.

**D1b — A release's pool choice falls back; an operator's does not (#403).** A pool a module's
*release* declares is a default, not the operator's word: when the node lacks it, the guest goes
to the first of `tanka1`, `tankb1` that the node has, with a warning, and the placement is written
to the module's config so it stays put. A pool the *operator* set (`module modify --set
storage=…`, recorded in `<module>.json.operator` since #488) remains a refusal, as #692 decided.

### D2 — A hosted server is a first node like any other, reached through the admin VPN

A rented dedicated server (Hetzner Robot is the reference; any provider with a rescue system and
an additional IP works the same way) is installed as a single-node site with D1's storage. What
differs is only the edge:

- **The firewall gets its own public address.** The provider's additional IPv4 with a **virtual
  MAC** goes to the firewall VM's WAN NIC on the `wan` bridge over the server's NIC — the same
  bridged WAN as on a site at home, so OPNsense, Caddy and the zone model are unchanged. (The
  main IP cannot be handed to a VM: the provider drops frames from any MAC but the server's.)
- **The node keeps its main IP, for the rescue path only.** Proxmox's own firewall admits SSH
  (key-only) on it and nothing else; the web UI, the API and everything TAPPaaS are reached from
  `mgmt`, as at home. If the firewall VM is down, the node is still reachable over SSH, and the
  provider's rescue system remains the last resort.
- **The operator reaches the site through the admin VPN.** There is no client on an upstream
  network: the bootstrap creates the first admin-VPN peer (ADR-010 P5) and prints its WireGuard
  config, and every later step — the console included — is done through it. The management-network
  question of #377 does not arise.
- **IPv6 starts off.** ADR-030 gives each zone a `/64` out of a delegated prefix; a hosted server
  has one routed `/64`. The site starts IPv4-only (`ipv6: false`), with the firewall's WAN on the
  `/64`; per-zone IPv6 waits for a larger prefix (O2).
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
- `config-storage.sh` gains one case (the boot pool is the only pool) and the answer file one
  choice (ZFS on the boot disk); the module JSONs and `resolve_storage` do not change for D1.
- D1b changes #692's behaviour for release-declared pools only, which needs the #488 ledger to
  tell the two apart; a site whose operator set `storage` before #488 has no record, and its
  module is treated as release-declared (it falls back with a warning, never fails).

## Alternatives considered

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
- **A5 — A routed WAN** (the node keeps the public IP and routes to the firewall). No extra IP to
  rent, but the node itself is the internet-facing host and the firewall is no longer the edge:
  the model every other site has would not hold.

## Open questions

- **O1 — Which providers.** Hetzner Robot is the reference. Do OVH/SoYouStart (virtual MAC: yes)
  and Hetzner Cloud (no bridging; a different edge) belong in D2, or in a later ADR?
- **O2 — IPv6 on a hosted site.** A routed `/64` cannot be split into zones. Ask the provider for
  a `/56` (Hetzner offers additional subnets for some products), NPTv6 from ULA zones, or stay
  IPv4-only. Decided when the first hosted site exists.
- **O3 — The QEMU install's network.** The answer file takes DHCP; on a hosted server the public
  address is static. Bake it in at build time (`--fqdn`, address, gateway), or let the first boot
  take DHCP from the provider (Hetzner answers DHCP for the main IP)?
- **O4 — The wizard's order for a hosted site.** Certificates before identity needs the public DNS
  record; the hosted site's domain may not exist yet. A step for the DNS record (#830) first?

## Implementation plan

| Step | What | Ease | Risk | Test |
|------|------|:-:|:-:|------|
| **P1 — one disk** | answer file: ZFS on the boot disk(s) when there is no data disk (`--single-disk`, auto-detected for the auto-ISO); `config-storage.sh`: `rpool/tanka1` with its quota, registered as `tanka1`; `backup:vm`'s warning without an off-node target | M | M | a VM on hrossen with one virtual disk installed from the auto-ISO; `cluster/test.sh --deep` and one module per stack on it |
| **P1b — D1b** | `resolve_storage`: a release-declared pool falls back with a warning and the placement is written; an operator-declared one (ledger) refuses | L | M | unit cases in the VM-creation tests; one live create on a node without `tankb1` |
| **P2 — a hosted server** | the virtual-MAC WAN (`--wan-mac` for the firewall VM), the node's SSH-only firewall on the main IP, the first admin-VPN peer from the bootstrap, the rescue-system QEMU install documented as `INSTALL-HOSTED.md` | H | M | a scratch Hetzner server, the whole install, `site-manager test --deep`, then a teardown (the server cancelled) |
| **P3a — the bootstrap ends at the console** | `install.sh` stops after the console is up and prints its address, the token and the VPN config; `--all` keeps the scripted path | M | M | a fresh install on the hosted server, the rest done in the wizard |
| **P3b — the bootstrap runs again** (#377) | the bootstrap's steps decide from their records; a second run continues | M | M | a bootstrap killed at each step and run again, on a scratch VM |
| **P3c — INSTALL.md** | steps 3–6 as the wizard's pages, the scripts as the headless path | L | L | a read-through by the operator |

2.4 target: this ADR decided, P1 built and live, P2 standing on a scratch hosted server and torn
down, P3a designed with its first page (certificates) in the wizard. P3b and P3c in 2.5.
