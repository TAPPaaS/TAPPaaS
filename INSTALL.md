# Installing TAPPaaS

This is the short install guide. It reflects the **automated** install with mostly default values.

Note this is a major upgrade from the version 1.0 of TAPPaaS stable:
The firewall and the NixOS VM template are now prebuilt images that download and
boot preconfigured, and the bootstrap scripts chain together — so most steps are
"run one command and watch".

> Defaults (subnet, hostnames, sizing, passwords, branch, …) work out of the box.
> Anywhere a default is mentioned, it can be changed — see
> [Appendix: install options](#appendix-install-options).

---

## 1. Prerequisites

You are installing **either a single-node system or a cluster** (you can add
nodes later, **up to 9** — `tappaas1`…`tappaas9`, which the firewall reserves
`10.0.0.10`–`10.0.0.18` and DNS names for). You need:

- **Hardware:** 1 node (or 3) capable of running Proxmox VE 9, each with **two
  NICs** (one WAN, one LAN). A 3-node cluster also needs a switch between the
  nodes — an **unmanaged switch** works out of the box, or a **managed switch**
  if you configure VLAN trunking (see [the network section](#network--cutting-over-to-the-firewall)).
- **An existing network** (your home/office LAN) with a **free IP** for the first
  node and a working DHCP server + internet. After the firewall is switched in,
  that same network hands the firewall's WAN an address via **DHCP**.
- **A registered domain** with API-accessible DNS (used for automatic TLS
  certificates): this is not a hard requirement, but useful for TAPPaaS to expose
  services — you can also configure TAPPaaS with a domain you have not yet registered.
- A **strong password** for Proxmox and the firewall. You will be asked for it
  several times during install.

That's it. Everything else is created by the install.

---

## 2. Bootstrap: cluster nodes, firewall, CICD mothership

### 2.1 First node + firewall

1. **Install Proxmox VE 9.1** on the first machine — download the ISO and create
   a bootable USB per the official guide:
   <https://pve.proxmox.com/wiki/Installation>. Note TAPPaaS does not support PVE 9.2 yet.
   
    On the installer screens:
   - **Network Nic** select the one you have connected to the upstream router. Initially this is the Lan port but it will eventually become the "wan" port of the TAPPaaS firewall. For secondary TAPPaaS nodes this is will stay lan port, as these nodes wil connect directly via the switch to the lan side of the firewall we create in the first node.
   - **Hostname (FQDN):** `tappaas1.mgmt.internal` — TAPPaaS uses the internal
     management domain `mgmt.internal`, **not** your public domain. (Your public
     domain is supplied with `--domain` in step 2.)
   - **Email:** a **working** address you actually monitor — Proxmox sends
     system/health notifications here, and TAPPaaS reuses it as the admin email.
   - **Management interface / IP / netmask / gateway / DNS:** must be **valid for
     your existing network** — use a free IP (the proxmox installer is not using DHCP), and the real gateway and DNS
     server of the network this node currently sits on (so it has internet for
     the bootstrap).

2. **Run the one-shot bootstrap** from the Proxmox **node console/shell**.

   Notes:
   - Do not use SSH — the network setup steps may move its interface and it has not been tested over SSH.
   - Use the **xterm.js** shell option in the tappaas1 menu; it gives more scrollback and persistence on the install output.
   - **⚠ Run from a client that is NOT on `10.0.0.0/24`.** The cutover puts the
     management network (`10.0.0.0/24`) on the node, so a browser/SSH client that
     sits in that subnet loses its return path to the node and freezes. Drive the
     install from a client on your **install/upstream network**, or from a true
     **out-of-band console** (IPMI/iKVM) — not from a `10.0.0.x` laptop. (The node
     keeps its install IP throughout, so such a client never loses it.)

   ```bash
   REPO="https://raw.githubusercontent.com/TAPPaaS/TAPPaaS/"; BRANCH="main"
   curl -fsSL ${REPO}${BRANCH}/src/foundation/cluster/install.sh >install.sh
   chmod +x install.sh && ./install.sh "$REPO" "$BRANCH" --domain "yourdomain.com"
   ```

   Pass your **public domain** with `--domain` — the platform's reverse proxy is
   configured for `<service>.yourdomain.com`, so it's needed up front (if you omit
   it you'll be prompted). You don't need the domain's DNS-01 API token yet — that
   comes in §2.3.

   On the **first node** this runs the whole foundation bring-up **end-to-end** —
   you run it once and watch:

   1. **Node** — Proxmox post-install, the `lan`/`wan` bridges (auto-detected: the
      install NIC, the one with internet, becomes **WAN**; the other, to your
      downstream switch, becomes **LAN**), the `TAPPaaS` cluster, and the ZFS pools.
   2. **Firewall** — downloads and boots the **prebuilt OPNsense image** at
      `10.0.0.1`, self-configured with unique credentials (no GUI, no installer).
   3. **Gateway cutover** — adds this node's management IP `10.0.0.10` and points
      its default route + DNS at the firewall. This is **additive and
      non-disruptive**: the upstream IP is *kept*, **no cables move**, and your
      current session is **not** dropped.
   4. **Sanity check** — gateway, DNS, internet.
   5. **Platform** — imports the prebuilt **NixOS template** and builds the
      **`tappaas-cicd` mothership** (clone → `install1` → reboot → `install2`),
      which then owns VLANs, the reverse proxy and firewall rules.

   The domain you passed is used to configure the reverse proxy. To stop earlier,
   pass `--skip-firewall` or `--skip-platform`; to drive the in-VM cicd install by
   hand, see [Appendix: install options](#appendix-install-options).

   When it finishes, `tappaas1` is at `10.0.0.10` behind the firewall and
   `tappaas-cicd` owns the platform. Optionally move your admin laptop onto the
   **downstream switch** (you'll get a `10.0.0.x` lease; Proxmox at
   `https://10.0.0.10:8006`, firewall GUI at `https://10.0.0.1`) — not required,
   since the node also keeps its upstream IP until you harden it later.

### 2.2 Add additional nodes (3-node only — skip for single-node)

Do this **after** the first node's bootstrap has finished (cicd is up).

1. Install Proxmox VE on each extra machine (`tappaas2`, `tappaas3`). At the
   installer's network screen pick the NIC connected to the **downstream switch**
   (the `10.0.0.0/24` LAN) and give it that node's mgmt IP (`10.0.0.11`,
   `10.0.0.12`) with gateway `10.0.0.1` — the node comes up directly on the
   management network. *(If the inter-node switch is **managed**, configure its
   VLAN trunks first — an **unmanaged** switch needs no setup; see
   [the network section](#network--cutting-over-to-the-firewall).)*

2. Run the **same bootstrap** (the command in 2.1 step 2) on each. It detects it's
   a secondary node (already on the mgmt net), assigns the install NIC as **LAN**
   and **asks which NIC is WAN** (wire it to your upstream if this node will host
   firewall HA), then **auto-joins** the cluster. *(No `tappaas1` reboot is needed —
   corosync was bound to the `10.0.0.10` mgmt IP from the start.)*

3. Back on the mothership, run `update-tappaas` so cicd reconciles the new
   topology — it then configures **HA + replication automatically** across nodes.

### 2.3 Set up TLS certificates

Your domain is already configured (you passed `--domain` in §2.1). To get **public
TLS certificates**, configure the Caddy **DNS-01 provider credentials** on the
mothership — e.g. your **Cloudflare / DNS-provider API token** for ACME DNS-01:

```bash
ssh tappaas@tappaas-cicd      # or its 10.0.0.x address
# configure the DNS-01 token (provider-specific) so Caddy can issue certs
```

Until this is set, internal-only services still work (reachable on the LAN), but
their public HTTPS endpoint has no certificate. *(Optional if you only use TAPPaaS
internally. To change the domain later: `create-configuration.sh --update --domain
<yourdomain>`.)*

---

## 3. Install the rest of the foundation

From here on you work **from the cicd mothership** (`ssh tappaas@tappaas-cicd`).
One command installs the remaining foundation modules (backup, identity,
logging), runs a final system update + tests, and prints a summary:

```bash
rest-of-foundation.sh
```

It's idempotent — safe to re-run if a module needs attention. When it finishes
you'll see a **"🎉 your TAPPaaS foundation is installed"** summary (nodes,
firewall, mothership, domain/TLS, modules).

> Prefer to do it by hand? `install-module.sh` is on the `PATH` but reads
> `./<module>.json` from the current directory, so `cd` in first:
> ```bash
> cd ~/TAPPaaS/src/foundation/backup   && install-module.sh backup     #  Proxmox Backup Server
> cd ~/TAPPaaS/src/foundation/identity && install-module.sh identity   #  Identity provider
> cd ~/TAPPaaS/src/foundation/logging  && install-module.sh logging    #  Loki / Grafana / Promtail
> ```
> *(Module sizing/zones are defaults — see appendix.)*

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

Putting the firewall (a VM on `tappaas1`, at `10.0.0.1`) inline as the gateway is
done **for you** by the bootstrap (§2.1 step 2.3) — `config-network.sh
--swap-gateway`. You normally never run it by hand; this section explains what it
does. Each node has **two NICs**, wired at install time and left in place:

- **WAN** — the NIC connected to your upstream router (the one with internet at
  install time). It's the firewall VM's uplink. On the first node the node *also*
  keeps its original install IP here.
- **LAN** — the NIC connected to your **downstream switch** (the `10.0.0.0/24`
  management LAN). VLAN-aware bridge; holds the node's mgmt IP `10.0.0.10`.

**The cutover is additive — nothing is removed, nothing is unplugged:**

- `--swap-gateway` makes sure `10.0.0.10` is on the **LAN** side, points the
  node's **default route + DNS** at the firewall (`10.0.0.1`), and restarts
  corosync so it binds to the mgmt IP. The **upstream IP is kept**, so the node
  (and your existing session) never lose connectivity.
- Because both IPs remain, you can keep managing the node where you are, **or**
  move your admin laptop onto the **downstream switch** (you'll get a `10.0.0.x`
  lease; firewall GUI at `https://10.0.0.1`). Moving is optional until you harden.

```
   internet / upstream router
        │
   [tappaas1 WAN NIC] ─────────────► OPNsense WAN  (DHCP from upstream)
   │                                 node also keeps its install IP here
   ┌───────────────────────────────────────────────┐
   │  tappaas1 (Proxmox)                             │
   │    OPNsense VM:   lan → 10.0.0.1  (the gateway) │
   │    node mgmt:     lan → 10.0.0.10               │   ← default route now via 10.0.0.1
   └──[tappaas1 LAN NIC]──────────────────────────────┘
        │
   [ downstream switch ] ── admin laptop  (optional; 10.0.0.x by DHCP)
```

**Later hardening:** once you're managing via the mgmt net (or netbird), run
`config-network.sh --drop-upstream` on a node to remove its upstream IP, so
Proxmox is reachable only behind the firewall.

**The switch (3-node clusters):** the `lan` bridge is **VLAN-aware** — it carries
the **management network untagged** (10.0.0.0/24) plus **every TAPPaaS VLAN
tagged** as a trunk. For VMs on different nodes to reach each other on a VLAN, the
switch between the nodes must pass those **tagged** frames. How that works depends
on the switch type:

- **Unmanaged switch** — passes *all* frames transparently, tagged or untagged, so
  the TAPPaaS VLANs cross between nodes **out of the box, with no configuration**.
  This is the simplest choice for a 3-node cluster.
- **Managed switch** — by default forwards only **untagged** traffic; it drops or
  ignores VLAN-tagged frames until you **configure (manage) it**. You must set the
  inter-node ports as **trunks** carrying the TAPPaaS VLAN tags (plus the untagged
  management network) **before adding nodes** — otherwise cross-node VLAN traffic
  won't pass even though everything else looks fine.

*(Single node: no switch needed for VLANs — all VLANs live inside the one node;
the `lan` NIC can go to your existing LAN or any switch.)*

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
| Chained first-node install (firewall→cutover→platform) | On by default; stop earlier with `install.sh --skip-firewall` or `--skip-platform`. |
| Gateway cutover (route via firewall) | Done automatically by the bootstrap; manual: `config-network.sh --swap-gateway` (additive — keeps the upstream IP). |
| Take Proxmox off the upstream net (hardening) | `config-network.sh --drop-upstream` (run later, once you manage via the mgmt net / netbird). |
| Platform install branch / domain | `install-platform.sh --branch <name> --domain <domain>`. |
| Automated vs. manual cicd install | `install-platform.sh` automates the in-VM install over SSH; pass `--manual-cicd` to run `install1.sh`/`install2.sh` by hand inside the VM instead. |
| ZFS pools (`tankXY`, topology) | `config-storage.sh --pool name=topology:disks` (interactive by default). |
| Firewall root password | `config-firewall.sh --root-pw <pw>` (otherwise prompted/generated; the API key is always unique per deploy). |
| VM sizing, storage, network zone per module | edit the module's `<name>.json` (cores, memory, diskSize, storage, zone0/bridge0). |
| Domain / TLS | provided to the `firewall`/app modules; TLS issuance is DNS-01 by default. |
| Unattended runs | most scripts accept `--non-interactive` (supply the values via flags). |

Field definitions for module JSON are in `src/foundation/module-fields.json`;
network zones/VLANs in `src/foundation/firewall/zones.json`.
