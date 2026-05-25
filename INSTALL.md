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
  **managed switch** that supports VLAN trunking (see [the network section](#network--cutting-over-to-the-firewall)).
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
   <https://pve.proxmox.com/wiki/Installation>. On the installer screens:
   - **Hostname (FQDN):** `tappaas1.mgmt.internal` — TAPPaaS uses the internal
     management domain `mgmt.internal`, **not** your public domain. (The public
     domain is supplied later, in 2.3.)
   - **Email:** a **working** address you actually monitor — Proxmox sends
     system/health notifications here, and TAPPaaS reuses it as the admin email.
   - **Management interface / IP / netmask / gateway / DNS:** must be **valid for
     your existing network** — use the free IP, and the real gateway and DNS
     server of the network this node currently sits on (so it has internet for
     the bootstrap).

   *(Hostnames/subnet are defaults — see appendix.)*

2. **Run the bootstrap** from the Proxmox **node console/shell**

Notes:
- Do not usen SSH — the network step may move the interfaceit has not been testet
- It is recomended to use the xterm.js shell option in the tappaas1 menu, this gives some more scroll and percistency on the output from installing

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

3. **Cut over to the firewall** (the only manual networking — see
   [the network section](#network--cutting-over-to-the-firewall)). This does
   **not** move cables: it renumbers the node to `10.0.0.10` and routes it via the
   firewall. Run it on the node, then **move your admin laptop to the downstream
   switch** (you'll reconnect at `10.0.0.10`):

   ```bash
   ~/tappaas/config-network.sh --swap-cables   # renumbers node → 10.0.0.10, gateway → firewall
   ~/tappaas/sanity-check.sh                    # gateway, DNS, internet must pass
   ```

### 2.2 Build the platform (NixOS template + CICD mothership)

Build the mothership on **`tappaas1` alone** — a single node is fine; you add the
other nodes next (§2.3), and HA is simply skipped until they exist. Run **one
command**:

```bash
~/tappaas/install-platform.sh --domain "yourdomain.com"
```

This is fully automated end-to-end:

1. Imports the **prebuilt NixOS VM template** (no manual NixOS install) and
   finalises it into a Proxmox template.
2. Clones it into the **`tappaas-cicd` mothership** VM.
3. SSHes into the mothership (the node's root key is already authorized on it)
   and runs the two installers itself — `install1.sh` (clone + `nixos-rebuild`),
   **reboots** the VM, then `install2.sh` (platform tooling + reverse proxy) —
   including wiring up cicd→node SSH **with no password prompts** (the node
   pre-authorizes cicd's key on every node).

After it finishes, cicd owns the platform (VLANs, reverse proxy, firewall rules)
and is where you install everything else.

> **Domain:** pass `--domain` to set the public TLS domain once. (It can't be
> auto-detected — the Proxmox FQDN is the internal `mgmt.internal` domain; the
> admin **email** *is* read from the node automatically.) If you omit it, a
> placeholder is used that you set later with
> `create-configuration.sh --update --domain <yourdomain>`.
>
> Use a non-`main` branch with `--branch <name>`, or `--manual-cicd` to perform
> the in-VM `install1`/`install2` steps by hand instead — see
> [Appendix: install options](#appendix-install-options).

### 2.3 Add additional nodes (3-node only — skip for single-node)

**Do this *after* the mothership is installed (§2.2), not before.**

1. **Reboot `tappaas1` first.** The cable-swap renumbered it to `10.0.0.10` and
   rewrote the cluster (corosync) config; a reboot is required for the cluster to
   load the new config — **a second node cannot join until `tappaas1` has been
   rebooted**:

   ```bash
   reboot          # on tappaas1; reconnect at 10.0.0.10 afterwards
   ```

2. On each extra machine: install Proxmox VE (`tappaas2`, `tappaas3`) and run the
   **same bootstrap** (the command in 2.1 step 2). It auto-joins the existing
   cluster. *(For VLANs to work across nodes, the managed-switch trunk must be in
   place first — see [the network section](#network--cutting-over-to-the-firewall).)*

3. Back on the mothership, run an update so cicd reconciles the new topology:
   `update-tappaas` (or `update-module tappaas-cicd`) — it now configures **HA +
   replication automatically** across the nodes.

### 2.4 Set up TLS certificates

**Configure the Caddy DNS-01 provider credentials** (e.g. your **Cloudflare API
token**) so public TLS certificates can be issued for your domain. Until this is
set, internal-only services still work (reachable on the LAN), but their public
HTTPS endpoint has no certificate.

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

## Network — cutting over to the firewall

This is the one-time step that puts the firewall (a VM on `tappaas1`, at
`10.0.0.1`) inline as the gateway. **Despite the command name `--swap-cables`,
you normally don't move any cables** — the cutover is a *logical* IP change plus
moving your admin laptop. Each node has **two NICs**: `wan` (the firewall's
upstream/internet uplink) and `lan` (a VLAN-aware bridge → the downstream managed
switch). You wire both at install time and they stay put.

What actually changes:

- **The node's IP** — `config-network.sh --swap-cables` renumbers `tappaas1` from
  its install address to **`10.0.0.10`** and points its default gateway + DNS at
  the firewall (`10.0.0.1`). No cable is touched.
- **Your admin laptop** — move it onto the **downstream switch** (the firewall's
  LAN side), where it gets a `10.0.0.x` lease from the firewall.

```
   internet / upstream router
        │
   [tappaas1 WAN NIC] ─────────────► OPNsense WAN  (DHCP from upstream)
   ┌───────────────────────────────────────────────┐
   │  tappaas1 (Proxmox)                             │
   │    OPNsense VM:   lan → 10.0.0.1  (the gateway) │
   │    node mgmt:     lan → 10.0.0.10               │   ← renumbered by --swap-cables
   └──[tappaas1 LAN NIC]──────────────────────────────┘
        │
   [ downstream managed switch ] ── admin laptop  (now 10.0.0.x by DHCP)
```

So the procedure is: make sure the **WAN NIC** reaches your upstream/internet and
the **LAN NIC** reaches the **downstream switch** (you cabled both at install —
nothing to move now), run `~/tappaas/config-network.sh --swap-cables` on the
node, then **move your admin laptop to the downstream switch**. The firewall GUI
is then at `https://10.0.0.1`. *(The `--swap-cables` flag name is historical; it
renumbers IPs, it does not move cables.)*

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
| Platform install branch / domain | `install-platform.sh --branch <name> --domain <domain>`. |
| Automated vs. manual cicd install | `install-platform.sh` automates the in-VM install over SSH; pass `--manual-cicd` to run `install1.sh`/`install2.sh` by hand inside the VM instead. |
| ZFS pools (`tankXY`, topology) | `config-storage.sh --pool name=topology:disks` (interactive by default). |
| Firewall root password | `config-firewall.sh --root-pw <pw>` (otherwise prompted/generated; the API key is always unique per deploy). |
| VM sizing, storage, network zone per module | edit the module's `<name>.json` (cores, memory, diskSize, storage, zone0/bridge0). |
| Domain / TLS | provided to the `firewall`/app modules; TLS issuance is DNS-01 by default. |
| Unattended runs | most scripts accept `--non-interactive` (supply the values via flags). |

Field definitions for module JSON are in `src/foundation/module-fields.json`;
network zones/VLANs in `src/foundation/firewall/zones.json`.
