*© 2024. This work is openly licensed via [MPL-2.0](https://mozilla.org/MPL/2.0/.).*

# TAPPaaS Software stack

This is the reason we call it TAPPaaS. Pronounced Tapas like the Spanish dish: A collection of delicious appetizers that makes up a comprehensive serving.

The Software Stack of TAPPaaS delivers the capabilities we believe is needed for a well served Private IT Platform.

Selecting from the enormous pool of software we have used the principles of:

1) must be Open Source
2) must show a track record of being Secure
3) must be "established", and sufficinet feature complete
4) must be open w.r.t. data formats (enabling migration away from TAPPaaS and/or away from the package)


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

proxmox with ZFS gives: RAID, Snapshotting, Replication, NFS, iSCSI, 
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
| email | High | PostIO | Very difficult to run autonomously, maintenance is high|
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
| Application platform | High | K3S, Garage, PostGreSQL | |
| Reverse Proxy | High | Pangolin | for development the requirement is easy access to a reverse proxy in a secure manner |


### Object storage: Garage

Alternatives:
- Minio
- SeeweedFS

### Transactional storage: Postgresql

also implement pg_auto_failover

alternatives:
- mysql, .....

# Security

| Capability | Priority | Software | Comments |
|------------|-----------|----------|----------|
| User and Access mgmt. | Mandatory | ?? | Authentik, Keycloak, proxmox, opnsense??  |
| Password mgmt. | High | Bitwarden |  |
| Backup/Restore | Mandatory | proxmox backup mgmt | need to look into complete backup, maybe znapzend, or other zfs methods. |
| Firewall | High | OPNsense  |  |
| Remote Access | High | TailScale/HeadScale | complement tailscale with self hosted Headscale |
| Thread detection | High | ?? | CrowdSec? |
| Thread monitoring | High | ?? |  |
| DMZ | Mandatory | Pangolin |  |


## Firewall: OPNSense

Alternatives are:

- PFsense: PFSense is the original but is going more and more commercial
- OpenWRT: it seems less scalable and less feature rich
- proxmox firewall: would make it easier as it is already build in, but less secure


## User Management: Authentik / Keycloak

To be investigated:
OPNsense have a build in LDAP. but it is basic. Authentic looks promising
Pangolin also have Identity management
So do NextCloud and Proxmox

## Backup: 

- We generally keep all functions contained in VM's or LCM's. 
- Running a Proxmox Backup service allow us to store backups on secondary tank, on separate nodes and on separate (off site) TAPPaaS systems
- In case of TAPPaaS deployment in High Availability then the HA mirror will add another backup copy
- We need to find a solution for backing up the PVE nodes them self, and any data that we store outside containers.
- We need to give special consideration to encryption keys

We will consider znapzend, used to snapshot and replicate zfs volumes across servers

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

