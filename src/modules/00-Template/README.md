# Template module configuration

a standard module will:

- Create a VM based on a clone of a NixOS base system. 
  - This is driven by the <template>.json
  - the same methog can be used for generic iso or img type os VMs
- Reconfigure the cloned or installed VM

The "install.sh" must be present and will be called by Tappaas-cicd at install time
The "update.sh" must also be present, it will be called at regular intervals to update/patch a runnnig installation
The template.json (rename to be the <vmname>.json)
The template.nix (rename to <vmname>.nix) is the configuration of the Nixos (if the VM is NixOS based): TODO change to flake structure

The .json have the following parameter

-    "version": Must be present. 
    "vmid": unique across the tappaas nodes. Must be present
    "vmtag": proxmox tags. Default is "TAPPaaS", must be a comma seperate list, no spaces
    "hostname": the name of the VM, also the name of the module and the hostname of the OS. Must be present
    "cores": Defaults to 2
    "memory": Defaults to 4096
    "diskSize": Defaults to 16G
    "storage": "Defaults to tanka1"
    "imageType": Defaults to "clone" but can also be "iso" or "img"
    "image": "Mandatory: if Clone then it is the VMID of the proxmox template to clone. otherwise it is the name of the image/iso file
    "imageLocation": mandatory if iso or img imagetype
    "bridge0": default to "lan"
    "bridge1": if present then a second network card is configured.
    "vlantag": vlan 0 means management lan.
    "bios": default is "ovmf"
    "ostype": default is "l26"
    "description": descriptive text that will end up in the proxmox summary  page for the VM  
}