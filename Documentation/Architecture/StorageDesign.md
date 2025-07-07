*© 2024. This work is openly licensed via [MPL-2.0](https://mozilla.org/MPL/2.0/.).*

# Storage design for TAPPaaS

The starting point for storage design in TAPPaaS is to ensure that the system can grow and that data is secured against failure and finally that we cate for at least to kinds of data w.r.t. availability and redundancy. In more details we have the design constraints:

- Storage is delivered to the application via Proxmox ZFS data pools
- We create growth flexibility through:
  - adding disks to zfs data pools
  - adding data pools to proxmox systems/node
  - adding more proxmox systems/nodes
- We deliver redundancy to cater for issues/faults through:
  - zfs RAID design
  - snapshot and replication between proxmox systems/nodes
  - Backup between local and remote TAPPaaS systems
- We do not insist on SSD vs HDD, and we do not prescribe a disk catching setup. but we give examples in the TAPPaaS example section on good optimized designs. 
- We cater for two kinds of data. High value data that need high degree of redundancy and availability and "second tier" data that in case of failure, can either be recovered from backup or can be safely discarded, or is part of a second order redundancy setup like Garage S3 buckets

## Design

In line with the general TAPPaaS design philosophy we are designing the storage pools in a way that takes away a lot of decision making: default setup should cater for 90% of use cases


In TAPPaaS storage is arranged in zfs pools. Pools are named tanka1, tankb1, ...
in addition to the named pools for data and VMs the default TAPPaaS setup will have the boot/root disk to be a zfs pool

Pools/tanks are mounted in /mnt

The default configuration of of a TAPPaaS node and the default setup of modules assumes that:

- there is a /tanka1 zfs data pool that have RAID redundancy and is high performance. A simple node would have two mirrowed ssd drives, but more complicated setus can be accommodated 
  - as default then all SW modules are installed in VMs that have virtual disks on /tanka1
  - for modules configured for high availability across two TAPPaaS servers/node then there is proxmox replication to the second node /tank1
- if a module require second tier storage then it will as default allocate storage on a /tankb1 zfs data pool
  - /tankb1 should not "waste" resources on having RAID redundancy
  - less performant hard disk can be used for /tankb1
  - typical second tier data is used for: backup modules, s3 bucket systems that have redundancy across TAPPaaS nodes, log systems

A TAPPaaS node might not have a tanka1 or tankb1, if is is part of a cluster, but for a single node TAPPaaS system then plan for having both tanks

A TAPPaaS system can have more data "tanks", to use them edit the install configurations for the module that should take advantage of them (see [Installation instructions](../Installation/README.md)).

The naming convention is 

- Redundant and high performance data pools: Called "a" tanks: "tanka1", "tanka2", "tanka3", ... 
- mass storage without redundancy and performance optimizations: Called "b" tanks: "tankb1", "tankb2", ...

Should you need other storage characteristic like high speed low redundancy, or high redundancy bot low speed, ... then start using letters "c", "d", and describe it in your config.


