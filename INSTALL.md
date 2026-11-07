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

| | Local | Cloud (Hetzner) |
|---|---|---|
| **Single node test system** | [Single node local TAPPaaS system](INSTALL/SINGLE-NODE-LOCAL.md) | [Single node TAPPaaS system in Hetzner](INSTALL/SINGLE-NODE-HETZNER.md) *(in development)* |
| **Multi node production cluster** | [Multi node local TAPPaaS cluster](INSTALL/CLUSTER-LOCAL.md) | [Multi node TAPPaaS cluster in Hetzner](INSTALL/CLUSTER-HETZNER.md) *(in development)* |

A single node system can grow into a cluster: more machines, disks and switches are added from
the console later.

## Appendices

The guides above are kept short. The appendices hold the detail behind them:

- [Appendix A — Install from a Windows PC](INSTALL/WINDOWS.md)
- [Appendix B — Hardware selection](INSTALL/HARDWARE.md)
- [Appendix C — Adding a satellite](INSTALL/SATELLITE.md)
- [Appendix D — Preparation](INSTALL/PREPARATION.md)
- [Appendix E — The foundation install in detail](INSTALL/FOUNDATION.md)
- [Appendix F — Environments](INSTALL/ENVIRONMENTS.md)
- [Appendix G — Servers in Hetzner](INSTALL/HETZNER.md)
- [Appendix H — The install from the command line](src/foundation/INSTALL.md)
