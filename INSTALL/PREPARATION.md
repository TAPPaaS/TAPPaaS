# Appendix D — Preparation

What to have ready before the install. The install script asks for most of it up front, so with
this list ticked it runs to the end without stopping.

## 1. The computer you install from

- [ ] A **Mac or Linux PC** for `bootstrap-tappaas.sh` (a Windows PC:
  [Appendix A](WINDOWS.md)).
- [ ] `curl`; on a Mac also Docker (`brew install colima docker && colima start`, or Docker
  Desktop); for a network boot, `dnsmasq`.
- [ ] A **USB stick** of 4 GB or more if the first machine boots from a stick (it is erased).
- [ ] For a site in Hetzner: your **SSH key**, the one you give Hetzner's rescue system, and the
  **WireGuard app**.

## 2. The network

- [ ] A wired network with **DHCP and internet**, which the first machine and your computer are
  both on. It becomes the site's internet side (WAN): the firewall's WAN gets an address on it.
- [ ] It must **not use 10.0.0.0/8**: the site's own networks are there.
- [ ] **The first machine's ports:** one is enough for a single machine. For a cluster, two: one
  to your router (WAN) and one to the switch between the machines (LAN). The others need one
  port each, to the switch.
- [ ] **A managed switch?** Know how to log in to it: its ports to the machines become trunks
  for the site's VLANs (Day 2, *Switch fabric*; TAPPaaS sets supported switches itself).
- [ ] Later, the firewall can take the place of your router, with its WAN straight on your
  internet line.

## 3. The site's names

- [ ] **Site name** (`--site`): lowercase, at most 15 characters, e.g. `warmelo1` (a place and a
  number). It names the Proxmox cluster and cannot be changed.
- [ ] **Organisation** (`--organization`): lowercase. It names your default environment, its
  network zone and your organisation in sign-in. Defaults to the site name.
- [ ] **Domain** (`--domain`), optional. Without one the site gets `<site>.home.arpa`, served only
  inside the site; nothing public is needed. With your own domain, services are published as
  `<service>.<domain>` once you make the site public.

## 4. A domain, if you want to go public

- [ ] A **registered domain**, and preferably a DNS provider with an **API token**: TAPPaaS then
  gets one wildcard certificate for all services (about 120 providers: Cloudflare, deSEC,
  Hetzner, OVH, Route 53, …). For Cloudflare, a custom token with `Zone → Zone → Read` and
  `Zone → DNS → Edit`, limited to your domain.
- [ ] Without a token, each published service gets its own certificate, and must be reachable
  from the internet on port 80.
- [ ] The token is given on Day 2 (*Make it public*), not at install.

## 5. Credentials and contact

- [ ] A **strong root password** for the machines. The firewall and every service make their
  own credentials.
- [ ] An **email address you read**: alerts from the site go there, and it becomes your sign-in
  user.

## 6. The size

- [ ] **small**, **medium** or **large**, from [Appendix B](HARDWARE.md). Small for one 32 GB
  machine or a test system.

## 7. The branch

| Branch | What it is | For whom |
|--------|------------|----------|
| **`stable`** | The released, supported TAPPaaS | Every production site |
| **`main`** | Ongoing development; moves fast, may break | Contributors and evaluators who want the newest |

If in doubt, choose `stable`. The site follows its branch through its automatic updates, so this
is the risk you keep. `stable` releases are signed; compare the signer the install prints with
[the published fingerprints](FOUNDATION.md#compare-the-release-signer).

**Done when** every box is ticked. Next: the install guide you chose, or
[Appendix E](FOUNDATION.md) for the detail.
