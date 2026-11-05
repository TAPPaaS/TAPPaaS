# Install a single node local TAPPaaS system

The shortest way to a running TAPPaaS: one machine, one disk, one network port, and a
Mac or Linux PC beside it on the same wired network. Everything else — more machines,
data disks, managed switches, Wi-Fi, going public — can be added later as Day 2
operations. For the full picture, see [INSTALL.md](../INSTALL.md).

## What you need

**The machine**

- x86-64, with virtualisation (Intel VT-x / AMD-V) switched on in its firmware
- 32 GB of memory
- one SSD or NVMe disk of 0.5 TB or more — it is **wiped**
- one Ethernet port, cabled to your router (or to a switch behind it)
- able to boot from a USB stick, or from the network (PXE, UEFI)

**In addition**

- a Mac or Linux PC (with a Windows PC, follow
  [Install from a Windows PC](SINGLE-NODE-WINDOWS.md) instead of steps 0 to 2 below)
- a wired network that both the Mac or PC and the machine are on, with DHCP and internet
  access
- a USB stick of 4 GB or more, which is **erased** (not needed if you boot the machine
  over the network instead, below)

## 0. Prepare the Mac or PC

The script needs `curl`, Docker on a Mac, and `dnsmasq` for the network boot.

On a Mac `curl` is already there; install the rest with [Homebrew](https://brew.sh):

```bash
brew install colima docker dnsmasq && colima start
```

(Docker Desktop instead of Colima works too; the script starts either when it is installed
but stopped. Leave out `dnsmasq` if you use the USB stick.)

On Debian or Ubuntu, no Docker is needed:

```bash
sudo apt install curl dnsmasq
```

## 1. Build the installer and start the install

On the Mac or PC, in an empty directory:

```bash
# The TAPPaaS install script
curl -fsSL "https://codeberg.org/TAPPaaS/TAPPaaS/raw/branch/main/src/foundation/cluster/bootstrap-tappaas.sh" \
     -o bootstrap-tappaas.sh && chmod +x bootstrap-tappaas.sh

# Build the installer, then follow the install
./bootstrap-tappaas.sh
```

It downloads the stock Proxmox VE ISO itself (about 1.5 GB, the newest Proxmox lists),
after the questions; an ISO already in the directory is used instead.

The script asks everything first, then runs without questions. The first question is
what to do; for this guide choose:

- **2** to make the installer, write it to a USB stick (it lists the sticks in this
  computer and erases the one you choose) and install TAPPaaS on the machine booted from
  it, or
- **4** to make the installer and boot the machine over the network from this computer
  instead (it answers the machine's network boot alongside your router, which keeps
  handing out addresses); no stick needed.

Then it asks:

- your **admin email** (for email alerting) and a **root password** for the machine;
- the **site's name** (with no domain given, the site gets `<site>.home.arpa`, served
  inside the site) and its **size**: answer **small**, for one machine or a test system;
- the branch, the organisation and the domain: press Enter for the defaults;
- your **login password on this computer** (`sudo`), once.

Country, keyboard, time zone and the node's name are not asked: it shows the defaults
it takes. Every answer can also be given as an option instead (`--help` lists them),
for example:

```bash
./bootstrap-tappaas.sh --email you@example.org --boot usb --site home --size small --install
```

It then builds `proxmox-ve_9.2-1-tappaas-auto.iso`, an installer that sets up Proxmox
without asking anything, and writes or serves it.

Keep the script running and its window open: it waits for the machine.

## 2. Boot the machine

With its Ethernet cable to the router connected:

- **From the stick:** plug it in, switch the machine on and choose the stick in its boot
  menu (often F11, F12 or Esc). Take the stick out when it reboots.
- **Over the network:** switch it on and choose network boot (PXE, UEFI) in its boot
  menu.

Proxmox installs by itself, wipes the disk and reboots.

The script on your Mac finds the machine on the network and starts the TAPPaaS install
on it: the firewall, the management VM, the platform services. Its log scrolls in the
script's window and is kept in `bootstrap-tappaas-<date>.log`. The install keeps
running on the machine if your Mac loses the connection; run the script again and choose
**3** to follow it again.

It ends with the console's address, such as `http://192.168.1.41:9097/setup/day1`, and
how to show the access token the console asks for the first time.

## 3. Day 1 in the console

Open the address from the end of the install, from the same network, and enter the
access token. The Day 1 page lists the steps in order; each says what it is waiting
for. On a single machine:

1. **Finish the first node's setup: its LAN port and disks.**
   - LAN port: the machine has one port, and the install took it for the internet side
     (WAN). Answer **This machine alone**: the site's own network stays inside the
     machine.
   - Disks: there is only the boot disk. Answer **Boot pool only**.
2. **Add more nodes** — answer **No more machines**.
3. **The admin VPN.** Enrol this Mac or PC: the wizard has you make a key pair, registers
   it, and gives you the WireGuard file to import. With the tunnel up you reach the
   site's management network and its names. It is your way in from now on.
4. **Rest of foundation.** Check the plan (on one machine everything goes on its one
   disk), choose the password you sign in with, and start it. It installs identity
   (sign-in), logging and the backup placeholder, then creates your organisation and
   you. It takes a while, and keeps going if the browser is closed.
5. **Status and health checks.** The modules running, the node, and the internet. With
   one machine there is no VLAN to test across machines. When all is well the page says
   so: **you have a working system.**

The steps after that are optional and can wait for Day 2: managed switches, making it
public, more repositories, application stacks, Wi-Fi and the physical site. A good next
step is an application stack, to make the system useful.

## What one machine means

- **Small sizes.** At size small every module is installed with less memory, fewer cores
  and a smaller disk than the default. The foundation, the home modules and the
  collaboration (office) modules then take about 26 GB, leaving the rest for Proxmox
  itself. A module can still be given more by hand, and the whole site moves up with
  `site-manager site modify --size medium` when the machine gets more memory.

- **No failover.** If the machine stops, so does everything on it.
- **Backups need more.** Rest of foundation installs the backup service as a
  placeholder: it starts backing up once the machine gets a second disk for it, or a
  backup buddy (another TAPPaaS site) is added.
- **One port.** The firewall's internet side shares your home network; the site's own
  networks live inside the machine. A second machine, a switch or a second port can be
  added later.
