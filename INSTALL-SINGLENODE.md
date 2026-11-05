# Install TAPPaaS on a single machine

The shortest way to a running TAPPaaS: one machine, one disk, one network port, and a
Mac or Linux PC beside it on the same wired network. Everything else — more machines,
data disks, managed switches, Wi-Fi, going public — can be added later as Day 2
operations. For the full picture, see [INSTALL.md](INSTALL.md).

## What you need

**The machine**

- x86-64, with virtualisation (Intel VT-x / AMD-V) switched on in its firmware
- 32 GB of memory
- one SSD or NVMe disk of 0.5 TB or more — it is **wiped**
- one Ethernet port, cabled to your router (or to a switch behind it)
- able to boot from a USB stick

**Beside it**

- a Mac or Linux PC on the **same wired network** as the machine
- Docker on it (Docker Desktop, or Colima on a Mac — the script starts it when it is
  installed but stopped) and `curl`
- a USB stick of 4 GB or more — it is **erased**
- internet through your router, which hands out addresses by DHCP
- your email address

## 1. Make the install stick and start the install

On the Mac or PC, in an empty directory:

```bash
# The stock Proxmox VE ISO (about 1.5 GB)
curl -fSLO "https://enterprise.proxmox.com/iso/proxmox-ve_9.2-1.iso"

# The TAPPaaS install script
curl -fsSL "https://codeberg.org/TAPPaaS/TAPPaaS/raw/branch/main/src/foundation/cluster/make-install-media.sh" \
     -o make-install-media.sh && chmod +x make-install-media.sh

# Build the stick, then follow the install
./make-install-media.sh
```

The script asks for your email and a root password for the machine; for the rest, press
Enter to take the defaults (country, keyboard, time zone from this computer). It builds
`proxmox-ve_9.2-1-tappaas-auto.iso`, writes it to the USB stick you choose (it asks for
your login password on this computer to do so), and asks for the site's name. With no
domain given, the site gets `<site>.home.arpa`, served inside the site.

Keep the script running and its window open: it waits for the machine.

## 2. Boot the machine from the stick

1. Plug the stick into the machine, with its Ethernet cable to the router connected.
2. Switch it on and choose the USB stick in its boot menu (often F11, F12 or Esc).
3. Proxmox installs by itself, wipes the disk and reboots. Take the stick out when it
   reboots.

The script on your Mac finds the machine on the network and starts the TAPPaaS install
on it: the firewall, the management VM, the platform services. Its log scrolls in the
script's window and is kept in `make-install-media-<date>.log`. The install keeps
running on the machine if your Mac loses the connection; run the script again with
`--use proxmox-ve_9.2-1-tappaas-auto.iso` to follow it again.

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

- **No failover.** If the machine stops, so does everything on it.
- **Backups need more.** Rest of foundation installs the backup service as a
  placeholder: it starts backing up once the machine gets a second disk for it, or a
  backup buddy (another TAPPaaS site) is added.
- **One port.** The firewall's internet side shares your home network; the site's own
  networks live inside the machine. A second machine, a switch or a second port can be
  added later.
