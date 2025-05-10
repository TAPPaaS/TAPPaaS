
This directory contains two scripts (and some helper scripts)

1) ProxmoxSetup: this do basic household activities on Proxmox after initial install
2) SelfManageSetup: this create and install a selfmanage VM with all the needed tooling

### how to bootstrap

Steps:

a) Build/buy/allocate a primary TAPaaS server according to minimum specs (see documentation)
b) download and create a bootable usb stick for Proxmox (TODO:insert link)
c) boot and install proxmox on server
d) go to gui of proxmox and configure tank1 and tank2
e) go to shell of proxmox and run the Proxmoxsetup script:
    - curl 

f) check that it all looks fine!!
g) run the Selfmanagesetup script
h) go to the URL of selfmanage and continue from there.

