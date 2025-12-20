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

use the same image on usb stick as with node 1
do run the post install scrip as with node 1

## add node to cluster

First set up ssh on the node: on the console of the new node:

```
TODO
```

then add the node to the cluster
```
pvecm add 10.0.0.10
pvecm status
```

Finally copy the configuration.json from tappas1
```
scp 10.0.0.10:/tappaas/configuraiton.json tappaas
```

## Repeat this for each additional node in the cluster

