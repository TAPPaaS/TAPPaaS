# Install a multi node TAPPaaS cluster in Hetzner

*In development, not ready: this is how it will work. Until then, use a
[local cluster](CLUSTER-LOCAL.md).*

Two or more rented dedicated servers in one cluster, joined by Hetzner's **vSwitch**, the
private network between servers. The firewall is a VM like at home and moves between the servers
when one fails. Its public address comes from a **public subnet on the vSwitch**, so it works on
whichever server the firewall runs on. A small Hetzner cloud server gives the cluster its third
vote. What to order and where: [Appendix G](HETZNER.md).

## 1. Order

- Two (or more) **dedicated servers** in the same location, each of at least 32 GB of memory and
  two equal NVMe disks; size by [Appendix B](HARDWARE.md).
- A **vSwitch** with both servers in it, and a **public IPv4 subnet** (/29 or larger) on the
  vSwitch.
- A small **cloud server** (Debian) as the cluster's tie-breaker, in a cloud network coupled to
  the vSwitch.
- **Rescue mode** activated on each server with your SSH key.

## 2. Install the first server

As in the [single node guide](SINGLE-NODE-HETZNER.md), choosing the vSwitch subnet for the
firewall's address instead of an additional IP. Size **medium** or **large**.

Already running a single node on an additional IP? Then order the vSwitch and its subnet, and move
the firewall to the subnet from the console: the site's public address changes once, and your
DNS records and VPN endpoint with it.

## 3. Add the second server

Run `./bootstrap-tappaas.sh` again, choose **6**, and give the second server's address with the
site to join. It installs Proxmox from that server's rescue system and the console's **Add more
nodes** step joins it: the site's own networks cross the vSwitch, and the cluster runs over it.

## 4. Add the tie-breaker

Make the cloud server the cluster's **QDevice**: two servers plus it keep the cluster running
when either server stops. On the management VM:

```bash
qdevice.sh add <the cloud server's address>
```

A [satellite](SATELLITE.md) can be the QDevice too. With three or more servers it can be removed
(`qdevice.sh remove`).

## 5. Day 1 and Day 2

As for a [local cluster](CLUSTER-LOCAL.md#4-day-1-in-the-console): a data pool on each server,
backup on the other server, then HA for the guests, the firewall among them. Take the backup
keys off the site, then make it public: the site has a public address already.
