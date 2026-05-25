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
  **managed switch** that supports VLAN trunking (see [the network section](#network--the-switch-the-only-fiddly-part)).
- **An existing network** (your home/office LAN) with a **free IP** for the first
  node and a working DHCP server + internet. After the firewall is switched in,
  that same network hands the firewall's WAN an address via **DHCP**.
- **A registered domain** with API-accessible DNS (used for automatic TLS
  certificates), and **strong passwords** for Proxmox and the firewall.

That's it. Everything else is created by the install.

---

## 2. Bootstrap: cluster nodes, firewall, CICD mothership

### 2.1 First node + firewall

1. **Install Proxmox VE 9.1** on the first machine. Set hostname `tappaas1` and
   give it the free IP from your existing network (the installer's normal
   network screen). *(Hostnames/subnet are defaults — see appendix.)*

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
   [the network section](#network--the-switch-the-only-fiddly-part)). On the node:

   ```bash
   ~/tappaas/config-network.sh --swap-cables   # node now routes via the firewall
   ~/tappaas/sanity-check.sh                    # gateway, DNS, internet must pass
   ```

### 2.2 Additional nodes (3-node only — skip for single-node)

On each extra machine: install Proxmox VE (`tappaas2`, `tappaas3`), then run the
**same bootstrap** (step 2.2). It auto-joins the existing cluster.
*(For VLANs to work across nodes, the switch trunk must be in place first — see
the network section.)*

### 2.3 Build the platform (NixOS template + CICD mothership)

Once all nodes + the firewall are up, on `tappaas1`:

```bash
~/tappaas/install-platform.sh
```

This imports the **prebuilt NixOS VM template** (no manual NixOS install) and
clones it into the **`tappaas-cicd` mothership** — the VM that drives the rest of
TAPPaaS (VLANs, reverse proxy, firewall rules, module installs).

---

## 3. Install the rest of the foundation

From here on you work **from the cicd mothership** (`ssh tappaas@tappaas-cicd`).
cicd installs and updates modules with `install-module.sh` / `update-module.sh`,
and keeps everything patched on a schedule.

```bash
install-module.sh backup      #  Proxmox Backup Server
install-module.sh identity    #  Identity provider
install-module.sh logging     #  Loki / Grafana / Promtail
```

Dependencies (`dependsOn`) are resolved automatically, so order is forgiving.
Provide your **domain** when prompted (used for TLS). *(Module sizing/zones are
defaults — see appendix.)*

---

## 4. Add Stacks (apps + community modules)

Everything beyond the foundation is a **module** installed from cicd the same
way. Group them into stacks as you like:

```bash
install-module.sh nextcloud        # productivity
install-module.sh homeassistant    # home
install-module.sh openwebui        # AI
```

- Foundation modules live in `src/foundation/`; first-party apps in `src/apps/`.
- **Community module store:** add the community repo to cicd's
  `configuration.json` (`tappaas.repositories`), then `install-module.sh <name>`
  installs it like any other.

Each module places its services on the right VLAN/zone and registers its reverse
proxy + firewall rules automatically.

---

## Network — the switch (the only fiddly part)

```
            ISP / upstream
                  │
            [ WAN NIC ]                         (each node: 2 NICs)
   ┌──────────────┴───────────────┐
   │  tappaas1 (Proxmox)           │   wan bridge → OPNsense WAN (DHCP from your
   │   ┌─────────┐  ┌─────────┐    │                existing network after swap)
   │   │ OPNsense│  │  guests │    │   lan bridge → OPNsense LAN = 10.0.0.1
   │   └────┬────┘  └────┬────┘    │                node mgmt IP = 10.0.0.x
   └────────┴────────────┴─────────┘
            [ LAN NIC ]  ── VLAN trunk ──┐
                  │                       │
            ┌─────┴───────────────────────┴─────┐
            │        Managed switch              │
            │  • mgmt VLAN untagged              │
            │  • TAPPaaS VLANs tagged (trunk)    │
            │  • trunk port to EACH node         │
            └────────────────────────────────────┘
```

- The node's **`lan` bridge is VLAN-aware**: it carries the **management network
  untagged** (10.0.0.0/24) plus **every TAPPaaS VLAN tagged** as a trunk to the
  switch. The **`wan` bridge** is the firewall's uplink.
- **Single node:** no switch needed — the `lan` NIC can go to a plain switch or
  your existing LAN; all VLANs live inside the one node.
- **3-node:** the managed switch must have a **trunk port to each node** carrying
  the mgmt VLAN (untagged) + the TAPPaaS VLANs (tagged). **Configure these trunk
  ports *before* adding nodes** — VMs can't reach each other across nodes on a
  VLAN until the switch trunks it.
- **Cable swap (once, after the firewall is up):** the firewall starts as a VM on
  `tappaas1` reachable at `10.0.0.1`. Put it inline — **WAN NIC → your upstream**,
  **LAN NIC → the managed switch** — then run `config-network.sh --swap-cables`,
  which drops the node's old WAN IP and routes it through the firewall. Move your
  admin PC onto the LAN/switch; it gets a `10.0.0.x` DHCP lease, and the firewall
  GUI is at `https://10.0.0.1`.
- **Upstream options:** firewall WAN can sit behind your ISP router (port-forward),
  in bridge mode, or replace the ISP router directly.

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
