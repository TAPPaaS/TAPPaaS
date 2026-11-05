# Installing TAPPaaS

The install turns one or more machines into a TAPPaaS site. Each machine gets Proxmox VE, and
the first one gets the TAPPaaS foundation on top: an OPNsense firewall that becomes the site's
gateway, the management VM that owns the platform (tappaas-cicd), and its web console. From the
console's Day 1 page you finish the rest: the machines' network ports and disks, more machines,
your admin VPN, then sign-in, logging and backup, and a check that it all works. Applications,
going public, switches and Wi-Fi come after, as Day 2 operations. A first machine starts from a
Mac or Linux PC with one script that builds the installer, boots the machine from it and follows
the install to the end.

## Choose how to install

| Option | Purpose | Status |
|--------|---------|--------|
| [Single node local TAPPaaS system](INSTALL/SINGLE-NODE-LOCAL.md) | Test TAPPaaS | Ready |
| [Single node TAPPaaS system in Hetzner](INSTALL/SINGLE-NODE-HETZNER.md) | Test TAPPaaS | In development, not ready |
| [Multi node local TAPPaaS cluster](INSTALL/CLUSTER-LOCAL.md) | Staging or production cluster | Ready |
| [Multi node TAPPaaS cluster in Hetzner](INSTALL/CLUSTER-HETZNER.md) | Staging or production cluster | In development, not ready |

A single node system can grow: more machines, disks and switches are added from the console
later.
