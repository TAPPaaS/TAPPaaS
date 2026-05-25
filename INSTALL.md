# Installing TAPPaaS

This is the short, precise install guide. It reflects the **automated** install:
the firewall and the NixOS VM template are now prebuilt images that download and
boot preconfigured, and the bootstrap scripts chain together — so most steps are
"run one command and watch".

> Defaults (subnet, hostnames, sizing, passwords, branch, …) work out of the box.
> Anywhere a default is mentioned, it can be changed — see
> [Appendix: install options](#appendix-install-options).

The verbose, screenshot-driven version lives at
<https://tappaas.org/installation/>. This file is the operator's quick path.

---

## 1. Prerequisites

You are installing **either a single-node system or a 3-node cluster** (you can
add more nodes later). You need:

- **Hardware:** 1 node (single) or 3 nodes (cluster) capable of running Proxmox
  VE 9, each with **two NICs** (one WAN, one LAN). A 3-node cluster also needs a
  **managed switch** that supports VLAN trunking (see [the network section](#network--the-cable-swap-the-only-fiddly-part)).
- **An existing network** (your home/office LAN) with a **free IP** for the first
  node and a working DHCP server + internet. After the firewall is switched in,
  that same network hands the firewall's WAN an address via **DHCP**.
- **A registered domain** with API-accessible DNS (used for automatic TLS
  certificates), and **strong passwords** for Proxmox and the firewall.

That's it. Everything else is created by the install.

---

## 2. Bootstrap: cluster nodes, firewall, CICD mothership

### 2.1 First node + firewall

1. **Install Proxmox VE 9.1** on the first machine — download the ISO and create
   a bootable USB per the official guide:
   <https://pve.proxmox.com/wiki/Installation>. Set hostname `tappaas1` and give
   it the free IP from your existing network (the installer's normal network
   screen). *(Hostnames/subnet are defaults — see appendix.)*

2. **Run the bootstrap** from the Proxmox **node console/shell** (not SSH — the
   network step may move the interface):

   ```bash
   REPO="https://raw.githubusercontent.com/TAPPaaS/TAPPaaS/"; BRANCH="main"
   curl -fsSL ${REPO}${BRANCH}/src/foundation/cluster/install.sh >install.sh
   chmod +x install.sh && ./install.sh "$REPO" "$BRANCH"
   ```

   It does the Proxmox post-install, builds the `lan`/`wan` bridges (you pick
   which NIC is which), creates the `TAPPaaS` cluster, and builds the ZFS pools.
   Because this is the **first** node, it then offers to **install the firewall**
   — say yes. The firewall is a **prebuilt OPNsense image**: it downloads, boots
   at `10.0.0.1`, and self-configures with unique credentials — no GUI, no
   installer.

3. **Swap cables + move your PC** (the only manual networking — see
   [the network section](#network--the-cable-swap-the-only-fiddly-part)). On the node:

   ```bash
   ~/tappaas/config-network.sh --swap-cables   # node now routes via the firewall
   ~/tappaas/sanity-check.sh                    # gateway, DNS, internet must pass
   ```

### 2.2 Additional nodes (3-node only — skip for single-node)

On each extra machine: install Proxmox VE (`tappaas2`, `tappaas3`), then run the
**same bootstrap** (the command in 2.1 step 2). It auto-joins the existing
cluster. *(For VLANs to work across nodes, the switch trunk must be in place
first — see the network section.)*

### 2.3 Build the platform (NixOS template + CICD mothership)

Once all nodes + the firewall are up, on `tappaas1`:

```bash
~/tappaas/install-platform.sh
```

This imports the **prebuilt NixOS VM template** (no manual NixOS install) and
clones it into the **`tappaas-cicd` mothership** VM. It does **not** finish the
mothership for you — `install-platform.sh` prints the cicd's address; SSH in (the
node's root key is already authorized on it) and run the two installers:

```bash
ssh tappaas@tappaas-cicd          # (or the DHCP address the script prints)

BRANCH="main"                     # the branch you're installing from
curl -fsSL "https://raw.githubusercontent.com/TAPPaaS/TAPPaaS/${BRANCH}/src/foundation/tappaas-cicd/install1.sh" -o /tmp/install1.sh
bash /tmp/install1.sh "https://github.com/TAPPaaS/TAPPaaS.git" "$BRANCH"   # clone + nixos-rebuild
sudo reboot                       # install1 asks for this; reconnect afterwards

cd TAPPaaS/src/foundation/tappaas-cicd
./install2.sh --domain "yourdomain.com"   # platform tooling + reverse proxy
```

`install2.sh` runs `ssh-copy-id` to each node, so it will **prompt for each
node's root password** (to set up cicd→node SSH). After this, cicd owns the
platform (VLANs, reverse proxy, firewall rules) and is where you install
everything else. *(The domain is set here, once.)*

---

## 3. Install the rest of the foundation

From here on you work **from the cicd mothership** (`ssh tappaas@tappaas-cicd`).
`install-module.sh` is on the `PATH`, but it reads `./<module>.json` from the
**current directory** — so `cd` into the module's directory first:

```bash
cd ~/TAPPaaS/src/foundation/backup   && install-module.sh backup     #  Proxmox Backup Server
cd ~/TAPPaaS/src/foundation/identity && install-module.sh identity   #  Identity provider
cd ~/TAPPaaS/src/foundation/logging  && install-module.sh logging    #  Loki / Grafana / Promtail
```

*(Module sizing/zones are defaults — see appendix.)*

---

## 4. Add Stacks (apps + community modules)

Functionality beyond the foundation comes from **modules** — first-party ones in
this repo (`src/apps/`) and ones from **community module stores** (other repos).

**1. Add the community module store** (once), with `repository.sh` — it registers
the repo and clones it under `/home/tappaas/`:

```bash
repository.sh add github.com/TAPPaaS/Community --branch main
repository.sh list
```

Its modules are then installable just like the built-in ones.

**2. Install a module.** `cd` into the module's directory (the one holding its
`<module>.json`) and run `install-module.sh`. E.g. add LiteLLM:

```bash
cd ~/TAPPaaS/src/apps/litellm && install-module.sh litellm
# a community module lives under its repo, e.g.:
# cd ~/Community/<contributer>/<module> && install-module.sh <module>
```

That's it — the module is placed on the right VLAN/zone and gets its reverse
proxy + firewall rules registered automatically. Install others the same way
(`nextcloud`, `homeassistant`, `openwebui`, …) to build out your stacks.

---

## Network — the cable swap (the only fiddly part)

The firewall starts as a VM on `tappaas1`, reachable at `10.0.0.1`. The "swap" is
the one-time step that puts it inline as the gateway. Each node has **two NICs**:
`wan` (firewall uplink) and `lan` (VLAN-aware bridge → managed switch).

**BEFORE the swap** — you still reach everything through your existing network;
the firewall VM is up but not yet the gateway:

```
  Existing LAN (your router + DHCP, e.g. 192.168.0.0/24)  ── admin PC
        │
   [tappaas1 WAN NIC]
   ┌──────────────────────────────────────────┐
   │  tappaas1 (Proxmox)                        │
   │    OPNsense VM:  wan → 192.168.0.x (DHCP)  │
   │                  lan → 10.0.0.1            │
   │    node mgmt:    lan → 10.0.0.10           │
   └──[tappaas1 LAN NIC]────────────────────────┘
        │
   [ managed switch ]        (3-node only; single-node: any switch / direct)
```

**AFTER the swap** (`config-network.sh --swap-cables`) — the firewall is the
gateway and everything sits behind it:

```
   ISP / upstream
        │
   [tappaas1 WAN NIC] ───────────────► OPNsense WAN (DHCP from upstream)
   ┌──────────────────────────────────────────┐
   │  tappaas1 (Proxmox)                        │
   │    OPNsense VM:  lan → 10.0.0.1 (gateway)  │
   │    node mgmt:    lan → 10.0.0.10  (wan IP removed)
   └──[tappaas1 LAN NIC]────────────────────────┘
        │
   [ managed switch ] ── admin PC (now gets 10.0.0.x by DHCP)
```

To do it: move the **WAN NIC cable** from your existing LAN to the **upstream/ISP**,
make sure the **LAN NIC** goes to the **managed switch**, run
`~/tappaas/config-network.sh --swap-cables`, then move your admin PC onto the
switch/LAN. The firewall GUI is then at `https://10.0.0.1`.

**The switch (3-node clusters):** the `lan` bridge is **VLAN-aware** — it carries
the **management network untagged** (10.0.0.0/24) plus **every TAPPaaS VLAN
tagged** as a trunk. The managed switch needs a **trunk port to each node** (mgmt
untagged + TAPPaaS VLANs tagged). **Configure those trunk ports *before* adding
nodes** — VMs can't reach each other across nodes on a VLAN until the switch
trunks it. *(Single node: no managed switch needed — all VLANs live inside the
one node; the `lan` NIC can go to your existing LAN or any switch.)*

**Upstream options:** the firewall WAN can sit behind your ISP router
(port-forward), in bridge mode, or replace the ISP router directly.

---

## Appendix: install options

Defaults are chosen so the commands above "just work". Override as needed:

| Default | How to change |
|---|---|
| Branch `stable` | Pass a different branch as the 2nd arg to `install.sh` (e.g. `main`). |
| Hostnames `tappaas1/2/3` | Set during the Proxmox install; the **first** node must be `tappaas1` (it creates the cluster). |
| Management subnet `10.0.0.0/24`, gateway/firewall `10.0.0.1` | `config-network.sh --mgmt-ip <CIDR> --gateway <ip>`; firewall LAN lives in `firewall/firewall-config.xml.template`. |
| Auto cluster create/join | `install.sh --cluster` / `--join` / `--no-cluster`. |
| ZFS pools (`tankXY`, topology) | `config-storage.sh --pool name=topology:disks` (interactive by default). |
| Firewall root password | `config-firewall.sh --root-pw <pw>` (otherwise prompted/generated; the API key is always unique per deploy). |
| VM sizing, storage, network zone per module | edit the module's `<name>.json` (cores, memory, diskSize, storage, zone0/bridge0). |
| Domain / TLS | provided to the `firewall`/app modules; TLS issuance is DNS-01 by default. |
| Unattended runs | most scripts accept `--non-interactive` (supply the values via flags). |

Field definitions for module JSON are in `src/foundation/module-fields.json`;
network zones/VLANs in `src/foundation/firewall/zones.json`.
