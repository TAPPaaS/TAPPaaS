# A single-node TAPPaaS on a Hetzner dedicated server

**Status:** DRAFT 0.1 (2026-11-05), for the operator's review. Refines
[ADR-037](<../ADR/ADR-037 - Install.md>) D2 for one server, against what the install is today
(`bootstrap-tappaas.sh`, the Day 1 wizard, a lone node's LAN with no port, no VPN peer made for
the operator). Part of #915.

## 1. What is different from a machine at home

| | At home | Hetzner dedicated server |
|---|---|---|
| Getting the installer onto it | USB stick or network boot from the operator's computer | Only the **rescue system**: a RAM Linux reached by ssh. A remote KVM with ISO mounting is a paid, booked extra |
| Its address | DHCP from the home router | **One static public IPv4** (Hetzner is phasing DHCP out for dedicated servers) and a **routed IPv6 /64** |
| The wire | Any number of MACs | Hetzner's switch accepts **the server's own MAC only**; any other MAC is an abuse report. Changing the hardware address by hand is against Hetzner's terms. Extra MACs exist only for extra IPs, generated in Robot (at most 6) |
| LAN | A port, or "this machine alone" | **Alone**: one NIC, and it is the WAN |
| The operator | On the install LAN, beside it | On the internet. Nothing is reached except through the server's one address |

Hetzner **Cloud** servers are out: they expose no virtualisation extensions to the guest, so
Proxmox cannot run VMs on them. The product is a Robot dedicated server (or one from the
Server Auction) of at least the single-node minimum: 32 GB, 0.5 TB NVMe. Two equal NVMe disks,
the usual configuration, give a mirrored boot pool (ADR-037 D1).

## 2. The shape of the site

The same as a one-port machine at home, with the firewall holding the public address:

```
internet ── Hetzner switch (accepts the server's MAC only)
               │
            NIC (real MAC) ── bridge wan ── firewall VM WAN: the public IPv4, the real MAC
                                             │  (OPNsense: the edge, the admin VPN on UDP 51821)
                                bridge lan (no port) ── mgmt 10.0.0.0/24: the node, tappaas-cicd,
                                                         and every zone's VLAN, inside the server
```

Nothing but the firewall answers on the public address. The node itself reaches the internet
through the firewall, like every guest. The operator reaches the console and the node through
the **admin VPN**.

## 3. The install, start to end

### 3.1 The operator, before the script

1. Rents the server in Robot, with its ssh key for the rescue system.
2. In Robot: Rescue → activate (Linux, 64-bit, the key), then Reset → hardware reset.

That is all done by hand: Robot's web service could do it, but it needs the operator's Robot
credentials, which TAPPaaS does not hold.

### 3.2 `bootstrap-tappaas.sh`, a sixth choice

```
  6) Install TAPPaaS on a rented server (Hetzner), through its rescue system
```

Asked up front, as for the others: the server's address, the admin email, the root password,
the site's name and size (small fits one server). Then it runs without questions:

1. **The operator's VPN key, made here.** `wg genkey` on the operator's computer; the private
   key never leaves it, the public key goes with the install. This is the operator setting up
   their own WireGuard first: the VPN step on Day 1 reads it as done, because it is the
   operator's device. The config is written to the operator's computer at the end (§3.4).
2. **The build runs on the rescue system**, not on the operator's computer: the script copies
   itself there and runs the build in the rescue system (Linux, so it fetches the Proxmox
   assistant itself, as on any Linux). The stock ISO is downloaded there from Proxmox, at the
   data centre's speed, instead of 1.5 GB up from a home line.
3. **The network, read from the rescue system:** the main IPv4, its gateway and the /64 from
   `ip addr` / `ip route` (the rescue system runs on them), and the NIC's MAC. They go into the
   answer file as a static network (`[network] source = "from-answer"`). This settles ADR-037 O3.
4. **The install in QEMU:** the rescue system runs the auto-install ISO in QEMU with KVM, UEFI
   (OVMF) when the server boots UEFI, the server's disks as raw drives, and a virtio NIC that
   carries **the server's real MAC**. The installer pins the interface name by that MAC, so after
   the reboot the real NIC has the name the installed system expects (ADR-037 D2's pinning, done
   by the installer instead of afterwards). The boot disk choice is the usual one: two equal
   NVMe disks become a mirror. QEMU's own network is user-mode NAT: the installer needs none of
   the server's address while in QEMU.
5. **Reboot into Proxmox:** the script turns rescue off (it is a one-boot setting, so a plain
   reboot leaves it), reboots the server, and waits for ssh on the public address with the
   install key, as it waits for a node at home.
6. **The TAPPaaS install**, over ssh, in tmux on the node, as at home, with one difference: the
   firewall's WAN is not on the wire yet (§3.3).

### 3.3 The firewall behind the node, then the handover

Two MACs on the wire is the one thing Hetzner punishes, so the firewall cannot have a WAN of its
own while the node still holds the address. The install runs in two phases:

**Phase 1 — the firewall behind the node (the whole install).** The firewall's WAN is on an
internal bridge (`wanstage`, 192.0.2.0/30 or similar) and the node NATs it out through its own
public address. The firewall reaches the internet, so everything that installs through it works:
OPNsense's packages, tappaas-cicd, the NixOS builds. The node stays reachable over ssh on its
public address, so the operator's install session never drops. The node forwards UDP 51821 to
the firewall, so the operator's VPN works already in this phase.

**Phase 2 — the handover (the last step of the bootstrap, with a way back).**

1. The firewall's WAN NIC moves to the `wan` bridge, with **the server's real MAC** and the
   public IPv4 and IPv6 (static, gateway as read in §3.2: OPNsense's "far gateway" for a /32).
2. The node's NIC takes a generated, locally administered MAC and no address. An `ebtables`
   rule on `wan` rewrites the source MAC of every frame leaving through the NIC to the real one,
   so the switch never sees another MAC.
3. **The rollback:** unless the operator's VPN reaches the node within 10 minutes, everything
   above is undone and the node has its address back. The script on the operator's computer
   brings the VPN up (§3.4) and confirms, so a working handover needs no one to click.
4. **The watchdog, at every boot:** when the firewall has not answered for 15 minutes, the node
   stops it and takes the address back. A broken firewall leaves the server on ssh; the rescue
   system is the last resort.

ADR-037 D2 had the handover as the cut-over itself. Moving it to the end, behind phase 1, keeps
the operator's ssh session through the whole install and makes the handover a single, last,
reversible step.

### 3.4 The operator's way in

At the end the script writes the operator's WireGuard config (their private key, the site's
public key and the public address as endpoint) to the operator's computer, `~/.tappaas/wg/<site>.conf`
on a Mac (`tappaas-wg.sh up <site>` then works), and prints the console's address
`http://10.0.0.x:9097/setup/day1` and how to show the setup token, which is now read through the
VPN.

The ssh tunnel through the node that the install's end note offers for a public WAN does not
work here: after the handover the public address is the firewall's. A hosted site's end note
says to bring up the VPN instead.

### 3.5 Day 1 on a hosted server

| Step | On a hosted server |
|---|---|
| First node: LAN port and disks | **This machine alone**; **Boot pool only** (or a pool on the second disk if the boot pool is not mirrored) |
| More nodes | No more machines (two servers are §5) |
| Admin VPN | **Done**: the operator's device was enrolled by the install |
| Rest of foundation | As at home. **Backup** needs an off-node target: a backup buddy or a second site; until then the placeholder |
| Health checks | As at home, no VLAN across nodes |
| Switches, Wi-Fi, physical site | Not applicable: answer none |
| Make it public | Natural here: the site has a public address. A domain with a DNS provider token gives public certificates |

## 4. Open points

- **H1 — Hetzner's word on the handover.** The design keeps the real MAC as the only one on
  the wire, but Hetzner's terms forbid changing the hardware address by hand, and others report
  abuse notices for setups like it. Ask Hetzner support before a production site, describing
  exactly §3.3. **If the answer is no**, the supported way is ADR-037 A5: an additional IP with
  a virtual MAC generated in Robot for the firewall's WAN (a monthly cost), and the node keeps
  the main IP, closed to everything but the VPN-forwarded ssh. Phase 1 is the same; phase 2
  becomes "the firewall's WAN on `wan` with Robot's MAC", with no ebtables and no watchdog.
  **Recommendation:** build phase 1 first (it is needed either way), ask Hetzner in parallel,
  and build phase 2 to the answer.
- **H2 — The /32 gateway.** Hetzner's current examples configure the main IP as /32 with the
  gateway on-link. Whether Proxmox's answer file and OPNsense take that as given, or need the
  subnet's real mask (/26 or /27, shown in Robot), is to be found on the first server.
- **H3 — IPv6.** The /64 is routed to the link-local address made from the server's MAC, so it
  follows the real MAC to the firewall at the handover. The zones start IPv4-only (ADR-037 O2).
- **H4 — Rescue system ZFS and UEFI.** The rescue system needs no ZFS: the installer in QEMU
  makes the pool. Whether the server boots UEFI or legacy decides OVMF or SeaBIOS in QEMU; the
  script reads `/sys/firmware/efi` in the rescue system. A server with CSM on alongside UEFI is
  reported not to boot the rescue system's PXE; Robot's docs say to turn CSM off.
- **H5 — The setup token over the VPN only.** Until identity is installed, the console takes the
  token from mgmt and the VPN. On a hosted site that is the VPN only; the install-LAN forward
  (`install-access.sh open`) sees a public WAN and opens nothing, as now.

## 5. Two or more servers (later)

A second server joins over Hetzner's vSwitch: one VLAN (4000–4091, MTU 1400) on the same NIC as
`lan`'s uplink on each server. The site's zones need their own VLANs inside it: VXLAN over the
vSwitch (Proxmox SDN), MTU 1350 (ADR-037 O5). Corosync and the nodes' mgmt run on it. Not part
of this design.

## 6. Order of work

1. `bootstrap-tappaas.sh` choice 6 up to a Proxmox node on the public address: the build on the
   rescue system, the static network in the answer file, QEMU with the real MAC, the reboot.
   Tested on a rented server (H2, H4 found there).
2. Phase 1: the firewall behind the node, the forwarded VPN port, the operator's key enrolled
   by the install, the config written back. A full install to Day 1 on the rented server.
3. H1 answered, then phase 2 to that answer, with its rollback and watchdog tested (the firewall
   stopped, the server power-cycled from Robot).
4. `INSTALL-HETZNER.md` (published as the overview's second option), and the overview's "in
   development" note removed.
