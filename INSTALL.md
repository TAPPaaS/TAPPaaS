# Installing TAPPaaS

The install turns one or more machines into a TAPPaaS site. Each machine gets Proxmox VE, and
the first one gets the TAPPaaS foundation on top: an OPNsense firewall that becomes the site's
gateway, the management VM that owns the platform (tappaas-cicd), and its web console. From the
console's Day 1 page you finish the rest: the machines' network ports and disks, more machines,
your admin VPN, then sign-in, logging and backup, and a check that it all works. Applications,
going public, switches and Wi-Fi come after, as Day 2 operations. A first machine starts from a
Mac or Linux PC with one script that builds the installer, boots the machine from it and follows
the install to the end.

## Choose how to install

| Option | For | Status |
|--------|-----|--------|
| [A small test TAPPaaS on one node, locally](#a-small-test-tappaas-on-one-node-locally) | Trying TAPPaaS on one machine at home or in the office | Ready |
| [A small test TAPPaaS on Hetzner](#a-small-test-tappaas-on-hetzner) | Trying TAPPaaS on one rented server | In development, not ready |
| [A production cluster, locally](#a-production-cluster-locally) | Running your home, family or business on several machines you own | Ready |
| [A production cluster in the Hetzner cloud](#a-production-cluster-in-the-hetzner-cloud) | Running it on rented servers | In development, not ready |

Either test install can grow: more machines, disks and switches are added from the console
later.

---

## A small test TAPPaaS on one node, locally

One machine (32 GB of memory, one 0.5 TB disk, one network port) on your own network, installed
from a Mac or Linux PC beside it, with a USB stick or over the network. No hardware planning and
no preparation checklist: the install asks for your email, a root password and the site's name,
and the console's Day 1 page takes you to a working system.

**Start here:** [Install TAPPaaS on a single machine](INSTALL-SINGLENODE.md).

## A small test TAPPaaS on Hetzner

*In development, not ready.* One rented dedicated server with a public address: no USB stick and
no local network beside it. The installer will reach the server through its rescue system or
remote console, the firewall will take the public address, and you will reach the console through an ssh tunnel
until your admin VPN is set up. Until it is ready, use a local machine.

## A production cluster, locally

Several machines you own, sized for what you will run, with managed switches, separate data
disks and backup. It follows seven stages; each says what it needs and what "done" looks like
before you move on.


| # | Stage | You'll need | Done when |
|---|-------|-------------|-----------|
| 1 | [Hardware Selection](hardware-selection.md) | An honest look at your needs | Hardware sized by tier + options, on the bench |
| 2 | [Preparation](preparation.md) | Network, domain, credentials, branch | The preparation checklist is all ticked |
| 3 | [Install Foundation](src/foundation/INSTALL.md) | Stages 1 + 2 complete | Foundation installed on all nodes; network cut over; you can log in everywhere |
| 4 | [Configure Environments](INSTALL-ENVIRONMENT.md) *(optional)* | A running foundation | Each tenant/purpose has its own separated environment |
| 5 | [Add a Satellite](src/foundation/satellite/INSTALL.md) *(optional)* | A VPS, if you planned one | The satellite carries its roles (ingress / backup / VPN) |
| 6 | [Add Workloads](#stage-6--add-workloads) | A running foundation | The apps you chose are installed and reachable |
| 7 | [Operate](https://tappaas.org/operate/) | — | Updates, backup and health checks running on schedule |

---

### Stage 1 — Hardware Selection

Pick a **size tier** (Evaluation / Home / SMB / Scale-out), then toggle three **capability
options** — local AI, local backup, local public IP — independently. The
[hardware selection guide](hardware-selection.md) walks the decision in four steps and gives
per-tier sizing tables.

**Done when:** you know your tier, your options, and the machine(s) are in hand.

### Stage 2 — Preparation

One concise checklist: network facts, domain + DNS API token, credentials, admin email — and the
**branch** your system will track (`stable` vs `main`). See [Preparation](preparation.md).

**Done when:** every box in [Preparation](preparation.md) is ticked.

### Stage 3 — Install Foundation

The automated foundation install: the first Proxmox node plus one command chain that brings up the
OPNsense firewall, the **network cut-over** (additive — the firewall becomes your gateway without
dropping your session or moving cables) and the CICD mothership; additional nodes joining unattended;
**DNS/TLS** setup (wildcard certificates via your DNS provider's API); and the remaining foundation
modules (backup, identity, logging) with your organisation bootstrapped in the identity provider.

The authoritative, always-current procedure is **[Install Foundation](src/foundation/INSTALL.md)** —
follow its steps top to bottom.

At install you say how big the site is: **small** (a few users, one machine or a test system),
**medium** (the default, up to about 50 users) or **large** (100+ users on three or more large
machines). Every module is then installed with cores, memory and disk to match; environments can
have a size of their own (stage 4).

**Done when:** the install prints its "🎉 your TAPPaaS foundation is installed" summary, and you can
reach the Proxmox UI, the firewall UI and the CICD mothership.

#### Compare the release signer

TAPPaaS releases on the `stable` and `staging` branches are tags signed by the TAPPaaS owners. The
install checks that the release it clones is signed by one of the keys below, and records those
fingerprints in `site.json`; from then on every update must be signed by a key the release the site
last verified lists. The fingerprints below are the one thing you take on trust, so compare them with what the
install prints:

```
TAPPaaS v2.4: signed by SHA256:… — compare it with the fingerprint in INSTALL.md
```

| Owner | Release key fingerprint |
|-------|-------------------------|
| Lars Rossen | *not published yet — the release keys are being enrolled* |
| Erik Daniel | *not published yet — the release keys are being enrolled* |

Check the same fingerprints on [tappaas.org](https://tappaas.org) and in the release notes; if they
differ anywhere, stop and ask before installing. What the site checks from then on, and how to
read it: [Verified updates](src/foundation/tappaas-cicd/VERIFIED-UPDATES.md). Until the keys are published TAPPaaS releases are
unsigned and the install says so (`TAPPaaS signs no releases yet`). The `main` branch is never
signed.

### Stage 4 — Configure Environments *(optional)*

Run more than one world on the same platform: production next to family, tenants next to
experiments — separated environments with network boundaries between them. See
[Configure Environments](INSTALL-ENVIRONMENT.md).

**Done when:** each environment exists with its own zones and domain.

### Stage 5 — Add a Satellite *(optional)*

If you planned a **satellite** in stage 1 (public ingress without a public IP, off-site backup,
admin VPN — see the [hardware guide](hardware-selection.md#the-satellite--the-gap-filler)), enrol the
VPS now via [the satellite install](src/foundation/satellite/INSTALL.md).

**Done when:** the satellite carries its roles.

### Stage 6 — Add Workloads

Install the workloads you chose in stage 1. First-party modules install with
`module-manager module add <module>`; community module stores register once with
`site-manager repository add <repo> --branch <branch>`, after which their modules install the same way.
On a `stable` or `staging` branch, a repository that signs its releases is added with the
fingerprints of its owners' signing keys, from them — `--signer SHA256:<fingerprint>`, once per key —
and one that signs nothing with `--unsigned`.

| Stack | What you get |
|-------|--------------|
| [AI stack](src/ai/INSTALL.md) | Local AI: vLLM serving, LiteLLM gateway, OpenWebUI |
| [Collaboration stack](src/collaboration/INSTALL.md) | Nextcloud with EURO Office editing and Talk calls (coturn, HPB) |
| [Home stack](src/home/INSTALL.md) | Home Assistant and the deCONZ Zigbee gateway |
| [Security stack](src/security/INSTALL.md) | Vaultwarden password vault, NetBird client |
| [Miscellaneous](src/misc/INSTALL.md) | Modules without a stack yet: Windows Server |

Each stack's INSTALL.md lists its modules in install order, with the notes for that stack; each
module's INSTALL.md says what to do by hand. What a stack is: its README.md.

**Done when:** each installed app answers on its URL and is known to the
[Module Manager](src/foundation/tappaas-cicd/manager/module-manager/README.md).

### Stage 7 — Operate

Hand over to day-to-day operation: the managers keep updating, backing up and health-checking the
platform. That is [Operate](https://tappaas.org/operate/) — bookmark it.

## A production cluster in the Hetzner cloud

*In development, not ready.* Several rented dedicated servers joined into one cluster. The
first server's public address becomes the firewall's internet side. The servers reach each
other over Hetzner's private network between them (the vSwitch). That network carries a single
VLAN, so the site's own networks (management, services, clients and so on) will run tunnelled
inside it rather than as VLANs on a switch you own. Until it is ready, use a local cluster.
