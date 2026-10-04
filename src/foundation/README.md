# TAPPaaS Foundation

The foundation is what makes TAPPaaS a *platform* rather than a pile of VMs. Its modules must
all be installed and running for the rest of TAPPaaS to work. Like everything else it is built
from modules, **named, not numbered** — install order is derived from each module's
`dependsOn`, not a numeric prefix. How to install it: [INSTALL.md](INSTALL.md).

## Modules

| Module | Role |
|--------|------|
| [cluster/](cluster/README.md) | Proxmox nodes, storage pools, HA — the ground everything stands on |
| [network/](network/README.md) | OPNsense firewall: zones, DNS, DHCP, reverse proxy, rules |
| [templates/](templates/README.md) | The prebuilt VM templates (NixOS, Windows) modules deploy from |
| [tappaas-cicd/](tappaas-cicd/README.md) | The mothership: managers and controllers that run the platform |
| [backup/](backup/README.md) | Proxmox Backup Server: scheduled, verified, off-site capable |
| [identity/](identity/README.md) | Authentik: SSO, users, groups, organisations; secrets |
| [logging/](logging/README.md) | Loki / Grafana / Promtail: central logs |
| [satellite/](satellite/README.md) | Optional off-premises VPS: public ingress, off-site backup, admin VPN (ADR-010) |

## Architecture view

The layered ArchiMate view — capabilities at the top, through services and the realizing
components, down to the cluster nodes:

```kroki-plantuml
@startuml
!include <archimate/Archimate>

title TAPPaaS Foundation Stack

' === STRATEGY LAYER (Capabilities) ===
Strategy_Capability(capFound, "Foundation Stack")
Strategy_Capability(capBackup, "Backup Services")
Strategy_Capability(capCluster, "Cluster")
Strategy_Capability(capFirewall, "Firewall")
Strategy_Capability(capProxy, "Web Proxy")
Strategy_Capability(capIdentity, "Identity Management")
Strategy_Capability(capCICD, "CI/CD")

' === APPLICATION LAYER (Services & Components) ===
' Application Services
Application_Service(backupSvc, "Backup Service")
Application_Service(vmSvc, "VM Service")
Application_Service(haSvc, "HA Service")
Application_Service(zoneSvc, "Zone Service")
Application_Service(firewallSvc, "Firewall Service")
Application_Service(routingSvc, "Routing Service")
Application_Service(proxySvc, "Proxy Service")
Application_Service(identitySvc, "Identity Service")
Application_Service(cicdSvc, "CI/CD Service")

' Application Components (the actual software)
Application_Component(pbs, "Proxmox Backup Server")
Application_Component(proxmox, "Proxmox VE")
Application_Component(opnsense, "OPNsense")
Application_Component(caddy, "Caddy")
Application_Component(authentik, "Authentik")
Application_Component(cicdApp, "TAPPaaS CICD")

' Caddy is a component of OPNsense
Rel_Composition(opnsense, caddy)

' === TECHNOLOGY LAYER (Infrastructure) ===
Technology_Node(node1, "tappaas1")
Technology_Node(node2, "tappaas2")
Technology_Node(node3, "tappaas3")

' Capability decomposition
Rel_Aggregation_Down(capFound, capBackup)
Rel_Aggregation_Down(capFound, capCluster)
Rel_Aggregation_Down(capFound, capFirewall)
Rel_Aggregation_Down(capFound, capProxy)
Rel_Aggregation_Down(capFound, capIdentity)
Rel_Aggregation_Down(capFound, capCICD)

' Capabilities realized by Services
Rel_Realization_Up(backupSvc, capBackup)
Rel_Realization_Up(vmSvc, capCluster)
Rel_Realization_Up(haSvc, capCluster)
Rel_Realization_Up(zoneSvc, capFirewall)
Rel_Realization_Up(firewallSvc, capFirewall)
Rel_Realization_Up(routingSvc, capFirewall)
Rel_Realization_Up(proxySvc, capProxy)
Rel_Realization_Up(identitySvc, capIdentity)
Rel_Realization_Up(cicdSvc, capCICD)

' Services delivered by Components
Rel_Realization_Up(pbs, backupSvc)
Rel_Realization_Up(proxmox, vmSvc)
Rel_Realization_Up(proxmox, haSvc)
Rel_Realization_Up(opnsense, zoneSvc)
Rel_Realization_Up(opnsense, firewallSvc)
Rel_Realization_Up(opnsense, routingSvc)
Rel_Realization_Up(caddy, proxySvc)
Rel_Realization_Up(authentik, identitySvc)
Rel_Realization_Up(cicdApp, cicdSvc)

' Components deployed on Infrastructure Nodes
Rel_Assignment_Up(node1, proxmox)
Rel_Assignment_Up(node2, proxmox)
Rel_Assignment_Up(node3, proxmox)
Rel_Assignment_Up(node3, pbs)

@enduml
```

## Reference files

| Path | Contents |
|------|----------|
| [schemas/](schemas/README.md) | JSON schemas for module configuration and related definitions. |
| [DEPENDENCIES.md](DEPENDENCIES.md) / [DEPENDENCIES.csv](DEPENDENCIES.csv) | Generated script/command dependency documentation. |
| [PROGRAMS.csv](PROGRAMS.csv) | Generated inventory of programs used across foundation. |
| [TESTING.md](TESTING.md) | How to test foundation modules. |
| [install.sh](install.sh) / [uninstall.sh](uninstall.sh) | Install / uninstall the full foundation layer. |
| [Deprecated/](Deprecated/) | Retired modules kept for reference. |
