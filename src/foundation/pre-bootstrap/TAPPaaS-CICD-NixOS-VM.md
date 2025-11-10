# generating a TAPPaaS-CICD VM

## Introduction

On a bare bone proxmox system install a NixOS
on the NixOS VM configure a NixOS generator
using said generator create TAPPaaS VM image

##

- Download the minimum NixOS ISO image from : https://nixos.org/download/
- Upload the iso to proxmox
- Create a VM under proxmox: 4G memory, two cores, 32G disk, attach the iso
- boot the system and do a basic NixOS install

In the console do the following
```
nixos-generate-config
cd /etc/nixos
# edit configuration to add options if needed
nixos-rebuild switch
ip a
```

the IP command gives you the IP number and from a terminal you can ssh into this IP.
This way you can use cut and pase commands in the ssh terminal
Add the following code to the config file in /etc/nixos

```

```
 now run the commands

```
nix-env -f https://github.com/nix-community/nixos-generators/archive/master.tar.gz -i
cd
```

```
curl -fsSL  https://raw.githubusercontent.com/TAPPaaS/TAPPaaS/main/src/foundation/00-ProxmoxNode/TAPPaaS-Base-NixOS.nix  >TAPPaaS-Base-NixOS.nix
nixos-generate -f proxmox -o ./TAPPaaS-NixOS -c ./TAPPaaS-Base-NixOS.nix
```

