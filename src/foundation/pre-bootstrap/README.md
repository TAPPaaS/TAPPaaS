# preparation before creating TAPPaaS Foundation

The TAPPaaS foundation stands up the hypervisor (proxmox), the TAPPaaS CICD VM and the Firewall.
Following this Foundation stand up reverse proxy (Pangolin) and Secrets management

In order to do this there is a need to download 3 images:
- First one if Proxmox itself. The image is downloaded from Proxmox. Description is in [00-Proxmox](../00-ProxmoxNode/README.md)
- Second is a proxmox image that contains a minimal OPNsense. This is provided by TAPPaaS
- Third is a proxmox VM image that contains a minimal TAPPaaS CICD NixOS. This is provided by TAPPaaS

In this folder we describe and script how to create the later two VM images.
This ensure you can recreate TAPPaaS from source, even if you do not have access to the VM images

Creating the OPNsense VM is described in [](./OPnSense-VM.md)

Creating the TAPPaaS-CICD VM is in [](./TAPPaaS-CICD-NixOS-VM.md)