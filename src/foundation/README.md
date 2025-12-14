
# TAPPaaS Foundation

The foundation modules are modules that must be installed for TAPPaaS to work. The more general modules of TAPPaaS rely on all of foundation is running.

The modules in Foundation should be installed and configured in the numbered order of the modules

1. Get the hyper visor installed on the first proxmox node [Proxmox](./00-ProxmoxNode/README.md)
2. Get a firewall installed and configured [OPNsense](./10-OPNsense/README.md)
3. Create a TAPPaaS NixOS VM template [tappaas-nixos](./20-tappaas-nixos/README.md)
4. Install the "mothership" that is the VM that will control the entire TAPPaaS system through it life [TAPPaaS-CICD](./30-tappaas-cicd/README.md)
5. Install secrets and identity management solution [Identity](./40-Identity/README.md)
6. Single Node: setup Proxmox backup: [Backup Single Node](./70a-SingleNodeBackup/README.md)
7. Multi node: Add additional proxmos nodes, configure hight availability and setup backup server [HA and Backup with Multi TAPPaaS nodes](./70b-MultiNodeHAandBackup/README.md)

As part of foundation there is a general configuration.json that will be installed locally in the tappass account on the cicd "mothership" VM under /root/tappaas/configuration.json
THe git repository has a "configuration.json.orig". copy it to configuration.json and edit the variable parts. This should be done as part of installing the first proxmox node
This file must be modified to reflect the local installation.