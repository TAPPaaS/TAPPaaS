## Installing Proxmox Backup server on a multi node system  

# Introduction

This recipe should only be followed if you plan to have a multi node TAPPaaS system
if you plan to have a single node system then follow the recipe in [version a](../70a-SingleNodeBackup/README.md) 

We set up a secondary TAPPaaS node for HA and for AI and multimedia services. We configure HA for core services in foundation

In the multi node setup, we set up a dedicated Proxmox Backup Server (as opposed to a VM in the only node in a single node setup)

As with a single node system we configure the backup server with a dedicated backup disk and we register the backup server with pangolin to facilitate remote backup synchronization.

We also configure quorum server for the TAPPaaS PBS node.

See [Examples](../../../docs/Examples/README.md) for description of a 3 node TAPPaaS cluster

## Configure a secondary TAPPaaS node

1. ensure configuration file is updated
2. ...

## Hight Availability setup

## Proxmox Backup server (PBS) setup

## quorum

## Test setup

