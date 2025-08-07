# Example TAPPaaS deployments

The following give examples of more concrete use cases and the associated hardware suitable for this deployment

## A minimal system

This assumes that we are not talking performance testing, then a minimum system can be quite small
Pretty much Intel/AMD CPU will do. 

- RAM: 16G byte (likely it will be possible to test in as little as 8G, but more is better especially if the minimal systems is to be used for more than testing)
- hard disks: only boot and tank1 needed, no resilience is needed. it can be either SSD or traditional HDDs
  - Boot: 256G SSD (might work with less than 100G, still testing)
  - Tanka: 1 TByte SSD (Might work with 512G, depends on number of modules that are enabled, 2-4 T if used for )
  - Tankb: optional: to be used for non important data and non important VM's 
  - backup disk: large HDD, think 2x the size of tanka and tankb together.
- Network: 2 ports. (one for Wan and a shared firewall lan and proxmox lan). 1G will do 2.5 or 10 preferred for the Lan port

you would need to have a at least one TAPPaaS peer to exchange backup with

A recommended setup we use is am Atom C3558 base system: Qotom Q20300G9, with 16G memory,256 SATA SSD for boot, 2TB tanka1 on SSD and 2Tb 2.5inch HHD for tankb1,
TODO: rethink backup hdd connection when using Qotom as single server

## Community/Home/SMB: High resilience

Construct a 3 node system:

- TAPPaaS1: Primary system for firewall, self management, and common services (like the minimal system)
  - only have boot and tanka disks. only run important stuff. Tanka is mirrow or raidz. SSD
  - RAM is ECC
- TAPPaaS2: AI, Media and fail over node.
  - Runs stuff that do not require HA. which is stored on tankb
  - has a tanka that is sized similar to tanka on TAPPaaS1, and if used as a HA mirrow
  - has a tankb that is big enough for media (films, music, ...) as well as AI models
  - has a GPU capability for AI (and potential for transcoding, virtualized gaming, etc)
  - GPU and ram is not ECC but large enough to support AI models
- TAPPaaS3: Small quorum and backup server
  - boot disk + backup disk: Proxmox backup server runs in an LXC on the boot disk
  - Backup disk is at least 2x tanka on TAPPaaS1 + tankb on TAPPaaS2.
    - backup should also be big enough to manage servicing as a backup system for remote TAPPaaS systems.
  - RAM: 4G + 1Gx(number of Tb backup disks)


## Scale out

Add servers as needed. Pangling can act as a load balancer. CEPH can be added to have consistent storage across nodes. 

