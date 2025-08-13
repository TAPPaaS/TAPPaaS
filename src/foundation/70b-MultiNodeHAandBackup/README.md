## Installing Proxmox Backup server on a multi node system  

# Introduction

This recipe should only be followed if you plan to have a multi node TAPPaaS system
if you plan to have a single node system then follow the recipe in [version a](../70a-SingleNodeBackup/README.md) 

We set up a secondary TAPPaaS node for HA and for AI and multimedia services. We configure HA for core services in foundation

In the multi node setup, we set up a dedicated Proxmox Backup Server (as opposed to a VM in the only node in a single node setup)

As with a single node system we configure the backup server with a dedicated backup disk and we register the backup server with pangolin to facilitate remote backup synchronization.

We also configure quorum server for the TAPPaaS PBS node.

See [Examples](../../../docs/Examples/README.md) for description of a 3 node TAPPaaS cluster

## Configure a secondary TAPPaaS node

1. ensure configuration file is updated
2. download a Proxmox VE iso installer image from: [Official Proxmox Download site](https://www.proxmox.com/en/downloads)
3. create a boot USB (on windows we recommend to use [Rufus](https://rufus.ie/en/), on Linux Mint right click on .iso and select make bootable usb stick)
4. boot the machine from the USB and do an install: use ZFS for the boot disk if you are having boot disk mirror.
5. once it is rebooted go to management console and create the "tanks" as zfs pools (minimum is to have a tanka1)
(if sufficient hw resources are available then use mirror on boot and tanka1)
6. run the TAPaaSPostPVEInstall.sh script in the proxmox node shell (via the proxmox management console):
```
curl -fsSL https://raw.githubusercontent.com/TAPPaaS/TAPPaaS/main/src/foundation/00-ProxmoxNodetstrap/TAPPaaSPostPVEInstall.sh | bash
```


## Hight Availability setup

## Proxmox Backup server (PBS) setup

## quorum

## Test setup

