# TAPPaaS NixOS setup

## Introduction

Setup runs in these macro steps:

- set up a minimal NixOS with cloud-init support 
- convert/create a NixOS template from this

## Create a minimum NixOS

run the following script as root from the proxmox console

```
curl -fsSL  https://raw.githubusercontent.com/TAPPaaS/TAPPaaS/main/src/foundation/20-tappaas-nixos/tappaas-nixos.json >~/tappaas/tappaas-nixos.json
~/tappaas/Create-TAPPaaS-VM.sh tappaas-nixos
```

in the console of VM 8080 install nixos
  - use the username "tappaas", give it a strong password, preferably same pwd as root on the tappaas node.
  - for graphical desktop select: no desktop
  - allow use of unfree software
  - select erase disk and no swap in disk partition menu
  - keep 'encrypt disk' unselected
  - review summary and select install on lower right side (maximize window)
  - start the install it will take some time
    - it may appear to be stalled at 46% for minutes - be patient!
    - toggle log to see detailed progress
  - finish the install but do NOT reboot

stop the system, detach the iso in the proxmox console and reboot VM

In the console of the VM do the following (and sorry, nixos do not support cut and paste and ssh ot of the box, so some typing is required)

```
sudo curl -fsSL  https://raw.githubusercontent.com/TAPPaaS/TAPPaaS/main/src/foundation/20-tappaas-nixos/tappaas-nixos.nix  >tappaas-nixos.nix
sudo cp tappaas-nixos.nix /etc/nixos/configuration.nix
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


