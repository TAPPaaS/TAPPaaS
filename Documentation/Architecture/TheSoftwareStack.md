# TAPPaaS Software stack

This is the reason we call it TAPPaaS. Pronounced Tapas like the Spanish dish: A collection of delicious appetizers that makes up a comprehensive serving.

The Software Stack of TAPPaaS delivers the capabilities we believe is needed for a well served Private IT Platform.

Selecting from the enormous pool of software we have used the principles of:

1) must be Open Source
2) must show a track record of being Secure
3) must be "established", and sufficinet feature complete
4) must be open w.r.t. data formats (enabeling migration away)


## Foundation

Let us get foundation out of the way first. Everything is running on top of the foundation.

| Capability | Priority | Software | Comments |
|------------|-----------|----------|----------|
| Compute    | Mandatory  | Proxmox | provide excellent compute cluster capability |
| Storage    | Mandatory  | Proxmox-ZFS | ZFS gives a lot of flexibility. and is build into proxmox, making it well aligned with Cluster management |
| Connectivity | Mandatory | OPNsense | Virtualized and combined with a layer 3 switch and proxmox bridging and vlan support |
| User Mgmt. | Mandatory | ?? | | 

### Base Cloud Infrastructure platform: Proxmox

This  deliver most of the Compute and Storage foundation

Alternatives:

- XCP-ng: seems less polished and with less features. 
  - But it also seems more "free"
- FreeNAS, TrueNAS: good for storage, but not really a cloud platform

### Persistent Storage layer

proxmox with ZFS gives: RAID, SNapshotting, Replication, NFS, iSCSI, 
Problem with proxmox is a limited GUI for management, and further the choice explosion zfs gives makes it hard to design a solution
TAPPaaS will address this with recommended setup and automation

Note that proxmox and zfs do not give Hight Available storage. in that case we need to look into Object Storage and other distributed storage solutions.
We do not consider this a Foundation. but something that goes in to the business layer of TAPPaaS together with a HA implementation of a relational database

The alternative to Proxmox ZFS is FreeeNAS, but we consider the benefits compared to what we can do with automation in proxmox to not being worth the effort to run FreeNAS in parallel with proxmox.

## Physical Home

| Capability | Priority | Software | Comments |
|------------|-----------|----------|----------|
| Smart Lighting | High | Home Assistant | Will be the main interface to TAPpaas for a home/community installation |
| Smart heating | Low | Home Assistant | |
| Smart Sprinkler | Low | Home Assistant + OpenSprinkler | |
| SMART AVR | Medium | ?? | This is the player system. to replace AppleTV, HEOS, etc |
| Home Butler | Medium | HA + LLM | lots of experimentation ongoing |

## Household Member

| Capability | Priority | Software | Comments |
|------------|-----------|----------|----------|
| email | High | PostIT | Very difficult to run autonomously, maintenance is high|
| Address book | High | NextCloud | need to be integrated into many other applications |
| Calendering | High | NextCloud | |
| Note Taking | Medium | ?? | Could simply be files in Nextcloud, but need to be investigated |
| Photos | High | NextCloud with Memories module ||
| Music | High | Jellyfin | |
| Video | High | Jellyfin| |
| Podcasts | medium | [audiobookshelf](https://www.audiobookshelf.org/)?? | |
| Document | high | NextCloud | |
| Offline Web | low | Karakeep | selfhosted open source version of Pocket |
| Virtual Assistant | medium | ?? | |
| Bookshelf | low | CAlibra?? | |

## Small Community

| Capability | Priority | Software | Comments |
|------------|-----------|----------|----------|
| WiFi Rooming | medium | R.O.B.I.N. ?? | |
| Internet Sharing | High | OPNsense | |
| Public Bookshelf | Medium | Calibra, wikipedia hosting, ... ?? | |
| Community Social | High | Mastedont | |
| Video Conferencing | low | ?? | |

## SMB

| Capability | Priority | Software | Comments |
|------------|-----------|----------|----------|
| Email | High | | | 
| Office Suite | High | CryptPad | |
| Corporate website | High | | |
| ERP System | Medium |||
| Office Wifi | Medium | | |
| Corporate VPN | High | TailScale/HeadScale | |
| Video Conferencing | Medium | ?? | |
| Chat | Medium | ?? | |

## Software Development

| Capability | Priority | Software | Comments |
|------------|-----------|----------|----------|
| Git | High | Gitea | |
| CICD | High | Gitea, Terraform, Ansible | |
| Chat | Medium | ?? | |
| Backlog | High | ?? | |
| Application platform | high | K3S, Garage, PostGreSQL | |
| Reverse Proxy | High | Pangolin | |


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

Alternative is PFsense. PFSense is the original but is going more and more commercial

### User Management: Authentik / Keycloak

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

