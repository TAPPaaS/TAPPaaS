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

## preparation

if this is the second node to add then we need to create the cluster on tappaas1 so that we can add this node to a cluster later on
on the cole of tappaas1:
```
pvecm create TAPPaaS
```

## Install proxmox PVE

Use the same image on usb stick as with node 1

Do run the post install scrip as with node 1

Register the hosts on the internal network: tappaas2,3,...

log into the firewall:
- go to Service -> Dnsmasq DNS & DHCP -> Hosts
  - add a host:
    - name tappaas2
    - domain: internal
    - ip: 10.0.0.11

join the node to the TAPPaaS cluster:
- on the tappass1 node: go to datacenter and click Cluster: click Join information, and copy information
- on the new tappaas node: go to datacenter and click Cluster and then join cluster: paste inforamtion and enter root password for tappaas1


Finally copy the configuration.json from tappas1.
On the tappaas2,3,.. console:
```
cd
scp 10.0.0.10:/root/tappaas/configuration.json tappaas
```

## Repeat this for each additional node in the cluster

