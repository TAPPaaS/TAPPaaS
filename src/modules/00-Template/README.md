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

The .json have the following parameter:

-    "version": Must be present.
     -    This is the version of the module, not the TAPPaaS System. use to keep track of running version of modules when reporting errors
     -    This should be incremented if the module is update
     -    format: Major.Minor.minorminor. Example 0.5.3
     -    if Major numner is less than 1, then the module is not ready for production use 
-    "node": The name of the proxmox/tappaas node the module should be installed on.
     -    Default is "tappaas1" 
-    "HANode": 
     -    Default "NONE"
     -    if present it must name a TAPPaaS node different from "node". This node must have the same storage defined as "storage"
     -    if present then install scrip will set up High Availability for the VM
-    "replicationSchedule"
     -    Default "*/15" # every 15 minutes
     -    define the replication interval for HA node
-    "vmid": unique across the tappaas nodes. 
     -    Mandatory: Must be present
-    "vmname": the name of the VM, also the name of the module and the hostname of the OS. 
     -    Default value: The name of the configfile sans .json
-    "vmtag": proxmox tags. Default is "TAPPaaS", must be a comma separate list, no spaces
     -    Default is "TAPPaaS"
     -    Typical tags is "TAPPaaS,FOundation" and "TAPPaaS,Test"
-    "bios": bios option for creation of the VM
     -    default is "ovmf"
-    "ostype": proxmox vm option for optimizing hypervisor
     -    default is "l26" (modern Linux kernel)
-    "cores": Allocation of cores to the VM for this module
     -    Defaults to 2
-    "memory": 
     -    Defaults to 4096
-    "diskSize": 
     -    Defaults to 8G
-    "storage": The name of the storage pool to install the module on
     -    "Defaults to tanka1"
-    "imageType": type of image source for the VM creation 
     -    value "clone": the VM is created as a clone of an existing proxmox template
     -    value "iso" the VM is created with a cdrom drive attached to the iso. The iso is downloaded, nad placed in local:iso
     -    value "img" the VM disk will import the image (image is downloaded and unzipped if compressed). img is thrown away after imported
     -    Defaults to "clone"
-    "image": "Mandatory: if Clone then it is the VMID of the proxmox template to clone. otherwise it is the name of the image/iso file
-    "imageLocation": Mandatory if iso or img imagetype, it must be an URL to where the "image" is located
-    "bridge0": the VM -net0 will be associated with this proxmox bridge
     -    Default to "lan"
-    "mac0": the Macadress associated with the net0 network port
     -    Default is a randaom generated number
-    "vlantag0": See firewall setup for VLAN tags
     -    Default value is "0" which is the management lan (non tagged traffic)
-    "bridge1": if present then a second network card is configured.
-    "mac1": as mac0 for bridge1 and -net1
-    "vlantag1": See firewall setup for VLAN tags
     -    Default value is "0" which is the management lan (non tagged traffic)
-    "description": descriptive text that will end up in the proxmox summary  page for the VM
-    
