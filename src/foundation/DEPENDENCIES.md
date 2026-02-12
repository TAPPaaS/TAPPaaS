# TAPPaaS Foundation Layer - Dependency Documentation

This document describes the file dependencies within the `src/foundation/` directory of TAPPaaS.

## Summary

The foundation layer contains **55 files** organized by directory:

| Directory | Files | Description |
|-----------|-------|-------------|
| Root level | 5 | JSON configuration files |
| 05-ProxmoxNode | 2 | Initial Proxmox node setup scripts |
| 10-firewall | 2 | OPNsense firewall configuration |
| 20-tappaas-nixos | 3 | NixOS VM template |
| 30-tappaas-cicd | 4 + 10 + 12 + 2 | CICD mothership (main + scripts + Python + Nix) |
| 35-backup | 6 | Proxmox Backup Server |
| 40-Identity | 4 | Identity/secrets management |
| Attic | 8 | Deprecated/archived files |

### Key Dependency Chains

1. **Configuration Flow**: `configuration.json` → `copy-jsons.sh` → all nodes
2. **Zone Flow**: `zones.json` → `zone-manager` → OPNsense firewall
3. **Build Chain**: `default.nix` → `nix-build` → `/home/tappaas/bin/` symlinks
4. **Update Chain**: `update-tappaas` → `update-node` → module `update.sh` scripts
5. **Install Chain**: `install.sh` → `common-install-routines.sh` → `Create-TAPPaaS-VM.sh`

### Most Connected Files

| File | Role |
|------|------|
| `common-install-routines.sh` | Sourced by all module install scripts |
| `Create-TAPPaaS-VM.sh` | Called by all module installers |
| `update.sh` (30-tappaas-cicd) | Most complex, depends on 15+ other files |
| `configuration.json` | Referenced by setup, update, and scheduling scripts |
| `zones.json` | Used by VM creation and zone-manager |

---

## Top-Level Entry Points

These are files that **no other files depend on** - they are the entry points into the system:

| Entry Point | Purpose | Trigger |
|-------------|---------|---------|
| `05-ProxmoxNode/install.sh` | Bootstrap first Proxmox node | Manual (curl from GitHub) |
| `30-tappaas-cicd/install1.sh` | Install CICD mothership | Manual (after VM creation) |
| `10-firewall/update.sh` | Update OPNsense firewall | Called by update-node |
| `35-backup/install.sh` | Install PBS backup server | Manual |
| `40-Identity/install.sh` | Install identity services | Manual |
| `update-tappaas` (CLI) | Scheduled node updates | Cron job (2 AM daily) |
| `check-disk-threshold.sh` | Monitor disk usage | Cron/manual |
| `rebuild-nixos.sh` | Rebuild NixOS VM | Manual |
| `test-config.sh` | Validate configurations | Manual |

---

## Dependency Graphs

### 1. Bootstrap Flow: `05-ProxmoxNode/install.sh`

Initial Proxmox node setup - downloads and configures the first node.

```mermaid
graph TD
    subgraph "Bootstrap Entry Point"
        A[05-ProxmoxNode/install.sh]
    end

    subgraph "Downloads from GitHub"
        B[Create-TAPPaaS-VM.sh]
        C[configuration.json]
        D[zones.json]
    end

    subgraph "External Tools"
        E[pveversion]
        F[apt]
        G[jq]
        H[curl]
        I[systemctl]
    end

    subgraph "Creates on Node"
        J[~/tappaas/Create-TAPPaaS-VM.sh]
        K[~/tappaas/configuration.json]
        L[~/tappaas/zones.json]
    end

    A -->|downloads| B
    A -->|downloads| C
    A -->|downloads| D
    A -->|uses| E
    A -->|uses| F
    A -->|uses| G
    A -->|uses| H
    A -->|uses| I
    A -->|creates| J
    A -->|creates| K
    A -->|creates| L

    B --> J
    C --> K
    D --> L
```

### 2. CICD Installation Flow: `30-tappaas-cicd/install1.sh`

Installs the CICD mothership VM that controls the entire TAPPaaS system.

```mermaid
graph TD
    subgraph "CICD Install Entry Point"
        A[30-tappaas-cicd/install1.sh]
    end

    subgraph "Phase 1: Git & SSH Setup"
        B[git clone TAPPaaS repo]
        C[ssh-keygen]
        D[ssh-copy-id to nodes]
    end

    subgraph "Phase 2: install2.sh"
        E[install2.sh]
        F[common-install-routines.sh]
        G[copy-jsons.sh]
        H[setup-caddy.sh]
    end

    subgraph "Phase 3: update.sh"
        I[update.sh]
        J[opnsense-controller build]
        K[update-tappaas build]
        L[zone-manager]
        M[update-HA.sh]
        N[update-cron.sh]
    end

    subgraph "Configuration Files"
        O[configuration.json]
        P[zones.json]
        Q[tappaas-cicd.json]
    end

    subgraph "Built CLI Tools"
        R[opnsense-controller]
        S[opnsense-firewall]
        T[zone-manager CLI]
        U[dns-manager]
        V[update-tappaas CLI]
        W[update-node]
    end

    A --> B
    A --> C
    A --> D
    A -->|sources| E

    E -->|sources| F
    E -->|calls| G
    E -->|sources| I
    E -->|calls| H

    G -->|reads| O
    G -->|reads| P

    H -->|reads| O
    H -->|uses| S

    I -->|sources| F
    I -->|builds| J
    I -->|builds| K
    I -->|calls| L
    I -->|calls| M
    I -->|calls| N
    I -->|reads| O
    I -->|reads| P
    I -->|reads| Q

    J -->|produces| R
    J -->|produces| S
    J -->|produces| T
    J -->|produces| U

    K -->|produces| V
    K -->|produces| W

    N -->|schedules| V
```

### 3. Update Scheduler Flow: `update-tappaas`

Automated scheduled updates for all TAPPaaS nodes.

```mermaid
graph TD
    subgraph "Cron Trigger"
        A[cron: 0 2 * * *]
    end

    subgraph "Update Scheduler"
        B[update-tappaas CLI]
        C[main.py]
    end

    subgraph "Configuration"
        D[configuration.json]
        E[tappaas-nodes array]
        F[updateSchedule per node]
    end

    subgraph "Per-Node Updates"
        G[update-node CLI]
        H[update_node.py]
    end

    subgraph "Module Update Scripts"
        I[10-firewall/update.sh]
        J[30-tappaas-cicd/update.sh]
        K[35-backup/update.sh]
        L[40-Identity/update.sh]
    end

    subgraph "Common Dependencies"
        M[update-json.sh]
        N[update-HA.sh]
        O[common-install-routines.sh]
    end

    A -->|triggers| B
    B --> C
    C -->|reads| D
    D -->|contains| E
    E -->|has| F

    C -->|for each scheduled node| G
    G --> H

    H -->|calls| I
    H -->|calls| J
    H -->|calls| K
    H -->|calls| L

    I -->|uses| M
    I -->|uses| N
    J -->|sources| O
    J -->|uses| M
    J -->|uses| N
```

### 4. OPNsense Controller Build: `opnsense-controller/default.nix`

Nix build for all OPNsense CLI tools.

```mermaid
graph TD
    subgraph "Nix Build Entry"
        A[default.nix]
    end

    subgraph "External Dependencies"
        B[oxl-opnsense-client from GitHub]
        C[python3Packages.httpx]
        D[python3Packages.ansible-core]
    end

    subgraph "Python Package"
        E[pyproject.toml]
        F[__init__.py]
    end

    subgraph "Core Modules"
        G[config.py]
        H[vlan_manager.py]
        I[dhcp_manager.py]
        J[firewall_manager.py]
    end

    subgraph "CLI Entry Points"
        K[main.py → opnsense-controller]
        L[firewall_cli.py → opnsense-firewall]
        M[zone_manager.py → zone-manager]
        N[dns_manager_cli.py → dns-manager]
    end

    subgraph "Runtime Config"
        O[~/.opnsense-credentials.txt]
        P[zones.json]
    end

    A -->|fetches| B
    A -->|requires| C
    A -->|requires| D
    A -->|builds| E

    E -->|defines| F
    F -->|exports| G
    F -->|exports| H
    F -->|exports| I
    F -->|exports| J

    K -->|imports| G
    K -->|imports| H
    K -->|imports| I
    K -->|imports| J

    L -->|imports| G
    L -->|imports| J

    M -->|imports| G
    M -->|imports| H
    M -->|imports| I
    M -->|imports| J
    M -->|reads| P

    N -->|imports| G
    N -->|imports| I

    G -->|reads| O
```

### 5. VM Creation Flow: `Create-TAPPaaS-VM.sh`

Creates VMs on Proxmox from JSON configuration.

```mermaid
graph TD
    subgraph "VM Creation Script"
        A[Create-TAPPaaS-VM.sh]
    end

    subgraph "Input Configuration"
        B["<vmname>.json"]
        C[zones.json]
    end

    subgraph "JSON Fields Used"
        D[vmid]
        E[node]
        F[imageType: clone/iso/img]
        G[zone0/zone1]
        H[trunks0/trunks1]
        I[cores/memory/diskSize]
    end

    subgraph "Zone Resolution"
        J[VLAN tags from zones.json]
        K[Bridge configuration]
        L[Network state validation]
    end

    subgraph "Proxmox Operations"
        M[qm create/clone]
        N[qm set - hardware config]
        O[qm resize - disk]
        P[cloud-init setup]
    end

    subgraph "External Tools"
        Q[jq]
        R[qm]
        S[pvesm]
        T[ssh]
        U[openssl]
    end

    A -->|reads| B
    A -->|reads| C

    B -->|provides| D
    B -->|provides| E
    B -->|provides| F
    B -->|provides| G
    B -->|provides| H
    B -->|provides| I

    C -->|provides| J
    C -->|provides| K
    C -->|provides| L

    A -->|executes| M
    A -->|executes| N
    A -->|executes| O
    A -->|executes| P

    A -->|uses| Q
    A -->|uses| R
    A -->|uses| S
    A -->|uses| T
    A -->|uses| U
```

### 6. Module Install Pattern: Generic Module Installation

Common pattern used by all module install scripts.

```mermaid
graph TD
    subgraph "Module Install Script"
        A["<module>/install.sh"]
    end

    subgraph "Common Routines"
        B[common-install-routines.sh]
        C[get_config_value function]
        D[info/warn functions]
    end

    subgraph "Module Configuration"
        E["<module>.json"]
        F[vmname]
        G[node]
        H[zone0]
    end

    subgraph "VM Creation"
        I[scp config to node]
        J[Create-TAPPaaS-VM.sh]
    end

    subgraph "Post-Install"
        K["<module>/update.sh"]
        L[Module-specific setup]
    end

    A -->|sources| B
    B -->|provides| C
    B -->|provides| D

    A -->|reads via| C
    C -->|parses| E
    E -->|contains| F
    E -->|contains| G
    E -->|contains| H

    A -->|copies| I
    I --> E
    A -->|calls on node| J
    J -->|creates VM from| E

    A -->|sources| K
    K -->|performs| L
```

### 7. Firewall Update Flow: `10-firewall/update.sh`

Updates the OPNsense firewall.

```mermaid
graph TD
    subgraph "Firewall Update Entry"
        A[10-firewall/update.sh]
    end

    subgraph "JSON Update"
        B[update-json.sh firewall]
        C[firewall.json]
    end

    subgraph "HA Configuration"
        D[update-HA.sh firewall]
        E[HANode field]
        F[ha-manager]
        G[pvesr replication]
    end

    subgraph "OPNsense Update"
        H["ssh root#64;firewall.mgmt.internal"]
        I[opnsense-update -bkp]
        J[Base system update]
        K[Kernel update]
        L[Package update]
    end

    subgraph "Reboot Check"
        M[uname -r running kernel]
        N[freebsd-version -k installed]
        O[Compare versions]
        P[Warn if reboot needed]
    end

    A -->|calls| B
    B -->|updates| C

    A -->|calls| D
    D -->|reads| E
    D -->|manages| F
    D -->|manages| G

    A -->|connects| H
    H -->|runs| I
    I -->|performs| J
    I -->|performs| K
    I -->|performs| L

    A -->|checks| M
    A -->|checks| N
    M --> O
    N --> O
    O -->|if different| P
```

### 8. Caddy Setup Flow: `setup-caddy.sh`

Sets up Caddy reverse proxy on OPNsense.

```mermaid
graph TD
    subgraph "Caddy Setup Entry"
        A[setup-caddy.sh]
    end

    subgraph "Configuration"
        B[configuration.json]
        C[domain field]
        D[email field]
    end

    subgraph "SSH to Firewall"
        E["root#64;firewall.mgmt.internal"]
    end

    subgraph "Package Installation"
        F[pkg install os-caddy]
    end

    subgraph "Web GUI Reconfiguration"
        G[PHP: set port to 8443]
        H[configctl webgui restart]
    end

    subgraph "Firewall Rules"
        I{opnsense-firewall available?}
        J[opnsense-firewall CLI]
        K[PHP fallback method]
        L[HTTP port 80 rule]
        M[HTTPS port 443 rule]
        N[configctl filter reload]
    end

    subgraph "Service Enable"
        O[rc.d/caddy enable]
    end

    A -->|reads| B
    B -->|extracts| C
    B -->|extracts| D

    A -->|connects| E
    E -->|runs| F
    E -->|runs| G
    G -->|triggers| H

    A --> I
    I -->|yes| J
    I -->|no| K

    J -->|creates| L
    J -->|creates| M
    K -->|creates| L
    K -->|creates| M

    L --> N
    M --> N

    A -->|runs| O
```

---

## File Reference Table

### Root Configuration Files

| File | Dependencies | Dependents |
|------|--------------|------------|
| `configuration.json` | None | setup-caddy.sh, update-tappaas/main.py, copy-jsons.sh, install2.sh |
| `zones.json` | None | Create-TAPPaaS-VM.sh, zone-manager, copy-jsons.sh, install2.sh |
| `*-fields.json` | None | Documentation only |

### Shell Scripts

| File | Sources/Calls | Called By |
|------|---------------|-----------|
| `common-install-routines.sh` | jq | All module install.sh, update.sh (cicd) |
| `copy-jsons.sh` | configuration.json, zones.json | install2.sh |
| `update-json.sh` | Module JSON files | All update.sh scripts |
| `update-HA.sh` | Module JSON files | All update.sh scripts |
| `setup-caddy.sh` | configuration.json, opnsense-firewall | install2.sh |
| `update-cron.sh` | update-tappaas | update.sh (cicd) |
| `rebuild-nixos.sh` | nixos-rebuild | Manual |
| `resize-disk.sh` | Module JSON files | check-disk-threshold.sh |

### Python Modules

| File | Imports | Provides |
|------|---------|----------|
| `config.py` | os, dataclasses | Config class |
| `vlan_manager.py` | config, oxl_opnsense_client | VlanManager, Vlan |
| `dhcp_manager.py` | config, oxl_opnsense_client | DhcpManager, DhcpRange, DhcpHost |
| `firewall_manager.py` | config, oxl_opnsense_client | FirewallManager, FirewallRule |
| `zone_manager.py` | config, vlan/dhcp/firewall_manager | ZoneManager, Zone |
| `firewall_cli.py` | config, firewall_manager | opnsense-firewall CLI |
| `dns_manager_cli.py` | config, dhcp_manager | dns-manager CLI |
| `main.py` (opnsense-controller) | all managers | opnsense-controller CLI |
| `main.py` (update-tappaas) | configuration.json | update-tappaas CLI |

### Nix Files

| File | Imports/Builds | Outputs |
|------|----------------|---------|
| `opnsense-controller/default.nix` | oxl-opnsense-client, python3 | opnsense-controller, opnsense-firewall, zone-manager, dns-manager |
| `update-tappaas/default.nix` | python3 | update-tappaas, update-node |
| `tappaas-cicd.nix` | hardware-configuration.nix, opnsense-controller | NixOS system config |
| `tappaas-nixos.nix` | hardware-configuration.nix | NixOS template |
| `identity.nix` | hardware-configuration.nix | Identity VM config |

---

## External Dependencies

### System Tools Required

| Tool | Used By | Purpose |
|------|---------|---------|
| `jq` | All scripts | JSON parsing |
| `ssh`/`scp` | All scripts | Remote operations |
| `git` | install1.sh, update.sh | Repository management |
| `curl` | 05-ProxmoxNode/install.sh | Download files |
| `nix-build` | update.sh | Build Nix packages |
| `nixos-rebuild` | update.sh, rebuild-nixos.sh | Apply NixOS configs |
| `qm` | Create-TAPPaaS-VM.sh, resize-disk.sh | Proxmox VM management |
| `pvesh` | Multiple scripts | Proxmox API |
| `ha-manager` | update-HA.sh | Proxmox HA |
| `pvesr` | update-HA.sh | Proxmox replication |
| `crontab` | update-cron.sh | Scheduling |

### Python Libraries

| Library | Package | Purpose |
|---------|---------|---------|
| `oxl-opnsense-client` | opnsense-controller | OPNsense API client |
| `httpx` | opnsense-controller | HTTP requests |
| `ansible-core` | opnsense-controller | Module validation |

### Remote Hosts

| Host | Accessed By | Purpose |
|------|-------------|---------|
| `firewall.mgmt.internal` | setup-caddy.sh, 10-firewall/update.sh, zone-manager | OPNsense firewall |
| `tappaas1.mgmt.internal` | Multiple scripts | Primary Proxmox node |
| `<node>.mgmt.internal` | copy-jsons.sh, update scripts | All Proxmox nodes |
