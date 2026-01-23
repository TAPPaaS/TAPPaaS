
# Proxmox node setup

## Overview

Note: PVE is an acronym for Proxmox Virtual Environment. what we are setting up in this README file is a PVE node, which we also call a TAPPaaS node. first node will have the name tappaas1

Bootstrapping TAPPaaS foundation has not been fully automated. However some steps are scripted.

You need to do the following activities (next sections give exact instructions)

1) **Prepare** the install
2) **Install** proxmox on the first TAPPaaS node
3) **PostInstall** TAPaaSPostPVEInstall.sh: Do basic household activities on Proxmox after initial install

continue with installing the [Firewall](../10-firewall/README.md) 
Then install proxmox on remaining TAPPaaS [nodes](../15-AdditionalPVE-Nodes/README.md)
followed by the rest of foundation, in number order.


## Prepare Proxmox install:

- prepare physical hardware. see [Examples](../../Documentation/Examples/README.md) or [Hardware](../../Documentation/Architecture/Hardware.md)
- ensure you designed your basic setup [Design](../../Documentation/Installation/README.md)
  - you have a domain name for the installation: <mytappaas.tld>
  - when the installer ask for a FQDM for the machine use: tappaas1.mgmt.internal  (do not use the external recognized domain for your installation, that is for the firewall)
    - if this is not the first node then replace the tappaas1 with the appropiate tappaas2,3,4, ...
    - Note that the current installation do not support a different name for the PVE nodes
  - The hardware is plugged into a local network with internet connection. you have a local IP number for the node (will later be changed when the firewall is installed)
  - You will be asked for a password for root. Select a strong password and remember it :-)
  - You will be asked for an email: Use an email that can be accessed by the administrator of the TAPPaaS installation
- download a Proxmox VE iso installer image from: [Official Proxmox Download site](https://www.proxmox.com/en/downloads)
- create a boot USB (on windows we recommend to use [Rufus](https://rufus.ie/en/), on Linux Mint right click on .iso and select make boot-able usb stick)

## Install Proxmox

- boot the machine from the USB and do an install: 
  - use ZFS for the boot disk if you are having boot disk mirror.
  - further info in [PVE instaler](./PVE-Installer.md) 

## Post Install

After reboot, log into the Proxmox GUI on the web address displayed on the console of the tappass maschine

When accessing the gui you likely need to accept that it is an unsecure connection. and after loging in as root do a page refresh to get rid of the subscription popup

Run the post install script (if you are not using the "main" branch for the install then then change the assignment in the first line):
```
BRANCH="main"
curl -fsSL https://raw.githubusercontent.com/TAPPaaS/TAPPaaS/$BRANCH/src/foundation/05-ProxmoxNode/install.sh >install-PVE.sh
chmod +x install-PVE.sh
./install-PVE.sh $BRANCH

```

## Creating or joining a cluster

If this is the first node then create the TAPPaaS cluster (even if you only run one machine in TAPPaaS you can create the cluster to make it ready for expansion)
In the console of tappaas1:

```bash
pvecm create TAPPaaS
```

If this is not the first node (and note that adding nodes after the first one should be done AFTER the firewall is configured)
Join the node to the TAPPaaS cluster:

- on the tappass1 node GUI: go to datacenter and click Cluster: click Join information, and copy information
- on the new tappaas node GUI: go to datacenter and click Cluster and then join cluster: paste information and enter root password for tappaas1
  - after you joined, you need to reload the tappaas2 web gui as it changes fingerprint for login after joining a cluster

## Add the storage tanks (that is adding data disks to the node configuration)

It is important to create the data "tanks" AFTER the cluster is created, or PVE will have problems recognizing them when joining the cluster (PVE bug?)

Create the "tanks" as zfs pools (normally, as a minimum, you will create a tanka1). 

- Use the GUI of the newly installed node
  - under the tappaas1 node in the datacenter panel go to the disk section. 
  - take note of the disks you have
  - In order to "reuse" a Hard disk (SSD or HDD), you might need to delete old partitions for zfs to accept it into a new pool
    - you can do that by selecting the disk and click on the "wipe" button
  - select add zfs under the zfs menu
    - select type of zfs redundancy (recomend is mirror for tanka1, and single disk for tankb1)
    - add the disk and click create
  - alternative you can create the pool from the command line. 
    - This gives the option to stripe disks together without reduancy (raid0), to create ssd disk cache (L2ARC) and log (ZIL)

## adjust the local copy of the configuration.json and vlan.json

The json is stored under /root/tappaas/configuration.json /root/tappaas/vlan.json

if this is the first node then modify it to reflect your local installation

If this is a secondary node then copy what you modified on tappaas1. On the new nodes console:
(note that if you have not modified the configuration.json, then the original github version will already be on the new node and this step can be skipped)

```bash
cd
scp tappaas1.mgmt.internal:/root/tappaas/configuration.json tappaas
scp tappaas1.mgmt.internal:/root/tappaas/zones.json tappaas
```

## Cleanup

if this is the fist node then proceed to firewall setup, where there is a reboot step after bridge reconfiguration
if this is not the first node, then reboot at this step.