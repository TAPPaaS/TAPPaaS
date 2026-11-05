# Install a single node local TAPPaaS system from a Windows PC

The install script for the [single node guide](SINGLE-NODE-LOCAL.md) runs on a Mac or Linux
PC. From a Windows PC you install Proxmox from the stock ISO by hand, answering its questions
the way the script would, then start the TAPPaaS install on the machine itself. This replaces
steps 0 to 2 of that guide; step 3, Day 1 in the console, is the same.

You need the machine and the network that guide lists, and a USB stick of 4 GB or more,
which is **erased**.

## 1. Write the Proxmox installer to a USB stick

1. Download the newest Proxmox VE ISO from
   <https://www.proxmox.com/en/downloads/proxmox-virtual-environment>.
2. Write it to the stick with [Rufus](https://rufus.ie) (choose **DD image** mode when Rufus
   asks) or [balenaEtcher](https://etcher.balena.io).

## 2. Install Proxmox

With the machine's Ethernet cable to your router connected, plug in the stick, switch the
machine on and choose the stick in its boot menu (often F11, F12 or Esc). Choose **Install
Proxmox VE (Graphical)**, and answer:

| Screen | Answer |
|---|---|
| Target harddisk | **Options → Filesystem: zfs (RAID0)**, on the machine's disk. Not ext4: with one disk the guests live in this ZFS pool |
| Location and time zone | Your country, time zone and keyboard |
| Password and email | A root password for the machine, and **your email**: alerts from the site go there |
| Management network | The network card with the cable. **Hostname (FQDN): `tappaas1.mgmt.internal`**, exactly. Keep the address, gateway and DNS server it fills in from your router |

It wipes the disk, installs and reboots: take the stick out. The screen then shows the
machine's address, such as `https://192.168.1.41:8006`.

## 3. Start the TAPPaaS install on the machine

Open that address in a browser on the Windows PC (accept the certificate warning), log in as
`root` with the password you chose, and open **Datacenter → tappaas1 → Shell**. Download the install script:

```bash
curl -fsSL https://codeberg.org/TAPPaaS/TAPPaaS/raw/branch/stable/src/foundation/install.sh -o install.sh && chmod +x install.sh
```

Then start the install, with your site's name in place of `home`:

```bash
./install.sh https://codeberg.org/TAPPaaS/TAPPaaS/raw/branch/ stable --name home --size small --non-interactive
```

`main` in place of `stable`, in both commands, takes the newest work. The site gets the
domain `<name>.home.arpa`, served inside the site.

The install takes a while: keep the Shell open until it ends. It ends with the console's
address, such as `http://192.168.1.42:9097/setup/day1`.

The console asks for the setup token the first time. In the same Shell:

```bash
ssh -i /root/tappaas/tappaas-cicd.key tappaas@tappaas-cicd.mgmt.internal cat config/console-setup-token
```

Then continue with [step 3, Day 1 in the console](SINGLE-NODE-LOCAL.md#3-day-1-in-the-console).
