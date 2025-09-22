# TAPPaaS naming conventions

consistent naming makes everything easier so naturally TAPPaaS is also having conventions for naming stuff

# VM name, hostname and service name

The entire point of TAPPaaS is to deliver services to users, so thinking outside in we start with naming of services

generally we use the common name of the software package that deliver the service. so the file service is delivered by next cloud so it is accessible as "nextcloud" under the domain name of the TAPPaaS system: nextcloud.example.org

generally a service is delivered from a virtual host, and we give the host the same name "nextcloud"
and the host is running as a VM under proxmox an we call the VM the same "nextcloud"

so service name, hostname and vm name are the same under TAPPaaS

Generally these names are kept in lowercase but if readability is easier then capitalizations can be used like for "HomeAssistant". TAPPAaaS prefer using capitalization over use of hyphen

## exceptions

no rule without exceptions: If a service is implemented in several instances, then the name can have a prefix indicating the variant

## note on tappaas itself

The tappaas system itself is controlled and monitored by a set of services served by a single VM. this VM is named "tappaas" and there is a service "tappaas.example.org" that allow an administrator to see the status of the system.

# Node names

The TAPPaaS system is implement on one or several physical machines each running Proxmox Virtual Environment (PVE) or running Proxmox Backup server (PBS). each of these machines are named: tappaasXY
where X is either a, b or c and Y running number

a: Indicate that it is a primary node: Implemented with redundancy
b: Indicate it is a secondary node: The TAPPaaS system can deliver its services without these nodes (but with less performance)
c: Indicate it is a backup node: Typically the PBS for the tappaas system

a small TAPPaaS setup will have one node named: "tappaasa1"
a scaled out system will have nodes: "tappaasa1", "tappaasa2", "tappaasb1", tappaasc1"

# Data pools

the nodes have storage pools and they follow the same naming conventions as the node names with "a", "b" and "c" indicating the type of storage. See [Storage](./StorageDesign.md) for details