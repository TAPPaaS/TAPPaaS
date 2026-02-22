# Installation of additional TAPPaaS Proxmox Virtual Environment Nodes

## Assumptions

- One node "tappaas1" have been configured
- the firewall have been configured
- The new TAPPaaS node is connected to a switch on the Lan side of the TAPPaaS firewall
- The first node installed will have the name tappaas1 and ip 10.0.0.10: The follwoing nodes will be
  - tappaas1: 10.0.0.11
  - tappaas2: 10.0.0.12
  - ...
use the same root password as the tappaas1 node

## Install proxmox PVE

Use the same image on usb stick as with node 1

Do run the post install scrip as with node 1: [README](../05-ProxmoxNode/README.md)

Register the hosts on the internal network: tappaas2,3,...

- log into the firewall:
- go to Service -> Dnsmasq DNS & DHCP -> Hosts
  - add a host:
    - name tappaas2
    - domain: mgmt.internal
    - ip: 10.0.0.11
  - press apply

Rename the network bridge from "vmbr0" to "lan" using the command line/console of tappaas node:
- edit the /etc/network/interfaces
- replace all occurrences of "vmbr0" with the string "lan" (there should be two instances)
- save file
- reboot the tappaas node (or PVE will not discover the new lan correctly)

If this node is to be used as fall over node for the firewall then create a "wan" bridge attached to a secondary physical ethernet port
(this can be done from the gui of the tappaas node)

## Repeat this for each additional node in the cluster

## Notes

If you want to remove a node from the cluster, then on console of one of the other nodes in the cluster:

- pvecm delnode "name of node"
- cd /etc/pve/nodes
- rm -r "name of node"
