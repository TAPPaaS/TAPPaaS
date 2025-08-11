*© 2024. This work is openly licensed via [MPL-2.0](https://mozilla.org/MPL/2.0/.).*

# TAPPaaS Security design

## Introduction

A high security standard for the TAPPaaS solution is essential for TAPPaaS to compete with cloud provides.

There are may aspects to security, what we have considered in TAPPaaS is:

- Secrets and password management
- Root and Management access to Virtual machines.
- Network segmentation
- Inbound Internet access security
- Supply chain security
- Monitoring of the TAPPaaS solution
- Resiliency in case of breach

In the following we document the design for each topic

## Secrets and password management

Having a well established password manager that can be trusted is essential, and the choice is BitWarden/VaultWarden. This is the only true open source password manager that can be self-hosted. VaultWarden is a rewrite of the server part in Rust. It is audited.

For secrets used in integration we chose to also use VaultWarden. This simplify setup

The server part runs as a service under pangolin reverse proxy so available everywhere. secrets are stored encrypted so even a hack of the server is not going to compromise the passwords. For that reason we host the vault in the DMZ to assist with uptime, and the possibility to host in a VPS.


## Root and Management access to VM's

General setup is:

- every management is done either from the root account of the tappass node itself
- or it is done from the tappass account on the tappaas-cicd vm
- every vm has a "tappaas" user with "sudu" rights. 
- the tappaas user defined in cloud-init will have no password login access
- root will not have password login
- there will be an SSH Authorized list configured to allow login from the tappaas@tappaas-cicd user and from root at the tappaas node


## Network segmentation

see [Network](./NetworkDesign.md) design

## Inbound Internet Access security

There are 3 main components in the external access security setup:

- Use a reverse proxy with access control, served in a separate DMZ network segment.
- Use a blocking firewall that filters DNS and IP based on public block lists
- Participate in the CrowdSec network

## Supply chain security

Only use software from major open source organisations with a good history on security
monitor CVE publication on all TAPPaaS packages
Keep SW patched on a weekly basis (automated)

## Monitoring of TAPPaaS

To be designed

## Resiliency

The two main designs principles for resiliency in TAPPaaS is:
- segmentation of TAPPaaS network: so breach of one service or one VM does not imidiately leads to breach of other VMs
  - and importantly the root access accounts for management resides on a segment that can not be accessed from the other segments
- extensive backups, including backups to external site that have completely different security setups
  - see [Backup](./BackupDesign.md)


