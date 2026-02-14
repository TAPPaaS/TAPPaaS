# Template Module

## Introduction

This is a template module that serves as a starting point for creating new TAPPaaS modules.

A TAPPaaS module typically runs in its own VM and provides a specific service or capability. The module name becomes the VM name, hostname, and DNS name.

## Creating a New Module

### Step 1: Copy the Template

Decide on a name for your module. Typically this is the name of the main software product or the capability being delivered.

```bash
cp -r 00-Template myModule
cd myModule
```

### Step 2: Rename Files

Replace template files with your module name:

```bash
mv README-template.md README.md
mv template.json myModule.json
```

For NixOS-based modules, rename the .nix file:
```bash
mv template.nix myModule.nix
```

For non-NixOS modules, remove it:
```bash
rm template.nix
```

### Step 3: Configure the Module

Edit each file as described below.

## Module Files

### myModule.json

The JSON file defines all external parameters of the module: VM size, ID, name, VLAN membership, etc. The automated create, install, and update scripts of TAPPaaS use this file.

Modify it to set good defaults for your module. Installers can further customize through this file.

#### Example Configuration

```json
{
    "version": "1.0.0",
    "description": "My awesome service module",
    "vmid": 200,
    "node": "tappaas1",
    "cores": 2,
    "memory": 4096,
    "diskSize": "16G",
    "storage": "tanka1",
    "imageType": "clone",
    "image": "9000",
    "zone0": "srv",
    "cloudInit": "true"
}
```

#### Common Configurations

| Use Case | Key Settings |
|----------|-------------|
| NixOS clone | `imageType: "clone"`, `image: "<template-vmid>"` |
| ISO install | `imageType: "iso"`, `image: "<filename>"`, `imageLocation: "<url>"` |
| Disk image | `imageType: "img"`, `image: "<filename>"`, `imageLocation: "<url>"` |
| High Availability | Add `HANode: "tappaas2"`, `replicationSchedule: "*/15"` |
| Multi-NIC | Add `bridge1`, `zone1` fields |

#### Field Reference

For complete field definitions including all possible values, defaults, and validation rules, see:

**[module-fields.json](../../foundation/module-fields.json)**

### install.sh

Installation script called with the module name as an argument when the module is installed. 
See [README-install.md](./README-install.md) for details

### update.sh

Update script called periodically to keep the module updated.

- Called with module name as argument
- TAPPaaS calls this script on a periodic basis per the node's `updateSchedule`
- Should handle incremental updates to the module

### myModule.nix

NixOS configuration file for NixOS-based modules.

- Used by the default `install.sh` to rebuild the VM configuration
- Remove this file for non-NixOS modules

## Module Locations

| Type | Directory |
|------|-----------|
| Foundation modules | `src/foundation/<NN>-<name>/` |
| Application modules | `src/apps/<name>/` |
| Service modules | `src/modules/<name>/` |

## Naming Conventions

- Module name = VM name = hostname = DNS name
- Use lowercase, avoid hyphens where possible
- Use descriptive names (e.g., `nextcloud`, `homeassistant`, `grafana`)
