# Template module configuration

A standard module will:

- Create a VM based on a clone of a NixOS base system. 
  - This is driven by the <template>.json
  - the same method can be used for generic iso or img type VMs
- Reconfigure the cloned or installed VM

The "install.sh" must be present and will be called by tappaas-cicd at install time. The script should expect one argument and that is the name of the vm.

The "update.sh" must also be present, it will be called at regular intervals to update/patch a runnnig installation

The <vmname>.json (rename and edit the template.json). Note:
- the git supplied .json will potentially need local tappaas instance modification (like choosing a different local node than the default tappaas1, or adjusting HA parameters)
- For that reason the tappaas-cicd install process will copy the json to a local tappaass-cicd configuration directory, and local modifications can be done from there

The <vmname>.nix (rename and edit the template.nix) is the configuration of the NixOS (if the VM is NixOS based): TODO change to flake structure


The .json have the following parameter:
-    "version": Must be present.
     -    This is the version of the module, not the TAPPaaS System. use to keep track of running version of modules when reporting errors
     -    This should be incremented if the module is update
     -    format: Major.Minor.minorminor. Example 0.5.3
     -    if Major number is less than 1, then the module is not ready for production use 
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
-    "bridge0": the VM -net0 will be associated with this proxmox bridge
     -    Default: "lan"
-    "mac0": the Macadress associated with the net0 network port
     -    Default is a randaom generated number
-    "zone0": See zones.json and firewall setup for VLAN tags
     -    Default: "mgmt" which is the management lan (non tagged traffic)
     -    name must exists in zones.json
-    "bridge1": if present then a second network card is configured.
-    "mac1": as mac0 for bridge1 and -net1
-    "zone1": See firewall setup for VLAN tags
     -    Default value is "mgmt" which is the management lan (non tagged traffic). 
     -    name must exists in zones.json
     -    not used if "bridge1 is not defined
-    "cloudInit": boolean "true"/"false", indicate if VM support cloud-init
     -    Default: "true"
-    "description": descriptive text that will end up in the proxmox summary  page for the VM
-    
