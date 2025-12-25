# Proxmox Backup Server (PBS) implementation notes

Reflections on how to deploy the TAPPaaS PBS solution

## Introduction

There are are a two topics that is important to consider when deploying PBS

1) Design and sizing of the storage pools
2) Deployment method of the PBS

## PBS storage pools

PBS has a number of options for storing backups, for instance:
- local native hard disks
- virtual hard disks like iscsi exposed storage
- NFS storage
- S3 buckets

For TAPPaaS we favour local native hard disks. (local to the system where PBS is deployed)

We recommend that PBS should have direct access to the hard disk and do its own zfs file system on the hard disks

Further we recommend that the physical hard disks for backup is ONLY used for backup data. This further reduce the risk of a failure of a production hard disk is also affecting the backup data

## Deployment of PBS

In the TAPPaaS design we considered the following 4 deployment options:

- Dedicated: Deploy PBS on a dedicated native physical server
- Native: Deploy PBS on a PVE TAPPaaS node directly as root, on the hypervisor
- LXC: Deploy PBS in an LXC container on a TAPPaaS Node
- VM: Deploy PBS in a VM on a TAPPaaS Node

There are advantages and disadvantages of each method, each described in the following subsections

The conclusion is that we will do Native PBS deployment in TAPPaaS

### Dedicated physical server

Advantages:

- Full separation of concerns. Backup are separate from any running system.
- There is direct native access to the hard disks in the system.
- It is possible to consider this a 3 node in a PVE cluster, but installing a quorum server process on the PBS system.

Disadvantages:

- It is more costly, as the hardware can not be reused for anything else
- for a small TAPPaaS system you would need at least two machines
- it is more complicated to deploy

### Native deployment on a PVE node

This is close to the Dedicated system (and the choice we made in TAPPaaS)

Advantages:

- It gives direct native access to hard disks.
- It shares the kernel with PVE and is thus very resource light
- it can be deployed in a single node system
- it is easy to deploy, setup, and keep updated (simple apt update)

Disadvantages:

- Require that PBS and PVE is on the same kernel
  - Remedy: typically they are release close together and TAPPaaS will be conservative towards bleeding edge Proxmox deployments so not an issue
- A running PBS backup will load the system that is also functioning as a TAPPaaS node.
  - Remedy: try and only use the node for high availability service fail over, and/or low priority services

### LXC deployments on a PVE node

Advantages:

- As with Native, there is a sharing of the kernel thus low resource overhead
- It is easier to passthrough hard disk resources than in the VM case
  - but is is still not native access as it is with "Native" and "dedicated"

Disadvantages:

- It is more complicated to access the Hard disk resources than in the Native and Dedicated case
- LXC deployment is not the default deployment in TAPPaaS

### VM deployments on a PVE node

Advantages:

- It will become "just an other service" under TAPPaaS

Disadvantages:

- It is very complicated to get access to the underlying hard disk resources
- Restoring PBS in case of hw failure is more complicated
- It is not a recommended way to deploy according to Proxmox documentation
