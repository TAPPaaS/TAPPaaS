# TAPPaaS Foundation

The foundation modules must all be installed and running for the rest of TAPPaaS to work. Modules are **named, not numbered** — install order is derived from each module's `dependsOn`, not a numeric prefix. See the [Installation guide](https://tappaas.org/installation/).

## Modules

| Module | Contents |
|--------|----------|
| [cluster/](cluster/README.md) | Proxmox node setup and adding cluster nodes. |
| [network/](network/README.md) | OPNsense firewall, network zones, and DNS. |
| [templates/](templates/README.md) | NixOS (and Windows) VM template creation. |
| [tappaas-cicd/](tappaas-cicd/README.md) | The "mothership" VM that controls the entire TAPPaaS system (managers and controllers). |
| [backup/](backup/README.md) | Proxmox Backup Server. |
| [identity/](identity/README.md) | Secrets and identity management. |
| [logging/](logging/README.md) | Centralized logging. |
| [satellite/](satellite/README.md) | Optional off-premises VPS for public ingress and off-site backup (ADR-010). |

## Reference files

| Path | Contents |
|------|----------|
| [schemas/](schemas/README.md) | JSON schemas for module configuration and related definitions. |
| [DEPENDENCIES.md](DEPENDENCIES.md) / [DEPENDENCIES.csv](DEPENDENCIES.csv) | Generated script/command dependency documentation. |
| [PROGRAMS.csv](PROGRAMS.csv) | Generated inventory of programs used across foundation. |
| [TESTING.md](TESTING.md) | How to test foundation modules. |
| [install.sh](install.sh) / [uninstall.sh](uninstall.sh) | Install / uninstall the full foundation layer. |
| [Deprecated/](Deprecated/) | Retired modules kept for reference. |
