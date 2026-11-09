# Appendix E — The foundation install in detail

What the install guides' steps do, and the choices behind them. The guides are enough to install;
read this when you want to know what happens, choose differently, or something does not go as
expected. The commands under it all: [Appendix H](../../src/foundation/INSTALL.md).

## 1. What the install builds

```
   internet / your router
        │
   [first machine, WAN port] ── bridge wan ── firewall VM (OPNsense): its WAN address from your router
   ┌──────────────────────────────────────────────────────────────────────┐
   │  Proxmox                                                             │
   │    firewall VM     lan → 10.0.0.1   the site's gateway, DNS, DHCP     │
   │    tappaas-cicd    10.0.0.x         the management VM and the console │
   │    the node        10.0.0.10        (tappaas2 10.0.0.11, …)           │
   └──[LAN port, or none on a single machine]─────────────────────────────┘
        │
   [switch] ── the other machines, access points, devices in the site's VLANs
```

- **The firewall** is the site's only way to the internet. Every network of the site (management,
  services, clients, each environment's zone) is a VLAN on the `lan` bridge behind it.
- **tappaas-cicd** owns the site: its configuration, the managers that change things, the nightly
  updates, the console.
- **The machine keeps its first address** on your network as well, so the install never loses its
  connection. It reaches the internet through the firewall from the end of the install on.

## 2. The install script

`bootstrap-tappaas.sh` runs on a Mac or Linux PC beside the first machine. It asks everything
first, then runs without questions.

**What to do**, the first question:

| Choice | What it does | When |
|--------|--------------|------|
| 1 | Makes the installer and writes it to a USB stick | To install later, or from another computer |
| 2 | The same, then installs TAPPaaS on the machine booted from it | The usual choice |
| 3 | The stick is made already: installs TAPPaaS on the machine booted from it | After 1, or to follow an install again after the window closed |
| 4 | Makes the installer and boots the machine over the network from this computer | No stick; the machine can boot from the network (PXE, UEFI) |
| 5 | Only makes the installer file | To write it yourself |

**The questions:** your email, the root password, the site's name, then the branch, organisation,
domain and size (Enter takes the default). Country, keyboard, time zone and the node's name are
taken from this computer and shown. Every answer can be given as an option instead; `--help`
lists them:

```bash
./bootstrap-tappaas.sh --email you@example.org --boot usb --site home --size small --install
```

**What it does then:**

1. Downloads the newest Proxmox VE ISO (about 1.5 GB), unless one is in the directory, and checks
   it against Proxmox's checksum.
2. Builds `proxmox-ve_<version>-tappaas-auto.iso`: the stock installer with an answer file, so it
   asks nothing. It carries the public half of a key made for it (`…-tappaas-auto.key`, next to
   it), which is how the script finds and logs in to the machine. Keep both private: they are the
   machine's root access until the install has ended.
3. Writes it to the stick you choose from a list (it is erased), or serves it on the network
   (with `dnsmasq`, alongside your router, which keeps handing out addresses).
4. Waits for the machine, logs in with that key, and starts the TAPPaaS install on it in a `tmux`
   session, so it keeps running if this computer loses the connection. Its log scrolls in the
   window and is kept in `bootstrap-tappaas-<date>.log`.

**The boot disk.** The installer takes the smallest SSD or NVMe disk, and both of an identical
smallest pair, as a mirror. `--disk 500GB`, `--disk "Samsung 990"` or `--disk <serial>` picks
another. The chosen disk is **wiped**; the others are left alone for data pools on Day 1.

## 3. On the machine

The install runs five phases; each prints what it waits for, and a line per real step:

1. **Node:** Proxmox's post-install, the `wan` bridge on the port with internet, the `lan` bridge
   on the other port (or on none), and the Proxmox cluster named after the site.
2. **Firewall:** downloads the prebuilt OPNsense image and boots it at `10.0.0.1`, with
   credentials of its own.
3. **Gateway:** the node gets its management address `10.0.0.10` and points its route and DNS at
   the firewall. Nothing is unplugged and the first address stays.
4. **Check:** gateway, DNS, internet.
5. **Platform:** builds tappaas-cicd, writes the site's configuration (the site, its zones, the
   management and default environments) and installs the console.

It ends with a framed **Congratulations** and the console's address:

- **At home** (the firewall's WAN is on a private network): `http://<the firewall's WAN
  address>:9097/setup/day1`, from that network only. This door closes once sign-in is installed.
- **With a public WAN address:** through an ssh tunnel to the node,
  `ssh -N -L 9097:<tappaas-cicd>:9097 root@<node>`, then `http://localhost:9097/setup/day1`.

The console asks for its **access token** the first time; the end note says how to show it (or
`--show-token` prints it on the script's screen, never in the log).

### Compare the release signer

`stable` and `staging` releases are tags signed by the TAPPaaS owners. The install checks that the
release it clones is signed by one of the keys below, records them, and from then on accepts only
updates signed by a key the last verified release lists. The fingerprints are the one thing you
take on trust, so compare them with what the install prints:

```
TAPPaaS v2.4: signed by SHA256:… — compare it with the fingerprint in INSTALL.md
```

| Owner | Release key fingerprint |
|-------|-------------------------|
| Lars Rossen | *not published yet — the release keys are being enrolled* |
| Erik Daniel | *not published yet — the release keys are being enrolled* |

Check the same fingerprints on [tappaas.org](https://tappaas.org) and in the release notes; if
they differ anywhere, stop and ask before installing. Until the keys are published, releases are
unsigned and the install says so (`TAPPaaS signs no releases yet`). `main` is never signed. More:
[Verified updates](../../src/foundation/tappaas-cicd/VERIFIED-UPDATES.md).

## 4. Day 1

The console's Day 1 page lists the steps in order. Each says what it waits for and is done when
the site shows it, not when a button was pressed.

### Finish the first node's setup: its LAN port and disks

- **Its LAN port:** the port cabled to the switch between the machines. Two ports to the switch
  become a bond. **This machine alone** keeps the site's networks inside the machine: a single
  machine with one port, or a Hetzner server.
- **Its disks:** a data pool on the free disks (`tanka1`), mirrored when there are two. The
  firewall and tappaas-cicd move onto it live, without a restart, and later guests are placed
  there; HA replicates from it. **Boot pool only** for a machine with one disk. A disk that holds
  data needs to be wiped first, which the wizard asks for by name.

### Add more nodes

One machine at a time, with the **Add node** wizard:

1. **The machine and where it is cabled:** its name (`tappaas2`, …), its switch port when the
   switch is managed by TAPPaaS.
2. **The installer:** a network boot (nothing to make), or an installer stick, written by a node
   of the site or on your own computer from the image the wizard offers.
3. **Boot it.** The site opens a short install window for that machine only; any other machine
   that boots is refused. Proxmox installs unattended, on the boot disk chosen as above.
4. **The join:** it moves to its management address (`10.0.0.11` for `tappaas2`), joins the
   cluster and gets the site's baseline. Its ports are asked with the real ones on screen.
5. **Its data pool**, from the disks it really has.

**Adopt a machine** (Day 2 page) joins a machine that already runs Proxmox instead. With a
**managed switch**, register it and set its trunk ports before the second machine (Day 2,
*Switch fabric*), or the VLANs will not cross between the machines.

### The admin VPN

**Enrol a device**: the wizard has you make a key pair on your device (the private key never leaves
it), registers the public key, and gives you the WireGuard file to import. With the tunnel up you
reach the site's management network and names from anywhere. A computer that sits on the site's
own LAN can answer **on the LAN** instead, and enrol later for access from outside.

### Rest of foundation

Shows the plan (which pool each module goes to), asks for the password you will sign in with,
and installs, in order:

- **backup** (Proxmox Backup Server): a placeholder until there is a `tankc1` pool on another
  machine or a backup buddy; it then becomes the real thing in place;
- **identity** (sign-in, Authentik), with your organisation and you as its first user;
- **logging** (Grafana, Loki), with the site's alerts.

It takes a while and keeps going if the browser closes. Afterwards the console sits behind
sign-in.

### Status and health checks

The modules, the nodes, the internet, and in a cluster the VLANs between the machines. When all
pass, the page says **you have a working system**.

## 5. Right after

**Take the backup keys off the site.** Backups are encrypted, and their keys live on tappaas-cicd,
which is inside what a lost site loses. With a USB stick in the first machine, on the Day 2 page:
**Write the backup keys to a USB stick** (on tappaas-cicd: `backup-manager key export --usb`). It
encrypts them with a password you choose and reads them back. Make two sticks, keep them at two
places away from the site, and the password elsewhere.

**Check that alert mail reaches you.** On tappaas-cicd: `tappaas-support-bundle.sh --test`. It
sends a test alert and its all-clear to your email. Nothing arrives? Check the spam folder and the
address (Site page).

## 6. Day 2

The Day 2 page, in any order:

- **Repositories:** module stores other than TAPPaaS's own. On `stable`, a repository that signs
  its releases is added with its owners' key fingerprints.
- **Switch fabric:** register each managed switch and its ports to the machines. Supported
  switches (UniFi) are set by TAPPaaS; for others it lists the VLANs to set by hand.
- **Stacks:** the applications, each stack with its own install notes (AI, collaboration, home,
  security).
- **Make it public** (below).
- **Blocking:** a new site's firewall refuses the names on one threat list (hagezi Threat
  Intelligence Mini) for the home and guest zones. Change it, add ads and tracking lists, or clear it;
  add address lists such as Spamhaus DROP to block known-bad networks both ways.
- **Wi-Fi:** register the access points and give each client zone its network name and
  passphrase.
- **The physical site:** rooms, racks and where each machine stands.
- **Environments** ([Appendix F](ENVIRONMENTS.md)) and a **satellite** ([Appendix C](SATELLITE.md)).

### Make it public

Until then the site's names are signed by its own certificate authority, which each person imports
once. Going public gives them certificates every device already trusts:

- **A wildcard through your DNS provider** (recommended): give the provider and its API token in
  the step (Cloudflare: a token with `Zone → Zone → Read` and `Zone → DNS → Edit`, limited to your
  domain), then **Go public with the wildcard**. One certificate for `*.<domain>` serves every
  service, also the ones not reachable from outside.
- **One certificate per service**, without a DNS token: each published service must be reachable
  from the internet on port 80.
- **Stay local:** keep the site's own authority.

A site installed with no domain (`<site>.home.arpa`) first gets its real domain:
`environment-manager modify <environment> --domain <domain>` on tappaas-cicd. Your public DNS
records point at the firewall's public address, or at the satellite's.

## 7. When something goes wrong

- **The script's window closed:** run it again and choose **3**; it finds the install running
  and follows it.
- **A phase stopped:** its last lines say why. Fix it and run the same command again: every step
  checks what is done already.
- **A Day 1 step stays "to do":** its line says what it is waiting for; open it for the output of
  its last run.
- **Something else:** the script's log (`bootstrap-tappaas-<date>.log`) holds the whole install;
  the console's Activity page holds the output of every job it ran. On tappaas-cicd,
  `tappaas-support-bundle.sh --reason "<what went wrong>"` packs the logs and the site's state,
  with personal data and secrets removed, for a support request.
