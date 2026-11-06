# TAPPaaS on Hetzner: one server, then a cluster

**Status:** DRAFT 0.2 (2026-11-06), for the operator's review. Two alternatives for where the
firewall runs: **A** on a Hetzner Cloud server beside the dedicated servers, **B** on the
dedicated servers themselves with an IP of its own. Each is described from a single server to a
true cluster. Refines [ADR-037](<../ADR/ADR-037 - Install.md>) D2 and O5. Part of #915.

Draft 0.1 had the firewall take over the server's own MAC and address at the end of the install
(an ebtables rewrite, a rollback and a boot watchdog). Both alternatives here drop that: the
firewall's public address is never the node's.

## 1. What is different from a machine at home

| | At home | Hetzner dedicated server |
|---|---|---|
| Getting the installer onto it | USB stick or network boot from the operator's computer | Only the **rescue system**: a RAM Linux reached by ssh. A remote KVM with ISO mounting is a paid, booked extra |
| Its address | DHCP from the home router | **One static public IPv4** (Hetzner is phasing DHCP out for dedicated servers) and a **routed IPv6 /64** |
| The wire | Any number of MACs | Hetzner's switch accepts **the server's own MAC**, plus the virtual MACs Robot generates for additional IPs. Any other MAC is an abuse report |
| Between servers | A switch with any VLANs | A **vSwitch**: one VLAN (4000–4091), MTU 1400, on the same NIC, at most 32 MACs per port |
| The operator | On the install LAN, beside it | On the internet. Nothing is reached except through public addresses |

Hetzner **Cloud** servers cannot host Proxmox: they expose no virtualisation extensions, so the
nodes are always Robot dedicated servers (or Server Auction ones) of at least the single-node
minimum: 32 GB, 0.5 TB NVMe. Two equal NVMe disks give a mirrored boot pool (ADR-037 D1). A Cloud
server can run a plain operating system, such as OPNsense from Hetzner's ISO library, which is
what alternative A uses.

## 2. Common to both: the node from the rescue system

### 2.1 The operator, before the script

1. Rents the server in Robot, with its ssh key for the rescue system.
2. In Robot: Rescue → activate (Linux, 64-bit, the key), then Reset → hardware reset.
3. Orders what the alternative needs: a Cloud server (A, §3.1) or an additional IP with a
   virtual MAC (B, §4.1).

Done by hand: Robot's and Cloud's web services could do it, but they need the operator's Hetzner
credentials, which TAPPaaS does not hold.

### 2.2 `bootstrap-tappaas.sh`, a sixth choice

```
  6) Install TAPPaaS on a rented server (Hetzner), through its rescue system
```

Asked up front, as for the others: the server's address, the admin email, the root password,
the site's name and size, the alternative (A or B) and its addresses. Then it runs without
questions:

1. **The operator's VPN key, made here.** `wg genkey` on the operator's computer; the private
   key never leaves it, the public key goes with the install. The Day 1 VPN step reads it as
   done, because it is the operator's device. The config is written back at the end (§2.4).
2. **The build runs on the rescue system**: the script copies itself there; the rescue system
   is Linux, so it fetches the Proxmox assistant and the stock ISO itself, at the data centre's
   speed.
3. **The network, read from the rescue system:** the main IPv4, its gateway, the /64 and the
   NIC's MAC (`ip addr`, `ip route`), into the answer file as a static network
   (`[network] source = "from-answer"`). This settles ADR-037 O3.
4. **The install in QEMU:** the auto-install ISO in QEMU with KVM, UEFI (OVMF) when the server
   boots UEFI, the server's disks as raw drives, a virtio NIC carrying the server's real MAC, so
   the installer pins the interface name the installed system will see. QEMU's own network is
   user-mode NAT.
5. **Reboot into Proxmox:** rescue is a one-boot setting, so a plain reboot leaves it; the script
   waits for ssh on the public address with the install key.
6. **The TAPPaaS install**, over ssh, in tmux on the node, as at home, with the firewall placed
   as the alternative says (§3 or §4).

### 2.3 The node's own address

In both alternatives the node keeps its main IPv4 on its own MAC. The node's Proxmox firewall
drops everything on it except what the alternative needs (A: the vSwitch underlay; B: nothing
from outside). The node reaches the internet through the TAPPaaS firewall, like every guest
(the gateway cutover, as at home). The rescue system stays the last resort.

### 2.4 The operator's way in

At the end the script writes the operator's WireGuard config (their private key, the site's
public key, the firewall's public address as endpoint) to `~/.tappaas/wg/<site>.conf`
(`tappaas-wg.sh up <site>` then works), and prints the console's address
`http://10.0.0.x:9097/setup/day1` and how to show the setup token, read through the VPN. The ssh
tunnel through the node that the end note offers for a public WAN is not offered: the node is
closed on its public address.

### 2.5 The site's LAN across servers: VXLAN over the vSwitch

The site's `lan` is a VLAN trunk (mgmt untagged, every zone a VLAN). The vSwitch carries only one
VLAN, so `lan` crosses servers inside **VXLAN** over it (ADR-037 O5):

- On each node, `lan` stays the VLAN-aware bridge it is at home; its uplink is a `vxlan` port
  (one VNI for the whole trunk, unicast peers = the other servers' vSwitch addresses) instead of a
  physical port. Guests keep `bridge=lan,tag=<zone>`: no Proxmox SDN, no change to a guest.
- MTU: 1400 on the vSwitch, less 50 for VXLAN, gives **1350** on `lan` and every guest NIC; the
  firewall hands it out per zone (DHCP option 26), Proxmox sets it on the bridge.
- VXLAN is unencrypted. Within Hetzner's network that is the vSwitch's own trust level; a site
  that wants more puts VXLAN inside WireGuard (MTU about 1290).
- Corosync and storage replication run on the vSwitch VLAN's addresses directly, not on the
  overlay: a ring that depends on the overlay depends on the firewall's bridge (A) or on itself.

Nothing of this exists in the code yet. Alternative A needs it from the first server; B only
from the second.

### 2.6 Day 1 on a hosted server

| Step | On a hosted server |
|---|---|
| First node: LAN port and disks | **This machine alone** (A: the overlay is the LAN); **Boot pool only**, or a pool on the second disk if the boot pool is not mirrored |
| More nodes | The cluster steps of the alternative (§3.3, §4.3) |
| Admin VPN | **Done**: the operator's device was enrolled by the install |
| Rest of foundation | As at home. **Backup** needs an off-node target: a backup buddy, a second site, or (cluster) PBS on another server |
| Switches, Wi-Fi, physical site | Not applicable: answer none |
| Make it public | Natural here: the firewall has a public address. A domain with a DNS provider token gives public certificates |

## 3. Alternative A: the firewall on a Cloud server

```
internet ── Cloud server: OPNsense, its own public IPv4 + IPv6
               │ Cloud Network, coupled to the Robot vSwitch (routed: cloud ↔ dedicated is L3)
               │ VXLAN: one device per node, all in one bridge; zone VLANs on that bridge
            vSwitch VLAN 4000 ── node 1 (lan = VLAN-aware bridge, uplink vxlan) ── node 2 …
```

### 3.1 One server

1. **The operator** creates, in the Hetzner Cloud console, in the same network zone as the
   dedicated server (eu-central: Falkenstein, Nuremberg, Helsinki): a Cloud Network with a
   **vSwitch subnet** coupled to a new vSwitch, the dedicated server added to that vSwitch in
   Robot, and the smallest Cloud server in the network, booted from Hetzner's OPNsense ISO. The
   Cloud Network's range must not overlap 10.0.0.0/24 or any zone (e.g. 172.31.0.0/16).
2. **The node** comes up from the rescue system (§2.2). Its network gets the vSwitch VLAN with its
   underlay address, a route to the Cloud range, and `lan` with the vxlan port to the firewall's
   underlay address.
3. **The firewall's install** changes from creating VM 110 to configuring a running host:
   `config-firewall.sh` pushes the same config.xml over ssh, to the Cloud server's underlay
   address instead of the bootstrap 10.0.0.1 inside a VM; its LAN is a bridge of one vxlan device
   per node (OPNsense's vxlan takes one remote each), with the zone VLANs on that bridge. From
   then on it is `firewall.mgmt.internal` (10.0.0.1) on the overlay, and everything that talks to
   it over the API or ssh is unchanged: the zone, rules, DNS, NAT and DHCP managers, the
   certificates, the health checks.
4. The install continues as at home: tappaas-cicd, the console, Day 1. No MAC is ever shared,
   so there is no handover phase.

### 3.2 HA in alternative A

The firewall is outside Proxmox, so Proxmox HA does not cover it. A Cloud server whose host
fails is restarted by Hetzner, on its own schedule. Two steps, the second only for a cluster:

1. **Restore, always:** the firewall's config.xml is backed up off the server on every change
   (to PBS through cicd), and a new Cloud server from the ISO plus that config is the recovery.
   Hetzner's own Cloud backups are a cheaper second copy.
2. **A standby firewall:** a second Cloud server, a **Floating IP** as the site's public address,
   and on the overlay side **CARP** for the zones' gateway addresses. CARP needs multicast, which
   the Cloud Network lacks, but the overlay is VXLAN and replicates it to every peer, so CARP
   works between the two firewalls on `lan`. The WAN side has no shared L2, so the Floating IP is
   moved by Hetzner's Cloud API when the standby takes over: a watcher (on the QDevice server,
   §3.3) holds a Cloud API token scoped to the project. OPNsense's config sync (XMLRPC) keeps the
   standby's rules equal; the TAPPaaS managers address the primary.

### 3.3 Growing to a cluster

1. **The QDevice:** a second smallest Cloud server (Debian) in the same Cloud Network runs
   `corosync-qnetd`; `cluster/qdevice.sh` already adds and removes it. A QDevice and not a full
   corosync member: it needs only TCP 5403 and copes with latency, and two nodes plus a QDevice
   is Proxmox's supported shape. Not on OPNsense itself: there is no package, and the firewall
   stays free of extra software.
2. **The second dedicated server** comes up from the rescue system (§2.2) with the add-node
   choice, joins the vSwitch in Robot, gets its underlay address, and `lan`'s vxlan port gets it
   as a peer on every node and on the firewall (a second vxlan device in the firewall's bridge).
3. **Corosync** binds its ring to the vSwitch addresses (today: the mgmt address on `lan`).
4. **Storage and HA** as at home: ZFS replication over the vSwitch, HA groups for the guests.
5. **A third server** follows the same steps; with an odd node count the QDevice can go.
6. **The firewall's HA** (§3.2 step 2) whenever the site needs it, independent of the nodes.

### 3.4 What it costs

- Two small Cloud servers (firewall, QDevice) and a third with a standby firewall, monthly.
- All guest traffic leaves through the Cloud server: its included traffic (20 TB a month in the
  EU) and its throughput for OPNsense plus VXLAN are the limits. To be measured.
- The firewall is a separate machine to patch: `update-os.sh` reaches it over ssh as today.

### 3.5 What changes in the code

1. **A firewall that is not a VM:** `network/network.json` gains a host kind (no vmid, no node);
   `config-firewall.sh` configures a running host instead of creating VM 110.
2. **The VM-only paths skip it:** the trunk sync (`vm-net.sh`, `proxmox-controller trunks`), HA
   placement (which requires a node with `lan` and `wan`), its PBS VM job (replaced by the config
   backup), `ha-manager relocate vm:110` in `reboot-node.sh` and `remove-node.sh`, the guest
   agent install, the storage inventory. The guest start hook already copes with no firewall VM.
3. **The node's network:** a mode in `config-network.sh` with the vSwitch VLAN, `lan` uplinked by
   vxlan, no `wan` bridge (§2.5).
4. **OPNsense's LAN parent:** `zone_manager.py` has `vtnet0` built in as the VLAN parent; it
   becomes the site's LAN parent (the vxlan bridge here).
5. **Corosync's ring** on the vSwitch address.
6. **The console's topology:** the firewall is an external asset, the WAN path is the Cloud
   server, not "the node hosting VM 110".

## 4. Alternative B: everything on the dedicated servers

The firewall is a VM on a node, as at home, with **a second public IPv4 of its own**: an
additional IP with a virtual MAC generated in Robot. The node keeps the main IP on the real MAC;
both MACs are allowed on the port, so nothing breaks Hetzner's rules and there is no handover.

```
internet ── Hetzner switch (the server's MAC + the firewall's virtual MAC)
               │
            NIC ── bridge wan ── node: main IP, real MAC (closed, §2.3)
                       └──────── firewall VM WAN: additional IP, Robot's virtual MAC
                                   │
                    bridge lan (one server: no port) ── mgmt + every zone VLAN
```

### 4.1 One server

1. **The operator** orders one additional IPv4 in Robot and generates its virtual MAC (Robot:
   IPs → the MAC button). The /64 is routed to the main IP; it can be routed on to the firewall
   with a route on the node, or a separate /64 ordered for it (open point B1).
2. **The node** comes up from the rescue system (§2.2), main IP in the answer file.
3. **The firewall** is VM 110 as at home, with its WAN NIC on `wan` carrying **Robot's virtual
   MAC** (`config-firewall.sh` takes it as a parameter) and the additional IP static, with the
   gateway the main IP's gateway. Its WAN is on the wire from the first boot: no phase behind the
   node, no rollback, no watchdog.
4. The node's gateway cutover to 10.0.0.1, then everything as at home.

The code change for one server is small: the static WAN address and the given MAC in
`config-firewall.sh`, the closed node address (§2.3), and bootstrap choice 6.

### 4.2 HA in alternative B

On one server there is none, as at home on one machine. In a cluster the firewall VM is under
Proxmox HA like every guest, which is the point of B, **but** a virtual MAC belongs to one
server: an additional IP is routed to that server only, so the firewall cannot move with it. To
move, its WAN address has to be one that follows it:

- **B-cluster, recommended: a public subnet on the vSwitch.** Robot sells IPv4 (and IPv6)
  subnets routed into the vSwitch VLAN, usable on every server in it, gateway the subnet's first
  address. The firewall's WAN NIC sits on the vSwitch VLAN on whichever node it runs, with any
  MAC (up to 32 per port). Proxmox HA moves it like any guest. Reports say a moved address can
  take 1–5 minutes to be routed again (ARP on Hetzner's side): to be measured (B2).
- **Alternatively, a failover IP:** routed to one server's main IP and switched by the Robot API
  (40–110 s, rate limited). It has no virtual MAC: the node routes it to the firewall, and a hook
  on relocation calls Robot. Needs Robot credentials on the site; the subnet does not.

**Starting with the vSwitch subnet** on the first server avoids changing the public address
later (the domain's records, the operator's VPN endpoint) at the cost of a /29 or larger (three
addresses go to network, gateway and broadcast). A site that knows it will grow should start
there; §4.1 is the cheaper start for a site that may stay one server.

### 4.3 Growing to a cluster

1. **The vSwitch** (if not there yet): created in Robot, the first server added, its VLAN on the
   node with its address.
2. **The firewall's WAN moves** to the vSwitch public subnet (a new public address, once): its
   WAN NIC from `wan` to a bridge on the vSwitch VLAN, the new address, the domain's records and
   the operator's VPN endpoint updated. The additional IP is cancelled. (Skipped if the site
   started on the subnet.)
3. **The second dedicated server** comes up from the rescue system (§2.2) with the add-node
   choice and joins the vSwitch.
4. **`lan` across servers:** VXLAN over the vSwitch (§2.5), `lan`'s uplink a vxlan port on both
   nodes. The firewall's NIC stays `bridge=lan,trunks=…`, unchanged.
5. **The QDevice:** two nodes need a third vote. A small Cloud server (Debian) running
   `corosync-qnetd`, reached over a Cloud Network coupled to the vSwitch or over the internet
   (qnetd authenticates with its own certificates); `cluster/qdevice.sh` already does the
   Proxmox side. The only thing outside the dedicated servers in B.
6. **Corosync** on the vSwitch addresses; ZFS replication and HA groups, the firewall among them,
   placed on any node that has the vSwitch WAN bridge.
7. **A third server**: the same steps; the QDevice can go.

### 4.4 What it costs

- One additional IPv4 (single server), then a vSwitch public subnet (cluster), monthly.
- The QDevice Cloud server from two nodes on.
- Guest traffic leaves through the dedicated server's own uplink.

### 4.5 What changes in the code

1. **The firewall's WAN as given:** static address, gateway and MAC in `config-firewall.sh`;
   later its WAN bridge on the vSwitch VLAN.
2. **HA placement** (`cluster/services/ha`, `ha-bridge-lib.sh`): "a node with `lan` and `wan`"
   becomes "a node with `lan` and the firewall's WAN bridge".
3. **The node's network:** the vSwitch VLAN and `lan` uplinked by vxlan (§2.5), at the second
   server.
4. **Corosync's ring** on the vSwitch address.
5. **A WAN address change** as a supported operation (records, VPN endpoint, the firewall's
   `wan-address.json`), for §4.3 step 2.

## 5. The two side by side

| | A: firewall on a Cloud server | B: everything on dedicated servers |
|---|---|---|
| One server | Dedicated + Cloud server + Cloud Network + vSwitch | Dedicated + one additional IP |
| Install complexity, one server | VXLAN overlay from day one, a firewall that is not a VM | As at home, plus a static WAN and a given MAC |
| Firewall HA | Outside Proxmox: restore, then a standby with a Floating IP via the Cloud API and CARP on the overlay | Proxmox HA, once the WAN is a vSwitch subnet |
| Growing | Add servers; the firewall's address never changes | One WAN address change, unless started on the subnet |
| Outside the dedicated servers | Firewall, QDevice (and standby) | QDevice only |
| Guest traffic | Through the Cloud server (its traffic quota, its throughput) | The dedicated uplink |
| Code | More: a host-kind firewall, VM paths skipped, overlay from the start | Less: mostly the same as at home until the second server |
| Shared | §2: the rescue install, the closed node address, the VPN, VXLAN over the vSwitch for a cluster, corosync on the vSwitch, the QDevice | |

**Recommendation: B.** It keeps the firewall a guest like every other, so HA, backup, updates,
the console and node removal work as they do at home; the single server is close to today's
install; and everything a cluster needs beyond it (VXLAN, corosync on the vSwitch, the QDevice)
is needed by A as well. A is the better choice only if guest traffic should not leave through
the dedicated server, or if a Floating-IP firewall pair is wanted regardless of the node count.

## 6. Open points

- **H2 — The /32 gateway.** Hetzner's examples configure the main IP as /32 with the gateway
  on-link. Whether Proxmox's answer file and OPNsense take that, or need the subnet's real mask
  (shown in Robot), is to be found on the first server.
- **H4 — Rescue system UEFI.** UEFI or legacy decides OVMF or SeaBIOS in QEMU; the script reads
  `/sys/firmware/efi`. Robot's docs say to turn CSM off.
- **H5 — The setup token over the VPN only.** Until identity is installed, the console takes the
  token from mgmt and the VPN; on a hosted site that is the VPN.
- **X1 — VXLAN over the vSwitch with VLAN tags inside:** that a VLAN-aware bridge with a vxlan
  port carries the zone tags across, and (A) that OPNsense's VLANs on a bridge of vxlan devices
  work. Both alternatives need the first; A needs both from day one.
- **A1 — The Cloud server's throughput** for OPNsense with VXLAN, and the traffic quota.
- **A2 — CARP over the overlay and the Floating IP move**, timed end to end.
- **B1 — The additional IP's /64:** routed on by the node, or a separate /64 for the firewall.
- **B2 — The vSwitch subnet's re-routing time** after the firewall moves between nodes.
- **B3 — 32 MACs per vSwitch port**: enough for the firewall WAN; the overlay keeps guest MACs
  off the vSwitch (they are inside VXLAN).

## 7. Order of work

1. Bootstrap choice 6 up to a Proxmox node on the public address (§2.2), tested on a rented
   server; H2 and H4 found there. Common to both.
2. **X1 by hand** on two rented servers (and, for A, a Cloud server): VXLAN over the vSwitch
   with tagged zones, before any code depends on it.
3. B, one server: the static WAN and virtual MAC, the closed node address, the VPN key enrolled
   by the install. A full install to Day 1.
4. B, cluster: the vSwitch, `lan` over VXLAN, corosync on the vSwitch, the QDevice, the WAN move
   to a vSwitch subnet; B2 measured.
5. A, only if chosen for a site: the host-kind firewall and its skipped VM paths, then its HA.
6. `INSTALL/SINGLE-NODE-HETZNER.md` and `INSTALL/CLUSTER-HETZNER.md` written from what was
   built, and their "in development" notes removed.
