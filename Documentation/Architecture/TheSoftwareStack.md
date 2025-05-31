# TAPPaaS Software stack

This is the reason we call it TAPPaaS. Pronounced Tapas like the Spanish dish: A collection of delicious appetizers that makes up a comprehensive serving.

The Software Stack of TAPPaaS delivers the capabilities we believe is needed for a well served Private IT Platform.

| Capability | Mandatory | Software | Comments |
| :--------- | :-------: | :------- | : ------ |
| Compute    | Yes  | Proxmox | provide exce;ent compute cluster capability


# Foundation

## Base Cloud Infrastructure platform: Proxmox

This  deliver most of the Compute and Storage foundation

Alternatives:

- XCP-ng: seems less polished and with less features. 
  - But it also seems more "free"
- FreeNAS, TrueNAS: good for storage, but not really a cloud platform

## Persistant Storage layer

### File storage, and NFS: Proxmox

Implement a "tank1" on each node with basic redundancy and replication
Implement a "tank2" on each node without redundancy for backups and higher level services that have own redundancy

### Object storage: Garage

Alternatives:
- Minio
- SeeweedFS

### Transactional storage: Postgresql

also implement pg_auto_failover

alternatives:
- mysql, .....

# Security

## Firewall: OPNSense

Alternative is PFsense. PFSense is the original but is going more and more comercial

### User Management: Authentik

To be investigated:
pfsense have a build in LDAP. but it is basic. Authentic looks promising

### Password management system: Bitwarden
Fully open source, considered safe, and you can run your own encrypted "cloud" service to sync between clients and accounts


## Backup: 

znapzend, used to snapshot and replicate zfs volumes across servers
This is complemented by Proxmox backup server to backup VMs

This will give two kinds of backups

## Self Management
- undecided on dashboard, but Grafana is part of it
- Portainer
- Kuma uptime monitoring

## Security

To investigate
- wazuh
- security@nion
- Graylog
- RustScan

# Functions

## Collaboration and Document, picture store: NextCloud

File storage and sharing
Picture storage and sharing: 
Can be used as a email client, undecided 

## Media center: Plex or Jellyfin

Plex is the easy way, but not as "free" as Jellyfin.

## home control: Home Assistant

For zigbee integration use build in package

## Home security: Frigate

still a beast to integrate

