
# TAPPaaS Foundation

The foundation modules are modules that must be installed for TAPPaaS to work. The more general modules of TAPPaaS rely on all of these modules are installed and work

The modules in Foundation should be installed and configured in the numbered order of the module

- [Proxmox](./00-ProxmoxNode/README.md)
- [OPNsense basis](./10-OPNsense/README.md)
- [TAPPaaS-CICD](./15-TAPPaaS-CICD/README.md)
- [VLNA and Switching](./20-VLans/README)
- [Pangolin](./30-Pangolin/README.md)
- [Backup Single Node](./70a-SingleNodeBackup/README.md)
- [HA and Backup with Multi TAPPaaS nodes](./70b-MultiNodeHAandBackup/README.md)

Note that the basic Proxmox install include a TAPPaaS CICD VM, and to bootstrap we reference a prebuild VM. We also reference a prebuild OPNSense VM.

If you want to build these VMs from scratch then there is a description in [pre-bootstrap](./pre-bootstrap/README.md)