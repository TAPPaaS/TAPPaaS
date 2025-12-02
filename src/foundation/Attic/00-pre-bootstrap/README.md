# preparation before creating TAPPaaS Foundation


## Introduction

The TAPPaaS foundation stands up the hypervisor (proxmox), the TAPPaaS CICD VM and the Firewall.
Following this Foundation stand up reverse proxy (Pangolin) and Secrets management

In order to do this there is a need to download 3 images:
- First one if Proxmox itself. The image is downloaded from Proxmox. Description is in [00-Proxmox](../00-ProxmoxNode/README.md)
- Second is a proxmox image that contains a minimal OPNsense. This is provided by TAPPaaS
--How to create this Image is described in [OPNsense](../10-OPNsense/README.md)
- Third is a proxmox VM image that contains a minimal TAPPaaS CICD NixOS. This is provided by TAPPaaS

In this folder we describe and script how to create the later last VM images.
This ensure you can recreate TAPPaaS from source, even if you do not have access to the VM images

## generating a TAPPaaS-CICD VM

- On a bare bone proxmox system install a NixOS
- on the NixOS VM configure a NixOS generator
- using said generator create TAPPaaS VM image

### details

- Download the minimum NixOS ISO image from : https://nixos.org/download/
- Upload the iso to proxmox
- Create a VM under proxmox: 4G memory, two cores, 32G disk, attach the iso
- boot the system and do a basic NixOS install
  - as part of the initial setup you register a user name and password. Note this NixOS is temporary so this account is only used during the generation of the tappaas-cicd image

In the console do the following
```
nixos-generate-config
cd /etc/nixos
# edit configuration to add options if needed
nixos-rebuild switch
ip a
```

the IP command gives you the IP number and from a terminal you can ssh into this IP.
This way you can use cut and paste commands in the ssh terminal
Add the following code to the config file /etc/nixos/configuration.nix

```
# nothing to add
```
 now install the nixos generator:

```
nix-env -f https://github.com/nix-community/nixos-generators/archive/master.tar.gz -i
cd
```

fetch the TAPPaaS-CICD configuraiton file

```
curl -fsSL  https://raw.githubusercontent.com/TAPPaaS/TAPPaaS/main/src/foundation/15-TAPPaaS-CICD/TAPPaaS-CICD.nix  >TAPPaaS-CICD.nix
curl -fsSL  https://raw.githubusercontent.com/TAPPaaS/TAPPaaS/main/src/foundation/15-TAPPaaS-CICD/TAPPaaS-Base.nix  >TAPPaaS-Base.nix
nixos-generate -f proxmox -o ./TAPPaaS-CICD -c ./TAPPaaS-CICD.nix
```

now save/upload the TAPPaaS/vzdump-qemu-tappaas-cicd.vma.zst to some cloud storage that can be accessed by the tappaas installers 

as a shortcut, copy the image to the root account of the proxmox account using the "scp" command from the proxmox console
```
scp <username>@<IP of nixos vm>:TAPPaaS-NixOS/vzdump-qemu-tappaas-cicd.vma.zst .
```

## test image

from a proxmox console download the image (you can scp from the NixOS VM) then do the following restore command:

```
unzstd vzdump*.vma.zst
qmrestore vzdump*.vma 345 --storage local-zfs
```
