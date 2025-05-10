
# Bootstraping TAPaaS

This directory contains two scripts (and some helper scripts)

1) ProxmoxSetup: this do basic household activities on Proxmox after initial install
2) SelfManageSetup: this create and install a selfmanage VM with all the needed tooling

## how to bootstrap

Steps:

a) Build/buy/allocate a primary TAPaaS server according to minimum specs (see documentation)
b) download and create a bootable usb stick for Proxmox (TODO:insert link)
c) boot and install proxmox on server
d) go to gui of proxmox and configure tank1 and tank2
e) go to shell of proxmox and run the Proxmoxsetup script:
```
bash -c "$(curl -fsSL https>//raw/githubusercontent.com/larsrossen/TAPaaS/src/bootstrap/ProxmoxSetup.sh)"
```
f) after reboot check that it all looks fine!!
g) run the SelfmanageSetup script from the root console
```
bash -c "$(curl -fsSL https>//raw/githubusercontent.com/larsrossen/TAPaaS/src/bootstrap/SelfManageSetup.sh)"
```
h) go to the URL of selfmanage and continue from there.

TODO: describe firewall bootstrap

## what is done during bootstrap

### ProxmoxSetup.sh

Actions taken by script:
- check version
- check resources (tank1, tank 2, network, free space, ...)
- install repository sources and disable community warning
- ...

### SelfManageSetup.sh

Actions taken by script
- create a self manage VM based on unbuntu
- install docker on VM
- install Gitea in docker
- configure Gitea with a clone of TAPaaS
- install Ansible and needed dependencies and modules
- install teraform and needed dependencies and modules
- Configure Gitea runners for TAPaaS
- Sanity check

