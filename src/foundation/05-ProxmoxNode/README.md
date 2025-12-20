
# Proxmox node setup

## Overview


Bootstrapping TAPPaaS foundation has not been fully automated. However some steps are scripted.

you need to do the following activities (next sections give exact instructions)

1) **Prepare** the install
2) **Install** proxmox on the first TAPPaaS node
3) **PostInstall** TAPaaSPostPVEInstall.sh: Do basic household activities on Proxmox after initial install

continue with installing the [Firewall](../10-firewall/README.md) 
Then install proxmox on remaining TAPPaaS [nodes](../15-AdditionalPVE-Nodes/README.md)
followed by the rest of foundation, in number order.


## Prepare Proxmox install:

- prepare physical hardware. see [Examples](../../Documentation/Examples/README.md) or [Hardware](../../Documentation/Architecture/Hardware.md)
- ensure you designed your basic setup [Design](../../Documentation/Installation/README.md)
  - you have a domain name for the installation: <mytappaas.net>
  - The hardware is plugged into a local network with internet connection. you have a local IP number for the node (will later be changed when the firewall is installed)
  - You will be asked for a password for root. Select a strong password and remember it :-)
- download a Proxmox VE iso installer image from: [Official Proxmox Download site](https://www.proxmox.com/en/downloads)
- create a boot USB (on windows we recommend to use [Rufus](https://rufus.ie/en/), on Linux Mint right click on .iso and select make bootable usb stick)

## Install Proxmox

- boot the machine from the USB and do an install: use ZFS for the boot disk if you are having boot disk mirror.
- once it is rebooted go to management console and create the "tanks" as zfs pools (minimum is to have a tanka1). further info in [pools](./Proxmox-VE-Installer.md)
(if sufficient hw resources are available then use mirror on boot and tanka1)

## Post Install

- run post install script
```
curl -fsSL https://raw.githubusercontent.com/TAPPaaS/TAPPaaS/main/src/foundation/00-ProxmoxNode/install.sh | bash
```


Now after reboot:
- check that it all looks fine!! (TODO automate check setup)
- Edit the /root/tappaas/configuration.json to reflect choices in this install.

and finally convert the PVE DAtacenter into a 'TAPPaaS' cluster (with only one node initially)
```
pvecm create TAPPaaS
pvecm status
```


