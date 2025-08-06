*© 2024. This work is openly licensed via [MPL-2.0](https://mozilla.org/MPL/2.0/.).*

# TAPPaaS Backup, Disaster Recovery and High Availability Design

## Introduction

Backup, Disaster Recovery (DR) and High Availability (HA) goes hand in hand and is typical topics that are not well planned for SMB and Home use.

- Backup: Ensuring that you never lose data
- Disaster Recovery: Ensure that you can recover from a fatal error
- High Availability: Ensure that the services continue running in case of component failure

A goal for TAPPaaS is to ensure all three topics are delivered out of the box.

All three topics have a cost associated and thus it wil always be a compromise. Here we define the compromise taken with TAPPaaS and the associated flexibility

## Backup

We are following the 3-2-1 backup design principle for TAPPaaS:

- have 3 copies of data
- have 2 different format of backup
- have 1 backup in a remote location

THe primary design principle for the TAPPaaS backup strategy is that every configuration and all user data is located inside the VMs that host the services. The TAPPaaS instance configuration itself is located inside the TAPPaaS CICD VM. 

Every TAPPaaS system should have local Proxmox Backup Server (PBS). In a single node system the backup server need to run on the same node obviously, but in a three or more node system it is encouraged to run the backup server on a node that only function as a High Available backup node (thus in regular mode of operation do not house active data). 

The PBS is running on a regular interval (default is daily), and with compression and deduplication it can keep a daily back up for 7 days. Weekly for 4 weeks and monthly for one year. Yearly for ever. This ensure you can go back in time in case of a long running hacking attempt or if an accidental delete is not discovered immediately.

The second layer of Backup is to ties the local PBS to a remote PBS backup service, using the PBS replication feature: Any TAPPaaS system can act as a PBS for another TAPPaaS system. Backups are encrypted by default, ensuring that you do not need to trust the remote TAPPaaS operator. Alternative you can set up your own PBS in a remote cloud provider using a cheap S3 backend.

The final aspect of backup is to allow the individual users to create their own data backup on a remote media. (typically an USB HD). This data is stored in the native format of the individual applications that is part of TAPPaaS. This last backup will also allow a user to leave a TAPPaaS system, without loosing their data.


## Disaster Recovery

There are generally 4 types of Disasters to deal with:

- Hardware failure
- Software updates that goes wrong
- Hackers infiltrate and destroy, encrypt or generally makes the system unreliable
- The user (or Administrator) accidentally deletes data or disrupt the working installation

High availability design to some extend can minimize the risk of the first and to some extend the second DR issue.

TAPPaaS operate with 3 kinds of Disaster recovery methods, that should be able to handle all four situations

1) Rebuild the system from backup
2) "rent" space on an other TAPPaaS system. re establish the services from backup in separate VLANs
3) Rent VPC's in a cloud provider and re establish VM's
Finally there is the option of taking the "personal" backup and re establish an account on somebody elses TAPPaaS

Initial design goal is to test and describe method 1)

## High Availability

There are the following High Availability scenarios that TAPPaaS will give options for managing:

- Hard disk failure
- General Hardware failure 
- Reboots and reconfiguration of TAPPaaS nodes
- Overloaded services
- Internet failure


### Hard disk redundancy

The Proxmox and associated ZFS file system allow TAPPaaS to be configured with Mirror or RAIDz1/2 redundancy. 
It comes with a cost so we are flexible in two ways:

- TAPPaaS separate between important and non important services, deployed on two different zfs datapools (tanka and tankb). this way you can reserve the redundancy to the services that are high in important
- TAPPaaS do not enforce a particular redundancy level for datapools, but recommend mirror for tanka and no redundancy for tankb

### Cluster setup

TAPPaaS support setting Proxmox up in a cluster with 3 or more nodes. It is not a requirement but recommended for anything but a small setup.
If TAPPaaS is configured on 3 or more nodes then each of the high priority services are setup with a default fall over node, and regular snapshot transfer. This can be improved with a Ceph file system setup (also part of Proxmox) but that is not recommended unless it is a large (SMB) installation.

Fail over in case of reboots, or HW failure can be done in a few minutes. 
Special attention needs to be taken for the OPNsense firewall, as it require an ethernet connection handover. It is possible to run OPNSense in HA setup, but that is outside the scope of TAPPaaS to configure out of the box

in terms of overloaded services, then the Pangolin Reverse proxy allow a service to be load balanced between TAPPaaS nodes, but again as with OPNsense it is outside the scope of a standard TAPPaaS installation to set this up. If is however possible.

### Internet Failure

It is the intent to test the OPNSetup and associated caching recursive DNS and ensure that the local TAPPaaS ecosystem continue to function when there is an internet outage

### Unbreakable Power Supply

It is outside the scope to design and recommend UPS setup for TAPPaaS. Depending on your environment it might be relevant to consider an UPS as well as potentially separate power paths to the nodes of TAPPaaS

