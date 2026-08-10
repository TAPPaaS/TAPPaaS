# Installing TAPPaaS

This is the short install guide. It reflects the **automated** install with mostly default values.

Note this is a major upgrade from the version 1.0 of TAPPaaS stable:
The firewall and the NixOS VM template are now prebuilt images that download and
boot preconfigured, and the bootstrap scripts chain together — so most steps are
"run one command and watch".

> Defaults (subnet, hostnames, sizing, passwords, branch, …) work out of the box.
> Anywhere a default is mentioned, it can be changed — see
> [Appendix: install options](#appendix-install-options).

**Before you start:** hardware sizing, network plan, domain/DNS, credentials and
branch selection are covered in the preparation guide on the documentation site:
<https://tappaas.org/installation/preparation/>. This document assumes preparation
is done and concentrates on the install itself.

---

## The six steps

Steps 3, 4, and 6 are optional — a single-node, internal-only site with no managed
switches needs only steps 1, 2, and 5.

| Step | What happens | Done when |
|------|--------------|-----------|
| [**1**](#step-1--install-proxmox-ve-on-the-first-node) | First node: install Proxmox VE (preconfigured media, or stock ISO) | Proxmox VE running on `tappaas1` |
| [**2**](#step-2--bootstrap-minimal-tappaas-on-the-first-node-mothership) | First node: one command bootstraps minimal TAPPaaS — firewall, network cut-over and the CICD mothership | `tappaas1` runs behind the firewall; `tappaas-cicd` owns the platform |
| [**3**](#step-3--add-additional-nodes-optional-skip-for-single-node) | Additional nodes join over the network, unattended *(optional)* | all nodes in the cluster |
| [**4**](#step-4--set-up-certificates-for-the-default-domain-optional) | Certificates for the default domain *(optional)* — wildcard, or per-service | cert strategy configured (or deliberately skipped) |
| [**5**](#step-5--complete-the-foundation) | Remaining foundation modules + your organisation | the 🎉 foundation summary prints |
| [**6**](#step-6--managed-switches-and-wi-fi-aps-optional) | Managed switches and Wi-Fi APs *(optional)* — register inventory, then reconcile | switch/AP VLANs + SSIDs in sync with `zones.json` |

---

## Step 1 — Install Proxmox VE on the first node

Install **Proxmox VE 9.2** on the first machine. **Two ways — pick one option,**
then continue with [Step 2](#step-2--bootstrap-minimal-tappaas-on-the-first-node-mothership).

### Option A — preconfigured install media (recommended)

Build a USB stick
that installs Proxmox with **one question asked on the target itself** (the
boot disk, chosen from the machine's real disks); everything else is
answered at build time (email, locale, root password) with TAPPaaS defaults
for the rest. The build runs on **your laptop** — no Proxmox needed and **no
repo checkout needed**: the script is self-contained (on Linux it fetches the
Proxmox assistant automatically; **on macOS it re-runs itself in a Debian
container, so Docker Desktop must be installed and running**).

**First, download the stock Proxmox VE ISO** from the official site —
<https://www.proxmox.com/en/downloads/proxmox-virtual-environment> (or fetch it
directly from the mirror as shown). Then fetch the build script and run it from
the directory holding the ISO:

```bash
# 1. Download the stock Proxmox VE 9.2 ISO (~1.5 GB)
curl -fSLO "https://enterprise.proxmox.com/iso/proxmox-ve_9.2-1.iso"

# 2. Fetch the TAPPaaS build script
curl -fsSL "https://codeberg.org/TAPPaaS/TAPPaaS/raw/branch/main/src/foundation/cluster/make-install-media.sh" \
     -o make-install-media.sh && chmod +x make-install-media.sh

# 3. Build the preconfigured install ISO
./make-install-media.sh --iso proxmox-ve_9.2-1.iso \
       --fqdn tappaas1.mgmt.internal
# prompts for email / country / keyboard / timezone / root password,
# VALIDATES the answer, writes proxmox-ve_9.2-1-tappaas-auto.iso

# 4. Write it to a USB stick (find the device with: diskutil list / lsblk)
dd if=proxmox-ve_9.2-1-tappaas-auto.iso of=/dev/<usb> bs=4M status=progress
```

(If you already have — or prefer — a full checkout:
`git clone https://codeberg.org/TAPPaaS/TAPPaaS.git` and run
`src/foundation/cluster/make-install-media.sh` from it instead.)

Boot the target from the stick with the NIC to your **upstream router**
connected — network comes from **DHCP**, exactly like the PXE flow (the
management addressing is applied later by the TAPPaaS install). Pick the
boot disk when the console asks; the rest is hands-off and WIPES that
disk. Pass `--disk <dev>` at build time for a zero-keystroke install.
⚠ The stick embeds the root password — treat the media like a credential
and rewrite it after use.

> **Disk standard:** the PVE system goes on a **dedicated boot disk**
> (ext4/LVM — the default). The `tankXY` data pools live on **other**
> disks and are created later by the platform (Step 2, [1/5] /
> `config-storage.sh`), never by the installer.

### Option B — stock ISO, manual screens

Download the ISO and create a
bootable USB per the official guide:
<https://pve.proxmox.com/wiki/Installation>.

On the installer screens:
- **Network Nic** select the one you have connected to the upstream router. Initially this is the Lan port but it will eventually become the "wan" port of the TAPPaaS firewall. For secondary TAPPaaS nodes this is will stay lan port, as these nodes wil connect directly via the switch to the lan side of the firewall we create in the first node.
- **Hostname (FQDN):** `tappaas1.mgmt.internal` — TAPPaaS uses the internal
     management domain `mgmt.internal`, **not** your public domain. (Your public
     domain is supplied with `--domain` in Step 2.)
- **Email:** a **working** address you actually monitor — Proxmox sends
     system/health notifications here, and TAPPaaS reuses it as the admin email.
- **Management interface / IP / netmask / gateway / DNS:** must be **valid for
     your existing network** — use a free IP (the proxmox installer is not using DHCP), and the real gateway and DNS
     server of the network this node currently sits on (so it has internet for
     the bootstrap).

### Option C — PXE / network-boot the first node (advanced; no USB stick)

When the target can't boot from USB, or you want to reinstall it repeatedly,
netboot it from your Mac. This stands up a **temporary PXE service** on the Mac —
`dnsmasq` in **proxy-DHCP + TFTP** mode (it does *not* hand out IP leases; your
existing router keeps doing DHCP), which chainloads **iPXE**, which then pulls the
same preconfigured installer as Option A over HTTP. It reuses the exact netboot
repack TAPPaaS uses for follow-on nodes (validated against the PVE 9.2 ISO).

**Prerequisites:** Docker Desktop + Homebrew on the Mac; the Mac and the target on
the **same wired L2 network** (no VLAN/managed-switch separation between them); the
target set to **UEFI network boot**.

**1. Build the preconfigured ISO** as in Option A, but **bake in the boot disk**
(`--disk <dev>`) so the netboot install is fully hands-off (a console disk prompt
over PXE is fiddly):

```bash
./make-install-media.sh --iso proxmox-ve_9.2-1.iso \
    --fqdn tappaas1.mgmt.internal --disk /dev/nvme0n1
# → proxmox-ve_9.2-1-tappaas-auto.iso  (answer + boot disk embedded)
```

**2. Stage the netboot assets** — extract the installer kernel + initrd and append
the whole ISO to the initrd (a Linux operation; run it in a container):

```bash
mkdir -p pxe
docker run --rm -v "$PWD:/work" -w /work debian:trixie bash -c '
  apt-get update -qq && apt-get install -y -qq xorriso cpio >/dev/null
  iso=proxmox-ve_9.2-1-tappaas-auto.iso
  xorriso -osirrox on -indev "$iso" \
    -extract /boot/linux26    pxe/linux26 \
    -extract /boot/initrd.img pxe/initrd >/dev/null 2>&1
  cp "$iso" pxe/proxmox.iso
  sz=$(stat -c %s pxe/initrd); pad=$(( (4 - sz % 4) % 4 ))
  [ "$pad" -gt 0 ] && head -c "$pad" /dev/zero >> pxe/initrd
  ( cd pxe && echo proxmox.iso | cpio -L -H newc -o >> initrd )
  chmod 644 pxe/*'
```

**3. Fetch iPXE and write its boot script** (point it at your Mac's LAN IP):

```bash
cd pxe
curl -fSLO http://boot.ipxe.org/ipxe.efi        # UEFI targets (most machines)
curl -fSLO http://boot.ipxe.org/undionly.kpxe   # legacy-BIOS targets (optional)
MAC_IP=$(ipconfig getifaddr en0)                # your Mac's LAN interface → IP
cat > boot.ipxe <<EOF
#!ipxe
echo TAPPaaS: booting the Proxmox VE auto-installer
kernel http://${MAC_IP}:8080/linux26 ro ramdisk_size=16777216 rw splash=silent proxmox-start-auto-installer
initrd http://${MAC_IP}:8080/initrd
boot
EOF
cd ..
```

**4. Serve the assets over HTTP** (the initrd is ~1.5 GB — HTTP, not TFTP):

```bash
( cd pxe && python3 -m http.server 8080 )        # leave running; Ctrl-C when done
```

**5. Start proxy-DHCP + TFTP** in another terminal — fill in your LAN subnet, the
absolute `pxe/` path, your interface and Mac IP:

```bash
brew install dnsmasq
cat > pxe/dnsmasq-pxe.conf <<'EOF'
port=0                                  # DNS off — PXE only
interface=en0                           # your Mac's LAN interface
bind-interfaces
log-dhcp
dhcp-range=192.168.2.0,proxy            # YOUR lan subnet + 'proxy' (hands out NO leases)
enable-tftp
tftp-root=/absolute/path/to/pxe
dhcp-userclass=set:ipxe,iPXE
dhcp-match=set:efi,option:client-arch,7
dhcp-match=set:efi,option:client-arch,9
dhcp-boot=tag:!ipxe,tag:efi,ipxe.efi          # firmware → iPXE (UEFI)
dhcp-boot=tag:!ipxe,tag:!efi,undionly.kpxe    # firmware → iPXE (legacy BIOS)
dhcp-boot=tag:ipxe,http://192.168.2.10:8080/boot.ipxe   # iPXE → our script (your Mac IP)
EOF
sudo dnsmasq --no-daemon --conf-file=pxe/dnsmasq-pxe.conf   # Ctrl-C when done
```

> **macOS firewall:** allow `dnsmasq` (UDP 67/69 and 4011) and the HTTP port, or
> turn the firewall off on a trusted lab network. `port=0` stops dnsmasq clashing
> with anything already on port 53.

**6. Boot the target from the network** — enter its UEFI boot menu (F12/F11/F8,
board-dependent) and pick **Network / PXE (IPv4)**. It chainloads iPXE →
`boot.ipxe` → the kernel + initrd over HTTP, then runs the **unattended**
installer, which **WIPES the baked `--disk`** and reboots into Proxmox.

**7. Tear down** — once PVE is up (it takes a normal DHCP lease from your router),
`Ctrl-C` both `dnsmasq` and the HTTP server, then continue with
[Step 2](#step-2--bootstrap-minimal-tappaas-on-the-first-node).

> Same version caveat as Option A: this uses the PVE netboot repack (kernel/initrd
> + ISO-in-initramfs) that follow-on nodes also use. The extract step fails loudly
> if `/boot/linux26` or `/boot/initrd.img` ever move in a future PVE release.

## Step 2 — Bootstrap minimal TAPPaaS on the first node

One command turns the bare Proxmox node from Step 1 into a minimal, running
TAPPaaS — the firewall, the network cut-over, and the CICD mothership that owns
the platform. Whichever install option you used in Step 1, continue here: run
the bootstrap from the Proxmox **node console/shell**.

Notes:
- **Prefer the console** — use the **xterm.js** shell option in the tappaas1 menu; it gives more scrollback and persistence on the install output.
- **SSH works too** — see [Appendix: Installing via SSH](#appendix-installing-via-ssh) for setup steps (known_hosts, locale, tmux).
- **⚠ Run from a client that is NOT on `10.0.0.0/24`.** The cutover puts the
     management network (`10.0.0.0/24`) on the node, so a browser/SSH client that
     sits in that subnet loses its return path to the node and freezes. Drive the
     install from a client on your **install/upstream network**, or from a true
     **out-of-band console** (IPMI/iKVM) — not from a `10.0.0.x` laptop. (The node
     keeps its install IP throughout, so such a client never loses it.)

```bash
REPO="https://codeberg.org/TAPPaaS/TAPPaaS/raw/branch/"; BRANCH="main"
curl -fsSL ${REPO}${BRANCH}/src/foundation/install.sh >install.sh
chmod +x install.sh && ./install.sh "$REPO" "$BRANCH" --name <orgname> --domain "yourdomain.com"
```

> The install **re-launches itself inside a `tmux` session** (`tappaas-install`) so a
> dropped SSH connection won't abort it — the firewall step reconfigures networking
> and can briefly cut your session. If you get disconnected, reconnect to the node and
> run `tmux attach -t tappaas-install`. (Opt out with `--no-tmux`.)

Pass two things up front:
- **`--name <orgname>`** — your organisation / system name (lowercase, ≤15
     chars). This is **the one name** for the whole install: it names the **Proxmox
     cluster**, the **`site.json`**, the **default environment**, and (later) the
     **organisation** in the identity provider. If omitted you'll be prompted.
- **`--domain`** — your **public domain**; the reverse proxy is configured for
     `<service>.yourdomain.com`. If omitted you'll be prompted. You don't need the
     domain's DNS-01 API token yet — that comes in Step 4.

On the **first node** this runs the whole foundation bring-up **end-to-end** as
a five-phase chain — you run it once and watch:

1. **[1/5] Node** — Proxmox post-install, the `lan`/`wan` bridges (auto-detected:
      the install NIC with internet becomes **WAN**; the other, to your downstream
      switch, becomes **LAN**), the Proxmox **cluster named `<orgname>`**, and the
      ZFS pools.
2. **[2/5] Firewall** — downloads and boots the **prebuilt OPNsense image** at
      `10.0.0.1`, self-configured with unique credentials (no GUI, no installer).
3. **[3/5] Gateway cutover** — adds this node's management IP `10.0.0.10` and
      points its default route + DNS at the firewall. **Additive and
      non-disruptive**: the upstream IP is *kept*, **no cables move**, your session
      is **not** dropped.
4. **[4/5] Sanity check** — gateway, DNS, internet.
5. **[5/5] Platform** — imports the prebuilt **NixOS template** and builds the
      **`tappaas-cicd` mothership** (`bootstrap.sh` clone+nixos-rebuild → reboot →
      `install.sh`). The cicd's `install.sh` then **writes the system's
      configuration**, automatically:
      - **`site.json`** — the site singleton (nodes, email, repos), via
        `create-site.sh --name <site-code> --organization <org>` (#426: the site
        code is the neutral cluster name; the org names the default env/zone)
      - **`zones.json`** — the network zones, via `network-manager init`
      - the **`mgmt` + default `<org>` environments**, via
        `environment-manager add` (the minimal-set bootstrap)
      - the **foundation modules** (cluster, templates, network, tappaas-cicd) and
        the **Caddy** reverse proxy

> **One name, everywhere:** `<orgname>` = the Proxmox cluster name = `site.json`
> `.name` = the default environment name = your organisation name. You set it
> once with `--name`; the **organisation itself** isn't created until Step 5
> (`rest-of-foundation.sh`, after the identity provider is up).

The domain you passed configures the reverse proxy. To stop earlier, pass
`--skip-firewall` or `--skip-platform`; to drive the in-VM cicd install by hand,
see [Appendix: install options](#appendix-install-options).

When it finishes, `tappaas1` is at `10.0.0.10` behind the firewall and
`tappaas-cicd` owns the platform. Optionally move your admin laptop onto the
**downstream switch** (you'll get a `10.0.0.x` lease; Proxmox at
`https://10.0.0.10:8006`, firewall GUI at `https://10.0.0.1`) — not required,
since the node also keeps its upstream IP until you harden it later.

## Step 3 — Add additional nodes (optional; skip for single-node)

Do this **after** the first node's bootstrap has finished (cicd is up).
Follow-on nodes install **over the network, fully unattended** — no USB stick,
no installer screens. The mothership runs a TTL-limited network-boot trap
(`node-provisioner`): a machine you have **registered** gets installed when it
PXE-boots on the management LAN; every other machine is refused.

Wire the new node's LAN NIC to the **downstream switch** (the `10.0.0.0/24`
management network) and find out which disk is its **boot disk** — that disk
is wiped. *(Managed inter-node switch? Configure its VLAN trunks first; see
[the network section](#network--cutting-over-to-the-firewall).)*

The netboot assets are **staged automatically by the first-node bootstrap**
(`prepare-netboot.sh`, run at the end of the cicd install) — adding nodes is
a latent capability of every TAPPaaS system. After a PVE version upgrade,
re-stage once with `prepare-netboot.sh --force` on the mothership.

**Per node — one command:**

```bash
site-manager node add tappaas2 --pxe
```

The command walks the whole flow and asks only what it cannot know:

1. Registers the node and **arms a TTL-limited PXE trap** (auto-disarms;
   only registered machines are answered).
2. Tells you to **network-boot the machine** (UEFI PXE, e.g. F11). The
   node's console asks **one question — the boot disk** (it lists the
   machine's real disks; the chosen disk is WIPED, ext4/LVM). Everything
   else is hands-off: the installer fetches its per-node answer from the
   mothership and reboots into PVE. The generated root password lands
   under `~/.node-secrets/` (0600) — the mothership's ssh key is already
   authorized.
3. Asks the **join-time questions** with the node's real hardware on
   screen: the WAN NIC (only if this node will host firewall HA) and the
   **data pool** declarations (e.g. `tanka1=single:nvme0n1`).
4. Runs the node step (served from the mothership — no GitHub needed),
   moves the node to its standard mgmt IP (`tappaasN` → `10.0.0.<9+N>`),
   joins the Proxmox cluster, creates the pools, and captures everything
   into site.json.

Every question can be pre-answered for a fully unattended run:

```bash
site-manager node add tappaas2 --pxe --boot-disk sda --mac aa:bb:cc:dd:ee:ff \
    --no-wan --pool 'tanka1=single:nvme0n1'
# --mac also pre-reserves the standard IP, so the node installs onto it directly
```

Afterwards, fold the new topology into HA + replication:

```bash
update-tappaas --force
```

> **Machine can't PXE-boot?** Write the staged netboot image to a stick —
> `dd if=/home/tappaas/pve-tappaas-netboot.iso of=/dev/<usb> bs=4M` on the
> mothership — and boot from USB instead of pressing F11: the flow (and the
> `node add <name> --pxe` command) is otherwise identical, the answer still
> comes from the mothership over HTTP.
>
> **Manual install instead?** Install from a stock ISO or the Step 1 Option A
> stick, give the node its standard mgmt IP (or let it DHCP), then run
> `site-manager node add tappaas2` (no `--pxe`) — it finds the Proxmox at
> the node's designated IP and runs the same join + capture pipeline.
> The underlying tools remain available for surgery: `node-provisioner
> register/enable/disable/status` and `dhcp-manager pxe/host`.

## Step 4 — Set up certificates for the default domain (optional)

**This step is optional** — it provisions the HTTPS certificate that lets your
TAPPaaS services be reached over TLS on `<service>.yourdomain.com`. **Skip it if:**

- you **don't want any external access** to the TAPPaaS system — internal / LAN-only
  use is fully supported; every service stays reachable on the LAN, only the
  *public* HTTPS endpoint of `dns01` modules lacks a certificate; **or**
- you want to **set it up later** — it can be run any time after the foundation is up.

Your domain is already configured (you passed `--domain` in Step 2). Pick one of the
two certificate strategies below.

> *(The public domain lives per-environment. To change the default environment's
> domain later: `environment-manager modify <system-name> --domain <yourdomain>`,
> then set up certificates.)*

### Option A — one wildcard certificate via DNS-01 (recommended)

The default TLS strategy (`proxyTls: dns01`) issues **one wildcard certificate per
TAPPaaS domain** via ACME **DNS-01**, then binds it to every module's reverse-proxy
entry through Caddy's `CustomCertificate` (issue #254). DNS-01 needs no
inbound :80 traffic, so internal-only services get a public cert too.

> **Why not Caddy's own DNS-01?** Since os-caddy 2.0.0 the OPNsense build only
> ships the Cloudflare DNS provider. TAPPaaS uses **os-acme-client** (which
> wraps acme.sh) so you can pick any of the 120 DNS APIs it supports —
> Cloudflare, deSEC, Hetzner, OVH, Route 53, Namecheap, etc.

Run the operator-driven setup on the mothership:

```bash
ssh tappaas@tappaas-cicd      # or its 10.0.0.x address
acme-setup.sh                 # interactive: picks up domain/email, prompts for token
```

The script:
1. Reads the domain from the default environment file
   (`config/environments/<system-name>.json`, `domains.primary`) and the admin
   email from `site.json` (`.email`).
2. Prompts for your **DNS provider** (default `cloudflare`) and its **API token**
   (offers to save them to `~/.acme-dns-credentials.txt`, mode 600, for re-runs).
3. Provisions an ACME account, a DNS-01 validation, a `caddy-reload` automation
   action, and a wildcard certificate (`*.<domain>` + bare apex) on the
   firewall — then signs it and waits for issuance (~10–30 s).
4. Stores the issued cert's OPNsense Trust refid in the runtime
   `config/cert-refids.json`, keyed by environment name (ADR-007c). Every later
   `proxyTls: dns01` module install reads this refid and binds the wildcard via
   `CustomCertificate` automatically.

**Using Cloudflare?** Its DNS-01 token needs specific scopes — see
[Appendix: Cloudflare API token scope](#appendix-cloudflare-api-token-scope).

```bash
# Non-Cloudflare? Pass the provider name; the script asks for that provider's fields:
acme-setup.sh --provider hetzner          # deSEC, hetzner, ovh, route53, ...
# Or seed creds non-interactively (chmod 600):
cat >~/.acme-dns-credentials.txt <<EOF
provider=cloudflare
dns_cf_token=YOUR-TOKEN-HERE
EOF
chmod 600 ~/.acme-dns-credentials.txt
acme-setup.sh
```

To **test before going live**, add `--staging` once (Let's Encrypt staging =
untrusted certs, no rate limits); then re-run without `--staging` for the
trusted prod cert (the script swaps the cert in place — Caddy picks up the new
one automatically via the registered `caddy-reload` action).

### Option B — per-service certificates via HTTP-01 (no DNS API needed)

Choose this if you **don't have ACME / DNS-01 API access to your DNS provider** —
i.e. you can't (or don't want to) issue an API token that lets TAPPaaS edit DNS
records, which Option A's DNS-01 requires. HTTP-01 validates each service over
inbound **port 80** instead of via DNS, so it needs **no DNS API token** — but each
publicly-reachable service gets its **own per-domain certificate** (no shared
wildcard), and that service **must be reachable from the internet on :80** for
issuance and renewal.

There is no wildcard to provision, so you **don't run `acme-setup.sh`**. Instead set
the TLS mode to `http01` on each module you want publicly reachable, in its
`<module>.json`:

```json
{ "proxyTls": "http01" }
```

Caddy then obtains and renews a per-domain certificate for that service via the ACME
HTTP-01 `:80` challenge. The two strategies **coexist per module**, so you can keep
the wildcard (Option A) for most services and use HTTP-01 for a specific public one.

---

## Step 5 — Complete the foundation

From here on you work **from the cicd mothership** (`ssh tappaas@tappaas-cicd`).
One command does two things:

```bash
rest-of-foundation.sh
```

1. **Installs the remaining foundation modules** in order — **backup → identity →
   logging** — then runs a final system update + tests.
2. **Bootstraps your people domain** — once the identity provider (Authentik) is
   up and `config/people/` is still empty (first install), it creates the
   **organisation `<orgname>`** (the same name from Step 2), the `users` group and
   **your installer user** (from `site.json`'s email), and pushes them into
   Authentik. So **this is where your organisation is actually created** — the
   earlier `--name` only reserved the name; the org entity is materialised here.

It's idempotent — safe to re-run if a module needs attention (the people bootstrap
is skipped once `config/people/` exists, so it never disturbs people you've added).
When it finishes you'll see a **"🎉 your TAPPaaS foundation is installed"** summary
(nodes, firewall, mothership, domain/TLS, modules, organisation).

> Prefer to do it by hand? `install-module.sh` is on the `PATH` but reads
> `./<module>.json` from the current directory, so `cd` in first:
> ```bash
> cd ~/TAPPaaS/src/foundation/backup   && install-module.sh backup     #  Proxmox Backup Server
> cd ~/TAPPaaS/src/foundation/identity && install-module.sh identity   #  Identity provider
> cd ~/TAPPaaS/src/foundation/logging  && install-module.sh logging    #  Loki / Grafana / Promtail
> ```
> *(Module sizing/zones are defaults — see appendix.)*

---

---

## Step 6 — Managed switches and Wi-Fi APs (optional)

Skip this entirely if you have **unmanaged switches and no TAPPaaS-driven APs** —
an unmanaged switch passes tagged frames transparently, so nothing to configure
(see [Network — cutting over to the firewall](#network--cutting-over-to-the-firewall)
for the inter-node trunk story). Do this step if you have **managed switches** or
**Wi-Fi access points** whose per-zone VLANs/SSIDs you want TAPPaaS to keep in sync.

TAPPaaS treats switches and APs as two more reconcile *providers* alongside OPNsense
and Proxmox — all driven from `zones.json` (the VLAN tags and the per-zone `SSID`
field). Unlike the firewall/Proxmox planes, **these are not applied automatically**
by `rest-of-foundation.sh` or `update-tappaas`: they need an inventory you register
once, and (for hardware without a vendor plugin) a manual "tag these VLANs" step. Run
everything below **from the mothership** (`ssh tappaas@tappaas-cicd`).

### 6a — Switches

Fastest path is the interactive bootstrap, which registers each brand/switch/uplink
port and then applies:

```bash
setup-switches.sh          # interactive; ends by running `switch-controller reconcile --apply`
```

Or register by hand with the `switch-controller` CLI, then reconcile:

```bash
# A manual switch with two node-uplink (trunk) ports:
switch-controller add-switch core --vendor tplink --managed manual
switch-controller add-port  core 9  --type node --target tappaas1 --target-port eth0
switch-controller add-port  core 10 --type node --target tappaas2 --target-port eth0
switch-controller reconcile --apply     # manual switch → prints the VLANs to tag (and records them)
#   …tag those VLANs on ports 9 & 10 in the switch UI…
```

- `--managed manual` → TAPPaaS **prints** the VLANs to tag; you apply them on the
  device (no separate `confirm` needed — `reconcile --apply` already records intent).
- `--managed auto` → a vendor plugin (currently **UniFi OS**) programs the switch over
  its API on `reconcile --apply`. Auto/controller brands read
  `~/.unifi-os-credentials.txt` (`url`/`username`/`password`, mode 0600).
- Check state any time: `switch-controller list-ports` (per-port config + drift vs
  `zones.json`), or `network-manager reconcile --only switch` for a dry-run.

### 6b — Wi-Fi access points

First set the real SSID **names** and WPA **passphrases** (they replace the
`<…_SSID>` placeholders in `zones.json`; secrets go to a 0600 file, never committed):

```bash
setup-wlan-secrets.sh          # set SSID names + passphrases  (→ ~/.wlan-secrets.txt)
setup-wlan-secrets.sh --list   # show SSIDs and whether a secret is set
```

Then register the AP(s) and map each SSID to a zone, and reconcile:

```bash
ap-controller add livingroom --vendor unifi --ip 10.0.0.21
ap-controller ssid livingroom add HomeWiFi  --zone home  --security wpa2-personal
ap-controller ssid livingroom add GuestWiFi --zone guest --security wpa2-personal
ap-controller link livingroom --switch core --port 5      # the AP's uplink port
ap-controller reconcile --apply
```

- With a **UniFi controller**, `switch-controller interrogate` auto-populates the AP
  inventory and marks the AP's uplink port as a WiFi-VLAN trunk — so adopting a
  controller wires most of this up for you.
- `security`: `open | wpa2-personal | wpa3-personal | wpa2-enterprise | wpa3-enterprise`
  (enterprise needs a RADIUS profile — currently a manual step).

### Re-running

All of the above is idempotent. After the initial setup, a full
`network-manager reconcile --apply` re-converges every plane (OPNsense, Proxmox,
switch, ap) against `zones.json`; add `--only switch` / `--only ap` to scope it.
Manual switches always report as "needs-manual" on apply (they can't self-program)
— that's expected, not an error. Full reference:
[network/scripts/README.md](../foundation/network/scripts/README.md) (ADR-008).

---

## Next steps

The foundation is complete. Everything from here is covered on the documentation
site: **add environments**, **add a satellite**, **add stacks** (each module's
install guide), and day-to-day **operation** — start at
<https://tappaas.org/installation/>.

## Network — cutting over to the firewall

Putting the firewall (a VM on `tappaas1`, at `10.0.0.1`) inline as the gateway is
done **for you** by the bootstrap (Step 2, [3/5]) — `config-network.sh
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

## Appendix: Cloudflare API token scope

*(Extra detail — only relevant if you chose **Cloudflare** as the DNS provider for the
wildcard certificate in Step 4, Option A.)*

Create a **custom token** at <https://dash.cloudflare.com/profile/api-tokens> with
permissions `Zone → Zone → Read` and `Zone → DNS → Edit`, restricted to your domain.
Optionally allow only the firewall WAN IPv4 *and* IPv6 (or skip the IP filter — the
token is already zone-scoped).

---

## Appendix: install options

Defaults are chosen so the commands above "just work". Override as needed:

| Default | How to change |
|---|---|
| Branch `stable` | Pass a different branch as the 2nd arg to `install.sh` (e.g. `main`). |
| Hostnames `tappaas1/2/3` | Set during the Proxmox install; the **first** node must be `tappaas1` (it creates the cluster). |
| Management subnet `10.0.0.0/24`, gateway/firewall `10.0.0.1` | `config-network.sh --mgmt-ip <CIDR> --gateway <ip>`; firewall LAN lives in `src/foundation/network/firewall-config.xml.template`. |
| Org / system / cluster name | `install.sh --name <orgname>` (the one name: Proxmox cluster, `site.json`, default environment, organisation; lowercase, ≤15 chars; prompted if omitted). |
| Auto cluster create/join | `install.sh --cluster` / `--join` / `--no-cluster`. |
| Chained first-node install (node→firewall→cutover→sanity→platform) | The entry point `foundation/install.sh` runs all 5 phases on the first node by default; stop earlier with `--skip-firewall` or `--skip-platform`. The node step alone is `cluster/install.sh`. |
| Gateway cutover (route via firewall) | Done automatically by the bootstrap; manual: `config-network.sh --swap-gateway` (additive — keeps the upstream IP). |
| Take Proxmox off the upstream net (hardening) | `config-network.sh --drop-upstream` (run later, once you manage via the mgmt net / netbird). |
| Platform install branch / domain | `install-platform.sh --branch <name> --domain <domain>`. |
| Automated vs. manual cicd install | `install-platform.sh` automates the in-VM install over SSH; pass `--manual-cicd` to run `bootstrap.sh` then `install.sh` by hand inside the cicd VM instead. |
| ZFS pools (`tankXY`, topology) | `config-storage.sh --pool name=topology:disks` (interactive by default). |
| Firewall root password | `config-firewall.sh --root-pw <pw>` (otherwise prompted/generated; the API key is always unique per deploy). |
| VM sizing, storage, network zone per module | edit the module's `<name>.json` (cores, memory, diskSize, storage, zone0/bridge0). |
| Domain / TLS | provided to the `firewall`/app modules; TLS issuance is DNS-01 by default. |
| Unattended runs | most scripts accept `--non-interactive` (supply the values via flags). |

Field definitions for module JSON are in `src/foundation/schemas/module-fields.json`.
Network zones/VLANs come from the git template
`src/foundation/tappaas-cicd/manager/network-manager/zones.json`, which
`network-manager init` transforms into the live, per-installation
`config/zones.json` at install time.

---

## Appendix: Installing via SSH

The main install guide recommends the Proxmox console, but SSH works fine with
proper preparation. The key is using `tmux` so the install continues if your
connection drops during network reconfiguration.

### 1. Generate and install an SSH key (from your workstation)

If you don't already have an SSH key pair:

```bash
# Generate a new key (accept defaults, optionally set a passphrase)
ssh-keygen -t ed25519 -C "your-email@example.com"
```

**Reinstalling?** If you previously installed TAPPaaS on the same IP, SSH will
refuse to connect due to a changed host key (`WARNING: REMOTE HOST IDENTIFICATION
HAS CHANGED!`). Remove the old entry first:

```bash
ssh-keygen -R <proxmox-ip>
```

```bash
# Copy the public key to the Proxmox node (use the node's current IP)
ssh-copy-id root@<proxmox-ip>
```

Now you can SSH without a password:

```bash
ssh root@<proxmox-ip>
```

### 2. Fix locale warnings

Fresh Proxmox installs may show Perl locale warnings. Fix them:

```bash
# Quick fix for current session
export LC_ALL=en_US.UTF-8
export LANGUAGE=en_US.UTF-8

# Permanent fix (then start a new shell)
echo "en_US.UTF-8 UTF-8" >> /etc/locale.gen && locale-gen && \
  update-locale LC_ALL=en_US.UTF-8 LANGUAGE=en_US.UTF-8
```

### 3. (Optional) Use tmux for session persistence

`tmux` keeps your session alive if SSH disconnects during network
reconfiguration. This is optional but recommended:

```bash
apt update && apt install -y tmux
tmux new -s install
```

**If your SSH connection drops**, reconnect and reattach:

```bash
ssh root@<proxmox-ip>
tmux attach -t install
```

**Useful tmux commands:**

- `Ctrl+b d` — Detach (leave session running in background)
- `Ctrl+b [` — Scroll mode (arrow keys to scroll, `q` to exit)

### 4. Run the install

Run the bootstrap command from Step 2:

```bash
REPO="https://codeberg.org/TAPPaaS/TAPPaaS/raw/branch/"; BRANCH="main"
curl -fsSL ${REPO}${BRANCH}/src/foundation/install.sh >install.sh
chmod +x install.sh && ./install.sh "$REPO" "$BRANCH" --name <orgname> --domain "yourdomain.com"
```

Even if your SSH drops during network cutover, the install continues inside
tmux. Reconnect with `tmux attach -t install` to see progress.

### 5. After install

Once complete, you can access:

- **Proxmox UI:** `https://10.0.0.10:8006` (or the node's upstream IP)
- **Firewall GUI:** `https://10.0.0.1`
- **CICD Mothership:** `ssh tappaas@tappaas-cicd` (or `ssh tappaas@10.0.0.143`)
