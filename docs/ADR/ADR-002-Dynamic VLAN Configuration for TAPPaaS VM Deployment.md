# ADR-002: Dynamic VLAN Configuration for TAPPaaS VM Deployment
**Author** Erik Daniel (tappaas)
**Status:** Proposed  
**Date:** 2025-02-03  
**Deciders:** TAPPaaS Core Module Owner  
**Technical Story:** RCA-2025-02-03-VLAN-SRV 
**Technical Story:** Depends on RCA-2025-02-03-VLAN-SRV and ADR-001 (Trunk Mode)

---

## Context and Problem Statement

TAPPaaS VMs using trunk mode (per ADR-001) have hardcoded VLAN parameters in NixOS configuration. Module developers must manually edit `/etc/nixos/configuration.nix` to change VLAN ID before deployment, which blocks automation and is error-prone.

**Key constraint:** TAPPaaS uses `./install.sh` deployment scripts (not Terraform/OpenTofu).

---

## Decision Drivers

* Eliminate manual NixOS configuration editing
* Work with existing `./install.sh` deployment scripts
* Maintain NixOS declarative configuration
* Use standard tooling (Proxmox native support)
* No Terraform or external orchestration dependencies

---

## Decision Outcome

**Chosen option:** Cloud-Init with Proxmox native support

Use cloud-init to inject VLAN parameters at deployment time. Module `./install.sh` scripts create cloud-init configuration files and use `qm` commands to deploy VMs.

---

## Implementation

### 1. NixOS Configuration (Template)

**File:** `/etc/nixos/configuration.nix`

Add this to the template:

```nix
{ config, pkgs, lib, ... }:

let
  # Default fallback
  defaultNetwork = {
    vlanId = 210;
    gateway = "192.168.210.1";
    useDhcp = true;
  };
  
  # Read cloud-init config if exists
  cloudNetworkPath = /etc/tappaas/network.nix;
  networkConfig = 
    if builtins.pathExists cloudNetworkPath
    then import cloudNetworkPath
    else defaultNetwork;

in {
  services.cloud-init.enable = true;
  services.cloud-init.network.enable = false;
  
  networking = {
    useDHCP = false;
    interfaces.ens18.useDHCP = false;
    
    vlans."ens18.${toString networkConfig.vlanId}" = {
      id = networkConfig.vlanId;
      interface = "ens18";
    };
    
    interfaces."ens18.${toString networkConfig.vlanId}".useDHCP = networkConfig.useDhcp;
    
    defaultGateway = {
      address = networkConfig.gateway;
      interface = "ens18.${toString networkConfig.vlanId}";
    };
    
    nameservers = [ networkConfig.gateway ];
  };
}
```

---

### 2. Cloud-Init Configuration File

**File:** `/var/lib/vz/snippets/<hostname>.yml`

Module developers create this file:

```yaml
#cloud-config
hostname: tappaas-mymodule-001

write_files:
  - path: /etc/tappaas/network.nix
    permissions: '0644'
    content: |
      {
        vlanId = 220;
        gateway = "192.168.220.1";
        useDhcp = true;
        staticIp = null;
      }

runcmd:
  - mkdir -p /etc/tappaas
  - nixos-rebuild switch
```

**Change `vlanId = 220;` to your module's VLAN.**

---

## Positive Consequences

* Eliminates manual NixOS editing
* Industry-standard cloud-init
* Works with Proxmox CLI (`qm` commands)
* Configuration persists across reboots/migrations

---

## Negative Consequences

* Adds cloud-init dependency
* First-boot only (cannot change VLAN after deployment)

---

## References

- Proxmox Cloud-Init: https://pve.proxmox.com/wiki/Cloud-Init_Support
- Cloud-Init Write Files: https://cloudinit.readthedocs.io/en/latest/reference/modules.html#write-files
- NixOS Modules: https://nixos.org/manual/nixos/stable/index.html#sec-modularity

---

**End of ADR-002**