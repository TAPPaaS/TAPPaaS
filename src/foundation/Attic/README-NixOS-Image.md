# TAPPaaS NixOS base image generation

The TAPPaasS base NixOS image can either be downloaded from a friend or generated on the tappaas1 node
This is a recipie for genrating it

It goes in the following steps

- set up an sudo user "tappaas" on the tappaas1 PVE node
- install Nix (not the OS but just the Nix environment) for the tappaas user
- instal the nixos-generate package
- download the TAPPaaS base configuration.nix file
- generate a proxmox virtual machine image (VMA)
- upload the image to the PVE node

## create a user and log in.

on the proxmox console do the command (give the user a sensible long password)

```
adduser --gecos "" tappaas
sudo adduser tappaas sudo
su - tappaas
```

## install Nix and the image generator package

As user tappaas do the following

```
sh <(curl --proto '=https' --tlsv1.2 -L https://nixos.org/nix/install) --no-daemon
nix-env -f https://github.com/nix-community/nixos-generators/archive/master.tar.gz -i
```

## download the TAPPaaS base configuration


```
curl -fsSL  https://raw.githubusercontent.com/TAPPaaS/TAPPaaS/main/src/foundation/00-ProxmoxNode/TAPPaaS-Base-NixOS.nix >TAPPaaS-Base-NixOS.nix
```

## generate an image

```
nixos-generate -f proxmox -c ./TAPPaaS-Base-NixOS.nix -o result
```

## store the image on tanka1

```
sudo mv result/iso/nixos*.iso /root/nixos-tappaas.iso
```