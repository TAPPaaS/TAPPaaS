
# Proxmox node and TAPPaaS CICD setup

## Overview


Bootstrapping TAPPaaS has not been fully automated. However some steps are scripted.

you need to do the following activities (next sections give exact instructions)

1) Install proxmox on the first TAPPaaS node
2) TAPaaSPostPVEInstall.sh: Do basic household activities on Proxmox after initial install
3) TAPaaSBootstrap.sh: this create and install a self management VM (called TAPPaaS-CICD) with all the needed tooling
4) TAPPaaS-CICD-bootstrap.sh: a script to be run inside the CICD VM
It you configuration have more than one node then you need to do sept 1 and 2 on the other nodes and join them into a cluster. (TODO: instructions for clustering)

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
curl -fsSL https://raw.githubusercontent.com/TAPPaaS/TAPPaaS/main/src/boofoundation/00-ProxmoxNodetstrap/TAPPaaSPostPVEInstall.sh | bash
```

- after reboot check that it all looks fine!!
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
  - add ssh keys to your github: copy and paste the output of cat ~/.ssh/id_ed25519.pub (not needed when TAPPaaS is public)
  - test that the key authentication works: ssh -T git@github.com
    - it will ask if if you want to continue connecting: answer yes
    - it will hopefully then state that you authenticated but that github does not provide shell access. That is OK

### Clone TAPPaaS to you CICD VM, and complete the bootstrap

  - clone the TAPPaaS repository: git clone git@github.com:TAPPaaS/TAPPaaS.git
  - run the final bootstrap code: ./TAPPaaS/src/bootstrap/TAPPaaS-CICD-bootstrap.sh
  - set the git user name (from the tappaas-cicd command prompt): git config --global user.name <your name> 
  - set the git user email: git config --global user.email <your email>
- Also add the ssh key to the proxmox root account.
  - copy the output of : cat ~ /.ssh/id_ed25519.pub
  - go to the shell of the root account on the proxmox server node and append it to the authorized keys: cat >> authorized_keys
  - presse enter and paste the key, end with ctrl-D
  - test that you can ssh to root@<ip of proxmox server> from the tappaas@tappaas-cicd vm account

Set up a coding environment connected to the CICD: see [Visual Code Remote Development](./VC-RemoteDev.md)

Next you need to set up tokens for Opentofu (terraform)
- in proxmox menu: Datacenter->Permission->API tokens: add a token with id: tappaas-token associated with root@pam
  - make sure the "Privilege Separation" is unchecked (or do setup/add needed permission for terraform )
- copy the token and write it into a file : cat >.ssh/tappaas-token
- make the file read/write for owner only: chmod 600 .ssh/tappaas-token

