
# TAPPaaS Foundation

The foundation modules are modules that must be installed for TAPPaaS to work. The more general modules of TAPPaaS rely on all of foundation is running.

The modules in Foundation should be installed and configured in the numbered order of the modules

1. Get the hyper visor installed on the first proxmox node [Proxmox](./05-ProxmoxNode/README.md)
2. Get a firewall installed and configured [Firewall](./10-firewall/README.md)
3. Add additional nodes to the cluster [Add Nodes](./15-AdditionalPVE-Nodes/README.md)
4. Create a TAPPaaS NixOS VM template [tappaas-nixos](./20-tappaas-nixos/README.md)
5. Install the "mothership" that is the VM that will control the entire TAPPaaS system through it life [TAPPaaS-CICD](./30-tappaas-cicd/README.md)
6. Install the Proxmox Backup software [PBS](./35-pbs/README.md)
7. Install secrets and identity management solution [Identity](./40-Identity/README.md)

As part of foundation there is a general configuration.json that will be installed locally in the tappass account on the cicd "mothership" VM under /root/tappaas/configuration.json
THe git repository has a "configuration.json.orig". copy it to configuration.json and edit the variable parts. This should be done as part of installing the first proxmox node
This file must be modified to reflect the local installation.
