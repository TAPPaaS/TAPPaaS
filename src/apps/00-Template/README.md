# Template module configuration

## Introduction

This is a template module that can be used as a starting point for creating a new TAPPaaS module

## Steps

Decide on a name for the module. typically the name of the main SW product in the module or the main capability the module is delivering.
As default in TAPPaaS the module name will also be the VM name that the module wil run in, and the host name for the running OS and DHCP, DNS name.

Copy the entire 00-Tempalte directory and its content to a new directory with the chosen <myModule> as the name.
(in the commands below replace "myModule" with the name of your module)
```
cp -r 00-Template myModule
```

remove the copy of this file and replace it with the README-template.md. rename the json to be the name <myModule>.json
```
cd myModule
mv README-template.md README.md
mv template.jso myModule.json
```

If the module will be a nixOS module then rename the .nix file, otherwise remove it
```
mv template.nix myModule.nix
```

Now edit the README.md, install.sh, update.sh, the json and potentially the .nix file. Further instructions for each file below:


## myModule.json

The myModule.json, defines all the "external" parameters of the module, such as a the size of the VM, its number, name VLAN membership, ..
The automated create and install and update scripts of TAPPaaS uses this file.

Modify it to give it good defaults for your module (the final instance of TAPPaaS gives the installer an opportunity to further customize the installation through this file)
Many of the fields in the .json has defaults, in case they are not present in the file.

Here is the list of posible paramters to configure via the json:
-    "version": Must be present.
     -    This is the version of the module, not the TAPPaaS System. 
     -    Used to keep track of running version of modules when reporting errors, and to determine if an upgrade exists
     -    This should be incremented if the module is update
     -    format: Major.Minor.Minorminor. Example 0.5.3
     -    if Major number is less than 1, then the module is not ready for production use 
-    "description": Descriptive text that will end up in the proxmox summary page for the VM
-    "node": The name of the proxmox/tappaas node the module should be installed on.
     -    Default: "tappaas1" 
-    "HANode": 
     -    Default: "NONE"
     -    if present it must name a TAPPaaS node different from "node". This node must have the same storage defined as "storage"
     -    if present then install script will set up High Availability for the VM
-    "replicationSchedule"
     -    Default: "*/15" # every 15 minutes
     -    define the replication interval for HA node
-    "vmid": unique across the tappaas nodes. 
     -    Mandatory: Must be present
-    "vmname": the name of the VM, also the name of the module and the hostname of the OS. 
     -    Default value: The name of the config file sans .json
-    "vmtag": proxmox tags. Default is "TAPPaaS", must be a comma separate list, no spaces
     -    Default: "TAPPaaS"
     -    Typical tags is "TAPPaaS,FOundation" and "TAPPaaS,Test"
-    "bios": bios option for creation of the VM
     -    default is "ovmf"
-    "ostype": proxmox vm option for optimizing hypervisor
     -    default is "l26" (modern Linux kernel)
-    "cores": Allocation of cores to the VM for this module
     -    Defaults: 2
-    "memory": 
     -    Defaults: 4096
-    "diskSize": 
     -    Defaults: 8G
-    "storage": The name of the storage pool to install the module on
     -    Defaults: "tanka1"
-    "imageType": type of image source for the VM creation 
     -    value "clone": the VM is created as a clone of an existing proxmox template
     -    value "iso" the VM is created with a cdrom drive attached to the iso. The iso is downloaded, nad placed in local:iso
     -    value "img" the VM disk will import the image (image is downloaded and unzipped if compressed). img is thrown away after imported
     -    value "apt" the package is a simple apt package to be installed
     -    Defaults: "clone"
-    "image": "Mandatory": 
     -    if "clone": then it is the VMID of the proxmox template to clone.
     -    if "iso" or "img": then it is the name of the image/iso file
     -    if "apt": then is ti the name of the apt packages to install
-    "imageLocation": 
-    -    Mandatory if "iso" or "img" imagetype, it must be an URL to where the "image" is located
-    -    if "apt" then if pressent it is the name of an additional package repository that needs to get loaded
-    "cloudInit": boolean "true"/"false", indicate if VM support cloud-init
     -    Default: "true"
-    "bridge0": the VM -net0 will be associated with this proxmox bridge
     -    Default: "lan"
-    "mac0": the MAC address associated with the net0 network port
     -    Default is a random generated number
-    "zone0": See zones.json and firewall setup for VLAN tags
     -    Default: "mgmt" which is the management lan (non tagged traffic)
     -    name must exists in zones.json
-    "bridge1": if present then a second network card is configured.
     -    The VM -net1 will be associated with this proxmox bridge
     -    Default: "lan"
-    "mac1": as mac0 but for bridge1 and -net1
-    "zone1": See firewall setup for VLAN tags
     -    Default value is "mgmt" which is the management lan (non tagged traffic). 
     -    name must exists in zones.json
     -    not used if "bridge1 is not defined

## install.sh

This script is called with one argument "myModule" when the module is to be installed on a TAPPaaS system
it will be called from the tappaas@tappaas-cicd account, which have ssh and sudo access to all tappaas nodes
The default implementation will create a VM based on the json spec,
it will either clone a template or install an image as pwe "image" type
it will then run the nixos-rebuild, assuming this is a nixos based module

Some modules might have a very different way of getting installed.
If there are manual steps to be completed then document i the INSTALL.md file

## update.sh

TODO: this part of tappaas is still in development

This script is called with one argument "myModule" when the module is to be updates on a TAPPaaS system

The TAPPaaS system will on a periodic basis call the script to keep the module updated.

## myModule.nix

This can be used as a starting point for a module .nix configuration.
The default install.sh will use this to rebuild the configuraiton of the NixOS based VM

