# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

TAPPaaS (Trusted - Automated - Private Platform as a Service) is a self-hosted platform designed for SMBs, government institutions, and home users who need privacy and data ownership. It runs on commodity hardware using Proxmox as the hypervisor with NixOS-based VMs.

## Architecture

### Foundation Layer (src/foundation/)
Foundation modules must be installed in numbered order:
1. `05-ProxmoxNode` - First Proxmox node setup
2. `10-firewall` - OPNsense firewall configuration
3. `15-AdditionalPVE-Nodes` - Add cluster nodes
4. `20-tappaas-nixos` - NixOS VM template creation
5. `30-tappaas-cicd` - "Mothership" VM that controls the entire TAPPaaS system
6. `35-pbs` - Proxmox Backup Server
7. `40-Identity` - Secrets and identity management

### Service Modules (src/modules/)
Each module contains:
- `<vmname>.json` - VM configuration (cores, memory, storage, network zones)
- `<vmname>.nix` - NixOS configuration for the VM
- `install.sh` - Called by tappaas-cicd to install the module
- `update.sh` - Called regularly to patch running installations

### Configuration Files
- `src/foundation/configuration.json` - Global TAPPaaS configuration (domain, email, node count)
- `src/foundation/zones.json` - Network zone definitions with VLAN tags and access rules

## Key Scripts

### VM Creation
`src/foundation/05-ProxmoxNode/Create-TAPPaaS-VM.sh <vmname>` - Creates VMs from JSON config. Supports three image types:
- `clone` - Clone from existing Proxmox template
- `iso` - Create from ISO image
- `img` - Import from disk image

### Module Installation
Install scripts source common routines from `src/foundation/30-tappaas-cicd/scripts/common-install-routines.sh` which provides:
- `get_config_value()` - Extract values from module JSON configs
- JSON validation and error handling

## Network Zones
Defined in `zones.json` with VLAN tags. Key zones:
- `mgmt` (untagged) - Management network for TAPPaaS infrastructure
- `srv` (VLAN 210) - Service network for business services
- `dmz` (VLAN 610) - Only zone allowing internet pinholes
- `private` (VLAN 310) - User client network
- `iot` (VLAN 410) - IoT devices

## Naming Conventions
- VM name, hostname, and service name are identical (e.g., `nextcloud`)
- Node names: `tappaasY` where Y is a sequence number (e.g., `tappaas1`, `tappaas2`, `tappaas3`)
- Storage pools: `tankXY` where X indicates type and Y is the node number (e.g., `tanka1`)
- Capitalization preferred over hyphens (e.g., `HomeAssistant`)

## First Node Bootstrap
```bash
BRANCH="main"
curl -fsSL https://raw.githubusercontent.com/TAPPaaS/TAPPaaS/$BRANCH/src/foundation/05-ProxmoxNode/install.sh >install-PVE.sh
chmod +x install-PVE.sh
./install_PVE.sh $BRANCH
```

## NixOS Rebuild (from tappaas-cicd)
```bash
nixos-rebuild --target-host tappaas@<vmname>.<zone>.internal --use-remote-sudo switch -I nixos-config=./<vmname>.nix
```

## JSON Configuration Parameters
Key VM config fields in `<vmname>.json`:
- `vmid` (required) - Unique VM ID across all nodes
- `node` - Proxmox node (default: tappaas1)
- `imageType` - clone/iso/img
- `image` - Template VMID (clone) or filename (iso/img)
- `zone0`/`zone1` - Network zone names from zones.json
- `cloudInit` - Enable cloud-init (default: true)
