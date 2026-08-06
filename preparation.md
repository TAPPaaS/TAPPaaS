
# Preparation

Consider these preparation steps **before** you run the [install](src/foundation/INSTALL.md). 

## 0. Hardware

This is is the previous step — [Hardware Selection](hardware-selection.md). 

## 1. Network

- [ ] An **existing network** (your home/office LAN) with working **DHCP and
  internet** — the install of the first node runs on it, After the first node is installed then this is considered the WAN (unprotected) side of TAPPaaS and the rest of the TAPPaaS ndes are installed on the TAPPaaS LAN. 
  - Note that the existing network can not use the 10.0.0.0/8 IP domain as it conflict with the TAPPaaS own LAN.
  - Also note that after the TAPPaaS fpoundation have been installed, then you can move the TAPPaaS WAN to connect directly to a DHCP providing Internet connection (thus replacing an existing home/office LAN)  
- [ ] At least the First TAPPaaS node must be wired with  **two NICs**: one towards the upstream router (WAN), one towards your downstream switch (LAN). 
  - If you install more than a single TAPPaaS node then you need a switch between the nodes. 
- [ ] Drive the install from a client (PC/Mackbook runnning a webserver and preferably also ssh) that is connected to the office/home LAN

## 2. Domain

- [ ] A **registered domain** with **API-accessible DNS**. Not a hard requirement —
  you can configure a domain in TAPPaaS you haven't registered yet 
- [ ] Preferably the Domain name is managed by an organisaiton that allow **API token** (used for ACME DNS-01; ~120 providers
  supported — Cloudflare, deSEC, Hetzner, OVH, Route 53, …). For Cloudflare: a custom token with `Zone → Zone → Read` and `Zone → DNS → Edit`, restricted to your domain. You'll enter it after bootstrap, not before.

## 3. Credentials and contact

- [ ] A **strong password** for Proxmox and the firewall — you'll be asked for it
  several times during install.
- [ ] A **working email address you actually monitor** — Proxmox sends system and health notifications there. 
TAPPaaS reuses it as the admin email.

## 4. Branch selection

The bootstrap command takes a branch (`BRANCH="..."` in the
[install guide](src/foundation/INSTALL.md)) — decide it now:

| Branch | What it is | Who should install it |
|--------|------------|-----------------------|
| **`stable`** | The released, supported version of TAPPaaS | Everyone running a production system |
| **`main`** | Ongoing development — moves fast, may break | Contributors, and evaluators who want the newest work |

**If in doubt, choose `stable`.** `stable` only moves when a release is cut and tested or if there are tested bug fixes released; `main` moves with every merged change. 
A TAPPaaS system tracks updates to its branch through
the automated updates — the choice you make here is the risk profile you keep.


## 5. Solution naming

Three inputs define your installation — pick them now:

- [ ] **Site code** (`--name`): lowercase, ≤15 characters. A neutral code (e.g.
  `warmelo1` — place plus number) that becomes the Proxmox **cluster name** and
  `site.json .name`. It is set once at cluster creation and is not reused to name
  anything else (#426).
- [ ] **Organisation name** (`--organization`): lowercase (hyphens allowed). Names
  your default **environment**, its network **zone**, and your default
  **organisation** in the identity provider. Defaults to the site code if omitted.
  Decoupled from the site code so it can differ and so a site can host several
  organisations.
- [ ] **Public domain** (`--domain`): As default services are published as
  `<service>.yourdomain.com` by the reverse proxy (the domain from point 2).

**Done when** every box above is ticked — then proceed to
[Install Foundation](src/foundation/INSTALL.md).
