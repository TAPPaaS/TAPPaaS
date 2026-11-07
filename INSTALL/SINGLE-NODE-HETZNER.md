# Install a single node TAPPaaS system in Hetzner

*In development, not ready: this is how it will work. Until then, use a
[single node at home](SINGLE-NODE-LOCAL.md).*

One rented Hetzner dedicated server, installed from your Mac or Linux PC through Hetzner's rescue
system. No USB stick and no local network are involved. The server keeps its own address; the
firewall gets a second public address of its own, which is where you and the internet reach the
site. What to order and where in Hetzner's Robot: [Appendix G](HETZNER.md).

## What you need

- A **Hetzner dedicated server** (Robot or Server Auction): 32 GB of memory, NVMe disks of 0.5 TB
  or more (two equal disks become a mirror). Hetzner's cloud servers cannot run TAPPaaS.
- An **additional IPv4 address** for the server, with a **virtual MAC** generated for it in
  Robot.
- **Rescue mode activated** on the server with your SSH key, and the server reset into it.
- A Mac or Linux PC with `curl` (and Docker on a Mac:
  `brew install colima docker && colima start`), and the
  [WireGuard app](https://www.wireguard.com/install/).

## 1. Run the install

In an empty directory:

```bash
curl -fsSL "https://codeberg.org/TAPPaaS/TAPPaaS/raw/branch/main/src/foundation/cluster/bootstrap-tappaas.sh" -o bootstrap-tappaas.sh && chmod +x bootstrap-tappaas.sh
```

```bash
./bootstrap-tappaas.sh
```

Choose **6**, *install TAPPaaS on a rented server (Hetzner)*, and answer:

- the server's **address**, the **additional address** and its **virtual MAC**;
- your **admin email** and a **root password**;
- the **site's name** and size **small**.

The script then works on its own: it installs Proxmox from the rescue system, reboots the server
into it, and runs the TAPPaaS install. It makes your computer's WireGuard key on the way. It ends
with the console's address and writes your WireGuard file (`<site>.conf`) next to the script.

## 2. Connect

Import `<site>.conf` into the WireGuard app and turn the tunnel on. The console and the server are
reached only through it.

## 3. Day 1 in the console

Open the console's address and enter the access token. Then, as at home:

1. **Finish the first node's setup:** **This machine alone**; **Boot pool only** (or a pool on
   the second disk if the boot disks are not mirrored).
2. **Add more nodes:** **No more machines**.
3. **The admin VPN** is already done: your computer was enrolled by the install.
4. **Rest of foundation**, then **Status and health checks**.

Backup needs a place off the server: a backup buddy, or a second server later. Growing into a
cluster: [Multi node TAPPaaS cluster in Hetzner](CLUSTER-HETZNER.md).
