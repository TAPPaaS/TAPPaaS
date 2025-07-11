
# Bootstrapping TAPPaaS

## Overview

Bootstrapping TAPPaaS has not been fully automated. However some steps are scripted.

you need to do the following activities (next sections give exact instructions)

1) Install proxmox on the first TAPPaaS node
2) TAPaaSPostPVEInstall.sh: Do basic household activities on Proxmox after initial install
3) TAPaaSBootstrap.sh: this create and install a self management VM (called TAPPaaS-CICD) with all the needed tooling
4) TAPPaaS-CICD-bootstrap.sh: a script to be run inside the CICD VM
It you configuration have more than one node then you need to do sept 1 and 2 on the other nodes and join them into a cluster. (TODO: instructions for clustering)
5) install and configure the firewall
6) Rewire the network replacing exiting firewall with new firewall and reconfigure IP number of first TAPPaaS node.

After initial 3 stems of bootstrapping then all management is done inside the TAPPaaS-CICD VM

## how to bootstrap

### Proxmox install:

- prepare physical hardware. see [Examples](../../Documentation/Examples/README.md) or [Hardware](../../Documentation/Architecture/Hardware.md)
- ensure you designed your basic setup [Design](../../Documentation/Installation/README.md)
- download a Proxmox VE iso installer image from: [Official Proxmox Download site](https://www.proxmox.com/en/downloads)
- create a boot USB (on windows we recommend to use [Rufus](https://rufus.ie/en/))
- boot the machine from the USB and do an install: use ZFS for the boot disk.
- once it is rebooted go to management console and create the "tanks" as zfs pools (minimum is to have a tanka1)
(if sufficient hw resources are available then use mirror on boot and tanka1)
- run the TAPaaSPostPVEInstall.sh script in the proxmox node shell (via the proxmox management console):
```
GITTOKEN=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
curl -fsSL -H "Authorization:token $GITTOKEN" https://raw.githubusercontent.com/TAPpaas/TAPpaas/main/src/bootstrap/TAPPaaSPostPVEInstall.sh | bash
```
(note the -H token stuff is only needed as long as the script is in a private repository, the token gives read access)

- after reboot check that it all looks fine!!
- run the TAPaaSBootstrap script from the root console
```
GITTOKEN=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
curl -fsSL -H "Authorization:token $GITTOKEN" https://raw.githubusercontent.com/TAPpaas/TAPpaas/main/src/bootstrap/TAPPaaSBootstrap.sh | bash
```
You should now have a PVE node with a TAPPaaS template and a TAPPaaS CICD VM

### TAPPaaS CICD bootstrap

Setting up the CICD toolchain and git repository. This is done in the TAPPaaS-CICD VM

The only way to access the VM is through ssh from the proxmox node console.

You need the IP of the VM: look it up in the summary of the TAPPaaS CICD VM in the proxmox gui

Now Do:

- Log into TAPPaaS CICD VM using ssh from a host terminal: ssh tappaas@<insert ip of CICD VM>
  - look at the summary page for the tappaas-cicd vm in the PVE portal. 
  - or do the command "qm guest cmd 100 network-get-interfaces"
- In the shell of the TAPPaaS CICD VM do:
  - create ssh keys: ssh-keygen -t ed25519
  - add ssh keys to your github: copy and paste the output of cat ~/.ssh/id_ed25519.pub (not needed when TAPPaaS is public)
  - test that the key authentication works: ssh -T git@github.com
  - clone the TAPPaaS repository: git clone git@github.com:TAPpaas/TAPpaas.git
  - run the final bootstrap code: ./TAPpaas/src/bootstrap/TAPPaaS-CICD-bootstrap.sh
  - set the git user name: git config --global user.name <your name> 
  - set the git user email: git config --global user.email <your email>

### Intermediate step:

Set up a coding environment connected to the CICD

- Install Visual code on your personal developer machine (MacOS, Linux, Windows)
- Install the Visual Code Remote Development extension pack (search in VC and install in VC)
- ensure you have ssh installed on your development machine and you have keys generated
- upload keys to the tapas@tapas-cicd VM users, authorized keys.
- test that you can ssh into tappaas@tappaas-cicd from the development machine
you can now connect to the CICD VM using the connection bottom in the lower left corner of VC

Next you need to set up tokens for Opentofu (terraform)
- in proxmox menu: Datacenter->Permission->API tokens: add a token with id: tappaas-token associated with root@pam
  - make sure the "Privilege Separation" is unchecked (or do setup/add needed permission for terraform )
- copy the token and write it into a file : cat >.ssh/tappaas-token
- make the file read/write for owner only: chmod 600 .ssh/tappaas-token

### Post bootstrap activities


You will need to do the Network module first which include setting up firewall, and vlans as well as wifi
This is described in [Network Setup](../modules/Network/README.md)

second module is the [DMZ](../modules/DMZ/README.md)

Now add any other module you think would be relevant to your TAPPaaS instance

