# Installing TAPPaaS

TAPPaaS installs as a set of interlinked foundation modules and platform services, built and
configured to work together. The process is **seven stages**; each one tells you what it needs and
what "done" looks like before you move on.

## The seven stages

| # | Stage | You'll need | Done when |
|---|-------|-------------|-----------|
| 1 | [Hardware Selection](hardware-selection.md) | An honest look at your needs | Hardware sized by tier + options, on the bench |
| 2 | [Preparation](preparation.md) | Network, domain, credentials, branch | The preparation checklist is all ticked |
| 3 | [Install Foundation](src/foundation/INSTALL.md) | Stages 1 + 2 complete | Foundation installed on all nodes; network cut over; you can log in everywhere |
| 4 | [Add an Environment](INSTALL-ENVIRONMENT.md) *(optional)* | A running foundation | Each tenant/purpose has its own separated environment |
| 5 | [Add a Satellite](src/foundation/satellite/INSTALL.md) *(optional)* | A VPS, if you planned one | The satellite carries its roles (ingress / backup / VPN) |
| 6 | [Add Stacks](#stage-6-add-stacks) | A running foundation | The apps you chose are installed and reachable |
| 7 | [Operate](https://tappaas.org/operate/) | — | Updates, backup and health checks running on schedule |

---

## Stage 1 — Hardware Selection

Pick a **size tier** (Evaluation / Home / SMB / Scale-out), then toggle three **capability
options** — local AI, local backup, local public IP — independently. The
[hardware selection guide](hardware-selection.md) walks the decision in four steps and gives
per-tier sizing tables.

**Done when:** you know your tier, your options, and the machine(s) are in hand.

## Stage 2 — Preparation

One concise checklist: network facts, domain + DNS API token, credentials, admin email — and the
**branch** your system will track (`stable` vs `main`). See [Preparation](preparation.md).

**Done when:** every box in [Preparation](preparation.md) is ticked.

## Stage 3 — Install Foundation

The automated foundation install: the first Proxmox node plus one command chain that brings up the
OPNsense firewall, the **network cut-over** (additive — the firewall becomes your gateway without
dropping your session or moving cables) and the CICD mothership; additional nodes joining unattended;
**DNS/TLS** setup (wildcard certificates via your DNS provider's API); and the remaining foundation
modules (backup, identity, logging) with your organisation bootstrapped in the identity provider.

The authoritative, always-current procedure is **[Install Foundation](src/foundation/INSTALL.md)** —
follow its steps top to bottom.

**Done when:** the install prints its "🎉 your TAPPaaS foundation is installed" summary, and you can
reach the Proxmox UI, the firewall UI and the CICD mothership.

## Stage 4 — Add an Environment *(optional)*

Run more than one world on the same platform: production next to family, tenants next to
experiments — separated environments with network boundaries between them. See
[Add an Environment](INSTALL-ENVIRONMENT.md).

**Done when:** each environment exists with its own zones and domain.

## Stage 5 — Add a Satellite *(optional)*

If you planned a **satellite** in stage 1 (public ingress without a public IP, off-site backup,
admin VPN — see the [hardware guide](hardware-selection.md#the-satellite-the-gap-filler)), enrol the
VPS now via [the satellite install](src/foundation/satellite/INSTALL.md).

**Done when:** the satellite carries its roles.

## Stage 6 — Add Stacks

Install the workloads you chose in stage 1. First-party modules install with
`module-manager module add <module>`; community module stores register once with
`site-manager repository add <repo> --branch <branch>`, after which their modules install the same way.

| Stack | What you get |
|-------|--------------|
| [AI stack](https://tappaas.org/install/ai-stack/) | Local AI: vLLM serving, LiteLLM gateway, OpenWebUI |
| [Productivity stack](https://tappaas.org/install/productivity-stack/) | Nextcloud (n8n, Karakeep planned) |
| [Home stack](https://tappaas.org/install/home-stack/) | Home Assistant (Jellyfin, Immich planned) |
| [IoT stack](https://tappaas.org/install/iot-stack/) | deCONZ Zigbee gateway |

**Done when:** each installed app answers on its URL and is known to the
[Module Manager](src/foundation/tappaas-cicd/manager/module-manager/README.md).

## Stage 7 — Operate

Hand over to day-to-day operation: the managers keep updating, backing up and health-checking the
platform. That is [Operate](https://tappaas.org/operate/) — bookmark it.
