This directory contain automation and instructions for installing the OPNsense software

We use proxmox helper scripts to get the basic opnsense VM up and running, then we modify it to use PCI passthrough for the ethernet card.
TODO: recode to be automated directly using opentufu and ansible.

The steps are:

1) Validate and configure proxmox and underpinning hardware for pci passthrough
2) creat a a temporary vmrb1
3) Create a VM with OPNsense using proxmox helperscripts
4) Select and setup Ethernet PCI passthrough instead of vmrb/1
5) SWitch out firewall

## PCI passthrough

Run ./validate.sh

## Create temporary vmbr1

do this in the proxmox gui under networking. add a vmrb1, add the approiate ethernet port for WAN

## Create OPNSense

Run the proxmox helperscript that installs opnsense. Run the following command from the root shell in the proxmox server (not the tappaas cicd VM)

```
bash -c "$(curl -fsSL https://raw.githubusercontent.com/community-scripts/ProxmoxVE/main/vm/opnsense-vm.sh)"
```

Use default values


## Select PCI passthrough

run ethernetPCI.sh

at this point you should check that there is a VM with PCI passthrough


## Validate

## Switch firewall



