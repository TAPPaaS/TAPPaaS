# Install a single node local TAPPaaS system

One machine, one disk, one network port, and a Mac or Linux PC beside it on the same wired
network. More machines, data disks, switches, Wi-Fi and going public can be added later.
What each step does, in more depth: [Appendix E](FOUNDATION.md).

## What you need

**The machine**

- x86-64, with virtualisation (Intel VT-x / AMD-V) switched on in its firmware
- 32 GB of memory
- one SSD or NVMe disk of 0.5 TB or more — it is **wiped**
- one Ethernet port, cabled to your router (or to a switch behind it)
- able to boot from a USB stick, or from the network (PXE, UEFI)

**In addition**

- a Mac or Linux PC (with a Windows PC, follow [Appendix A](WINDOWS.md) instead of steps 0
  to 2 below)
- a wired network that both the Mac or PC and the machine are on, with DHCP and internet
  access
- a USB stick of 4 GB or more, which is **erased** (not needed if you boot the machine over
  the network instead)

## 0. Prepare the Mac or PC

The script needs `curl`, Docker on a Mac, and `dnsmasq` for the network boot. On a Mac, with
[Homebrew](https://brew.sh):

```bash
brew install colima docker dnsmasq && colima start
```

On Debian or Ubuntu (no Docker needed):

```bash
sudo apt install curl dnsmasq
```

## 1. Build the installer and start the install

In an empty directory:

```bash
curl -fsSL "https://codeberg.org/TAPPaaS/TAPPaaS/raw/branch/main/src/foundation/cluster/bootstrap-tappaas.sh" -o bootstrap-tappaas.sh && chmod +x bootstrap-tappaas.sh
```

```bash
./bootstrap-tappaas.sh
```

It asks everything first, then runs without questions:

- **What to do:** **2** to write the installer to a USB stick, or **4** to boot the machine
  over the network from this computer.
- Your **admin email** and a **root password** for the machine.
- The **site's name**, and its **size**: answer **small**.
- Branch, organisation and domain: press Enter for the defaults.
- Your **login password on this computer** (`sudo`), once.

It downloads the Proxmox VE ISO, builds an installer that asks nothing, and writes or serves it.
Keep the script's window open: it waits for the machine.

## 2. Boot the machine

With its network cable connected, boot it from the stick or from the network (its boot menu is
often F11, F12 or Esc). Proxmox installs by itself and reboots; take the stick out.

The script finds the machine and runs the TAPPaaS install on it, its log scrolling in the window
(and kept in `bootstrap-tappaas-<date>.log`). If the window closes, run the script again and
choose **3** to follow it. It ends with the console's address, such as
`http://192.168.1.41:9097/setup/day1`, and how to show the access token.

## 3. Day 1 in the console

Open the address from the same network and enter the token. Do the steps in order:

1. **Finish the first node's setup:** LAN port **This machine alone**; disks **Boot pool
   only**.
2. **Add more nodes:** **No more machines**.
3. **The admin VPN:** enrol this computer and import the WireGuard file it gives you. It is your
   way in from now on.
4. **Rest of foundation:** choose your sign-in password and start it. It installs sign-in,
   logging and the backup placeholder, then creates your organisation and you.
5. **Status and health checks:** when all is well the page says **you have a working system**.

Then add an application stack (Day 2) to make the system useful.

## What one machine means

- **Size small:** every module gets less memory and disk than the default. The foundation plus
  the home and office stacks fit in 32 GB. More memory later: `site-manager site modify --size
  medium`.
- **No failover:** if the machine stops, so does everything on it.
- **Backup is a placeholder** until the machine gets a second disk or a backup buddy.
- **One port:** the site's own networks live inside the machine.
