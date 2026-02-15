# TAPPaaS Foundation Layer - Dependency Documentation

This document describes the program dependencies within the `src/foundation/` directory of TAPPaaS.

## Summary

| Directory | Programs | Description |
|-----------|----------|-------------|
| 30-tappaas-cicd/scripts/ | 12 | Core helper scripts |
| 30-tappaas-cicd/opnsense-controller/ | 4 | OPNsense Python CLI tools |
| 30-tappaas-cicd/update-tappaas/ | 2 | Update scheduler |
| 30-tappaas-cicd/test-vm-creation/ | 3 | VM creation test suite |
| 30-tappaas-cicd/ | 4 | Main installation scripts |
| 05-ProxmoxNode/ | 2 | Node bootstrap scripts |
| 10-firewall/ | 1 | Firewall update |
| 35-backup/ | 2 | Backup server scripts |
| 40-Identity/ | 2 | Identity module scripts |

### Key Dependency Chains

1. **Install Chain**: `install1.sh` → `install2.sh` → `create-configuration.sh` + `setup-caddy.sh` + `update.sh`
2. **Update Chain**: `update-tappaas` → `update-node` → module `update.sh` scripts
3. **VM Creation Chain**: `install-vm.sh` → `copy-update-json.sh` → `Create-TAPPaaS-VM.sh`
4. **Zone Management Chain**: `zone-manager` → OPNsense API → firewall configuration
5. **Test Chain**: `test.sh` → `install.sh` → `test-vm.sh`

### Most Connected Programs

| Program | Role |
|---------|------|
| `common-install-routines.sh` | Sourced by all module scripts |
| `install-vm.sh` | Called by all module install scripts |
| `update-tappaas` | Orchestrates all node updates |
| `zone-manager` | Manages all OPNsense zones |

---

## Top-Level Entry Points

These programs are NOT called by other TAPPaaS programs - they are entry points:

| Entry Point | Purpose | Trigger |
|-------------|---------|---------|
| `05-ProxmoxNode/install.sh` | Bootstrap first Proxmox node | Manual (curl from GitHub) |
| `30-tappaas-cicd/install1.sh` | Install CICD mothership | Manual (after VM creation) |
| `30-tappaas-cicd/test.sh` | Run VM creation test suite | Manual/CI |
| `update-tappaas` | Scheduled node updates | Cron job |
| `create-configuration.sh` | Generate system configuration | Manual (initial setup) |
| `check-disk-threshold.sh` | Monitor disk usage | Cron |
| `test-config.sh` | Validate configurations | Manual |
| `opnsense-controller` | Direct OPNsense management | Manual |

---

## Dependency Graphs

### 1. Bootstrap Flow: `05-ProxmoxNode/install.sh`

Initial Proxmox node setup - downloads scripts and configuration files.

```mermaid
graph TD
    A[05-ProxmoxNode/install.sh] -->|downloads| B[Create-TAPPaaS-VM.sh]
    A -->|downloads| D[zones.json]

    B -->|reads| D
    B -->|reads| E["<module>.json"]
```

### 2. CICD Installation Flow: `install1.sh` then `install2.sh`

Two-phase installation with reboot in between.

```mermaid
graph TD
    subgraph "Phase 1: install1.sh"
        A[install1.sh] -->|clones| B[TAPPaaS repo]
        A -->|runs| C[nixos-rebuild]
        A -->|creates| D[SSH keys]
        A -->|requires| E[reboot]
    end

    subgraph "Phase 2: install2.sh (after reboot)"
        F[install2.sh] -->|sources| G[create-configuration.sh]
        F -->|calls| H[setup-caddy.sh]
        F -->|sources| I[update.sh]

        G -->|creates| J[configuration.json]

        H -->|reads| J
        H -->|calls| K[opnsense-firewall]

        I -->|sources| L[common-install-routines.sh]
        I -->|calls| M[zone-manager]
        I -->|calls| N[update-HA.sh]
        I -->|calls| O[update-cron.sh]

        L -->|reads| P[module-fields.json]
        L -->|reads| Q[zones.json]

        M -->|reads| Q

        O -->|schedules| R[update-tappaas]
    end
```

### 3. Update Scheduler Flow: `update-tappaas`

Automated scheduled updates for all TAPPaaS nodes.

```mermaid
graph TD
    A[update-tappaas] -->|reads| B[configuration.json]
    A -->|calls| C[update-node]

    C -->|calls| D[10-firewall/update.sh]
    C -->|calls| E[30-tappaas-cicd/update.sh]
    C -->|calls| F[35-backup/update.sh]
    C -->|calls| G[40-Identity/update.sh]

    D -->|calls| H[update-HA.sh]

    E -->|sources| I[common-install-routines.sh]
    E -->|calls| J[zone-manager]
    E -->|calls| H
    E -->|calls| K[update-cron.sh]

    K -->|schedules| A
```

### 4. VM Creation Flow: Module Installation

Used by all module install scripts.

```mermaid
graph TD
    A["module/install.sh"] -->|sources| B[install-vm.sh]

    B -->|sources| C[copy-update-json.sh]
    B -->|sources| D[common-install-routines.sh]

    C -->|reads| E[module-fields.json]
    C -->|copies| F["<module>.json"]

    D -->|reads| E
    D -->|reads| G[zones.json]

    B -->|scp to node| H["<module>.json"]
    B -->|ssh calls| I[Create-TAPPaaS-VM.sh]

    I -->|reads| H
    I -->|reads| G

    A -->|calls| J[update-os.sh]
    A -->|calls| K[update-HA.sh]
```

### 5. Test Suite Flow: `30-tappaas-cicd/test.sh`

VM creation and validation tests.

```mermaid
graph TD
    A[30-tappaas-cicd/test.sh] -->|calls| B[test-vm-creation/test.sh]

    B -->|for each test| C[install.sh]
    B -->|for each test| D[test-vm.sh]

    C -->|sources| E[install-vm.sh]
    C -->|calls| F[update-os.sh]
    C -->|calls| G[update-HA.sh]

    E -->|sources| H[copy-update-json.sh]
    E -->|sources| I[common-install-routines.sh]
    E -->|ssh calls| J[Create-TAPPaaS-VM.sh]

    D -->|sources| I
```

### 6. OPNsense Controller: `opnsense-controller`

Direct management of OPNsense firewall.

```mermaid
graph TD
    A[opnsense-controller] -->|subcommand| B[zone-manager]
    A -->|subcommand| C[dns-manager]
    A -->|subcommand| D[opnsense-firewall]

    B -->|reads| E[zones.json]
    B -->|manages| F[VLANs]
    B -->|manages| G[DHCP ranges]
    B -->|manages| H[Firewall rules]

    C -->|manages| I[DNS entries]

    D -->|manages| H
```

### 7. Disk Management Flow: `check-disk-threshold.sh`

Automated disk monitoring and resizing.

```mermaid
graph TD
    A[check-disk-threshold.sh] -->|reads| B["<module>.json"]
    A -->|calls| C[resize-disk.sh]

    C -->|reads| B
```

### 8. Configuration Generation: `create-configuration.sh`

Creates the main configuration file from cluster state.

```mermaid
graph TD
    A[create-configuration.sh] -->|queries| B["Proxmox cluster (pvecm)"]
    A -->|creates| C[configuration.json]

    C -->|used by| D[setup-caddy.sh]
    C -->|used by| E[update-tappaas]
    C -->|used by| F[update.sh scripts]
```

---

## Configuration File Dependencies

| Config File | Created By | Used By |
|-------------|------------|---------|
| `configuration.json` | create-configuration.sh | update-tappaas; setup-caddy.sh; module update.sh |
| `zones.json` | Manual/git | zone-manager; Create-TAPPaaS-VM.sh; common-install-routines.sh |
| `module-fields.json` | Manual/git | common-install-routines.sh; copy-update-json.sh |

---

## Install Locations

| Location | Programs |
|----------|----------|
| `/home/tappaas/bin/` | All CLI tools and helper scripts (symlinks) |
| `/root/tappaas/` (Proxmox nodes) | Create-TAPPaaS-VM.sh |
| `src/foundation/*/` | Module install.sh and update.sh scripts |
