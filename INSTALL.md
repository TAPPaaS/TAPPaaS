# Installing TAPPaaS

The install turns one or more machines into a TAPPaaS site. Each machine gets Proxmox VE, and
the first one gets the TAPPaaS foundation. Foundation consist of a network (firewall) module, an Identity module, a backup module, a logging module, and very importantly a tappaas-cicd module that controls the entire TAPPaaS installation. The later has a command line interface and a web interface called "The Console"

The installation runs in 3 major phases:
1) bootstrap: getting the first node of the TAPPaaS site installed up to the point of have "The Console"
2) Finish foundation: get the rest of the foundations and the rest of the nodes and the VPN access setup using wizards in the in web Console
3) add features and applications

Step 3 is can be done at a later stage as "day 2" activities from the console

Details on how to do this can be found in the 4 guides in the table

## Choose what to install

| | Local | Cloud (Hetzner) |
|---|---|---|
| **Single node test system** | [Single node local TAPPaaS system](docs/install/SINGLE-NODE-LOCAL.md) | [Single node TAPPaaS system in Hetzner](docs/install/SINGLE-NODE-HETZNER.md) *(in development)* |
| **Multi node production cluster** | [Multi node local TAPPaaS cluster](docs/install/CLUSTER-LOCAL.md) | [Multi node TAPPaaS cluster in Hetzner](docs/install/CLUSTER-HETZNER.md) *(in development)* |

A single node system can grow into a cluster: more machines, disks and switches are added from
the console later.

## Appendices

The guides above are kept short. The appendices hold the detail behind them:

- [Appendix A — Install from a Windows PC](docs/install/WINDOWS.md)
- [Appendix B — Hardware selection](docs/install/HARDWARE.md)
- [Appendix C — Adding a satellite](docs/install/SATELLITE.md)
- [Appendix D — Preparation](docs/install/PREPARATION.md)
- [Appendix E — The foundation install in detail](docs/install/FOUNDATION.md)
- [Appendix F — Environments](docs/install/ENVIRONMENTS.md)
- [Appendix G — Servers in Hetzner](docs/install/HETZNER.md)
- [Appendix H — The install from the command line](src/foundation/INSTALL.md)
