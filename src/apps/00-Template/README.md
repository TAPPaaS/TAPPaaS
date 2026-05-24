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
| NixOS VM clone | `imageType: "clone"`, `image: "<vmid>"`, `ostype: "l26"`, `os: "nixos"`, `cloudInit: "false"` |
| Debian/Ubuntu cloud image | `imageType: "clone"`, `image: "<vmid>"`, `ostype: "l26"`, `os: "debian"`, `cloudInit: "true"` |
| Windows Server 2025 clone | `imageType: "clone"`, `image: "8081"`, `ostype: "win11"`, `os: "windows"`, `cloudInit: "false"` |
| ISO install (Linux) | `imageType: "iso"`, `image: "<filename>"`, `imageLocation: "<url>"`, `ostype: "l26"` |
| ISO install (Windows) | `imageType: "iso"`, `image: "<filename>"`, `ostype: "win11"`, `cloudInit: "false"` |
| Disk image (e.g. OPNsense) | `imageType: "img"`, `image: "<filename>"`, `imageLocation: "<url>"` |
| High Availability | Add `HANode: "tappaas2"`, `replicationSchedule: "*/15"` |
| Multi-NIC | Add `bridge1`, `zone1` fields |

#### Choosing `ostype` and `os`

These two fields serve different purposes and are both needed for non-default OS types:

| Field | What it controls | Set it to |
|-------|-----------------|-----------|
| `ostype` | **QEMU hardware profile** — clock source, ACPI behaviour, Hyper-V enlightenments, TPM availability | The guest OS family — see table below |
| `os` | **TAPPaaS bootstrap logic** — which cloud-init snippet to attach, whether to deploy an OOBE answer ISO | The OS family string — see table below |

**`ostype` quick-reference:**

| Guest OS | `ostype` | Notes |
|----------|----------|-------|
| NixOS, Debian, Ubuntu, any modern Linux | `l26` | Default. The `l` is a lowercase letter L (Linux), not digit 1. Enables KVM paravirtual clock, UTC hardware clock. |
| Windows Server 2025, Windows 11 | `win11` | Enables Windows ACPI, local-time hardware clock, Hyper-V enlightenments, TPM 2.0. Required for Server 2025. |
| Windows Server 2019/2016, Windows 10 | `win10` | Same Windows treatment as `win11`, earlier ACPI profile. |
| Unknown / generic | `other` | Minimal optimisation. Use only when nothing else fits. |

**Compatibility note:** `ostype` does not prevent booting — a wrong value causes clock drift or incorrect power-management but the VM will still start. However, Windows Server 2025 specifically requires `win11` for TPM 2.0, which Windows enforces during install.

#### Field Reference

For complete field definitions including all possible values, defaults, and validation rules, see:

**[module-fields.json](../../foundation/module-fields.json)**

### install.sh

Installation script called with the module name as an argument when the module is installed. 
See [README-install.md](./README-install.md) for details

### update.sh

Update script called periodically to keep the module updated.

- Called with module name as argument
- TAPPaaS calls this script on a periodic basis per the global `updateSchedule`
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

## Debugging VMs

### VM console screenshot (all OS types)

When you can't SSH into a VM — during setup, after a failed boot, or for a Windows OOBE check — take a screenshot via the Proxmox QEMU monitor. This works for NixOS, Windows, Debian, and any other VM type.

```bash
# Capture and base64-encode the screen (run from tappaas-cicd or any node with SSH access)
ssh root@<node>.mgmt.internal "qm screendump <VMID> > /tmp/screen.ppm && base64 /tmp/screen.ppm"
```

Copy the base64 output, then decode locally:

```bash
# macOS
echo "<paste base64 here>" | base64 -d | open -a Preview -f

# Linux (ImageMagick)
echo "<paste base64 here>" | base64 -d | display
```

Replace `<node>` with the Proxmox node name (e.g., `tappaas1`) and `<VMID>` with the VM ID.
The VMID is in the module's JSON file (`vmid` field) and listed in `src/modules.json`.

### Proxmox QEMU monitor

```bash
ssh root@<node>.mgmt.internal "qm monitor <VMID>"
```

Gives low-level access to the QEMU instance (disk I/O, CPU state, device info).

## Naming Conventions

- Module name = VM name = hostname = DNS name
- Use lowercase with hyphens for multi-word names (e.g., `home-assistant`, `open-webui`)
- Use descriptive names (e.g., `nextcloud`, `vaultwarden`, `windows-server`)

## Deploying multiple instances

Any VM-backed module can be deployed multiple times using `deploy-instances.sh`:

```bash
deploy-instances.sh <module> <count>
```

`count` is the number of **new** instances to add on top of any already installed — not the
total desired count. Instance 1 uses the original `vmname` and `vmid` from the JSON. Additional
instances get a `-<n>` suffix and the next free VMID in the same hundreds block. A confirmation
table is shown before anything is installed.

The module JSON does not need any changes to support this — the script handles all naming and
VMID assignment automatically.
