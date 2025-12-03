# TAPPaaS CICD setup

## Introduction

Setup runs in these macro steps:

- set up a minimal NixOS with cloud-init support 
- convert/create a NixOS template from this
- create a tappaas-cicd VM based on the template 
- update the tappaas-cicd with the git clone and rebuild with right nixos configuration
- configure/install tappaas-cicd tools and pipelines

## Create a minimum NixOS

run the following script as root from the proxmox console

```
sudo curl -fsSL  https://raw.githubusercontent.com/TAPPaaS/TAPPaaS/main/src/foundation/15-TAPPaaS-CICD/CreateTAPPaaSNixOS-VM.sh  | bash

```

in the console of VM 8080 set install nixos
  - use the username "tappaas", give it a strong password, preferably the same as root on the tappass1 node. same password for root
  - do not select a graphical desktop
  - allow use of unfree software
  - select erase disk and no swap in disk partition menu
  - start the install it will take some time and likely look stalled at 46% for many minutes, toggle log to see detailed progress
  - finish the install but do NOT reboot

stop the system, detach the iso in the proxmox console and reboot VM

In the console of the VM do the following

```
sudo curl -fsSL  https://raw.githubusercontent.com/TAPPaaS/TAPPaaS/main/src/foundation/15-TAPPaaS-CICD/TAPPaaS-Base.nix  >TAPPaaS-Base.nix
sudo cp TAPPAaS-Base.nix /etc/nixos/configuration.nix
sudo nixos-rebuild switch

```

## Convert to template

reboot the VM and test it still work
then from the Proxmox tappaas1 console do a template generation from the VM. 
```
qm stop 8080
qm template 8080
```
or do it from the proxmox gui


## create tappaas-cicd

Install cloning script: on the proxmox command prompt, then run the command to create the tappaas-cicd clone
```
cd
mkdir tappaas
apt install jq
curl -fsSL  https://raw.githubusercontent.com/TAPPaaS/TAPPaaS/main/src/foundation/15-TAPPaaS-CICD/CloneTAPPaaSNixOS.sh >~/tappaas/CloneTAPPaaSNixOS.sh
curl -fsSL  https://raw.githubusercontent.com/TAPPaaS/TAPPaaS/main/src/foundation/15-TAPPaaS-CICD/tappaas-cicd.json >~/tappaas/tappaas-cicd.json
chmod 744 ~/tappaas/CloneTAPPaaSNixOS.sh
~/tappaas/CloneTAPPaaSNixOS.sh tappaas-cicd
```

There should now be a running tappaas-cicd VM.
on the tappaas-cicd console do:
```
curl -fsSL  https://raw.githubusercontent.com/TAPPaaS/TAPPaaS/main/src/foundation/15-TAPPaaS-CICD/install.sh | bash
```

