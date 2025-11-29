
# TAPPaaS CICD setup

## Introduction

Setup runs in these macro steps:

- set up a minimal NixOS with cloud-init support 
- convert/create a NixOS template from this
- create a tappaas-cicd VM based on the template 
- update the tappaas-cicd with the git clon and rebuild with right nixos configuration

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
mkdir bin
curl -fsSL  https://raw.githubusercontent.com/TAPPaaS/TAPPaaS/main/src/foundation/15-TAPPaaS-CICD/CloneTAPPaaSNixOS.sh >~/bin/CloneTAPPaaSNixOS.sh
chmod 744 bin/CloneTAPPaaSNixOS.sh
bin/CloneTAPPaaSNixOS.sh 101 tappaas-cicd 4 16G 32G "The TAPPaaS mothership VM"
```

ssh into vm and
- clone the git repository
- rebuild the nixos for tappaas cicd
- create ssh keys for tappass@tappass-cicd



# Old Setup

This setup assume that there is a bootstrap NixOS based TAPPaaS CICD backup image

from a proxmox console download the image (you can scp from the NixOS VM) then do the following restore command:

```
unzstd vzdump*.vma.zst
qmrestore vzdump*.vma 100 --storage local-zfs
qm set 100 --tag TAPPaaS,foundation
qm start 100
```

Test that it work by looking at the proxmox gui and then
logging into the tappaas-cicd frmo the root console of tappaas1 node:
```
ssh tappaas@tappaas-cicd
```

from the logged in account run the follwong setup


# setup ssh keys for tappaas user




# Old  Old setup Ignore

- run the TAPaaSBootstrap script from the root console
```
curl -fsSL  https://raw.githubusercontent.com/TAPPaaS/TAPPaaS/main/src/foundation/00-ProxmoxNode/TAPPaaSBootstrap.sh | bash
```
You should now have a PVE node with a TAPPaaS template and a TAPPaaS CICD VM

### TAPPaaS CICD bootstrap

Setting up the CICD toolchain and git repository. This is done in the TAPPaaS-CICD VM

The only way to access the VM is through ssh from the proxmox node console.

You need the IP of the VM: look it up in the summary of the TAPPaaS CICD VM in the proxmox gui

Now Do:

- Log into TAPPaaS CICD VM using ssh from a host terminal: ssh tappaas@<insert ip of CICD VM>
- In the shell of the TAPPaaS CICD VM do:
  - create ssh keys: ssh-keygen -t ed25519
  - add ssh keys to your github: copy and paste the output of cat ~/.ssh/id_ed25519.pub
  - test that the key authentication works: ssh -T git@github.com
    - it will ask if if you want to continue connecting: answer yes
    - it will hopefully then state that you authenticated but that github does not provide shell access. That is OK

### Clone TAPPaaS to you CICD VM, and complete the bootstrap

  - clone the TAPPaaS repository: 
  ```
  git clone git@github.com:TAPPaaS/TAPPaaS.git
  ```
  - run the final bootstrap code: 
  ```
  ./TAPPaaS/src/foundation/00-ProxmoxNode/TAPPaaS-CICD-bootstrap.sh
  ```
  - set the git user name (from the tappaas-cicd command prompt): git config --global user.name <your name> 
  - set the git user email: git config --global user.email <your email>
- Also add the ssh key to the proxmox root account.
  - copy the output of : cat ~/.ssh/id_ed25519.pub
  - go to the shell of the root account on the proxmox server node and append it to the authorized keys: cat >> authorized_keys
  - press enter and paste the key, end with ctrl-D
  - test that you can ssh to root@<ip of proxmox server> from the tappaas@tappaas-cicd vm account

Set up a coding environment connected to the CICD: see [Visual Code Remote Development](./VC-RemoteDev.md)

Next you need to set up tokens for Opentofu (terraform)
- in proxmox menu: Datacenter->Permission->API tokens: add a token with id: tappaas-token associated with root@pam
  - make sure the "Privilege Separation" is unchecked (or do setup/add needed permission for terraform )
- copy the token and write it into a file : cat >.ssh/tappaas-token
- make the file read/write for owner only: chmod 600 .ssh/tappaas-token

