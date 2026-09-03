# Template Module

## Introduction

This is a template module that serves as a starting point for creating new TAPPaaS modules.

A TAPPaaS module typically runs in its own VM and provides a specific service or capability. The module name becomes the VM name, hostname, and DNS name.

> **Where will your module be maintained?** Before you start, decide which repository your module
> will live in — the open-source TAPPaaS repo (contributed via a Pull Request), a community
> repository, or a private/downstream one — because that shapes your development workflow. See
> [Git & repository topology](../../foundation/tappaas-cicd/DESIGN-GIT.md).

## Creating a New Module

The step-by-step path — copy the template, rename, configure, `module-manager module add` —
is the quick start in **[DEVELOP.md](DEVELOP.md)**. This page is the reference behind it:
every file, field and convention in detail.

Pick a module name (typically the main software product or the capability delivered);
it becomes the VM name, hostname and DNS name. Optionally record authorship in
`AUTHORS.md` (edit the placeholder line, or delete the file — it is optional; see
`src/foundation/schemas/README.md` for the contributor/author/maintainer role model).

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

#### Template dependencies and `autoInstall`

Some modules clone from a **VM template** rather than downloading an image directly (e.g. `windows-server` clones from `tappaas-winserver`, VMID 8081). If the template doesn't exist when you run `module-manager module add`, TAPPaaS checks the template JSON for the `autoInstall` flag:

| `autoInstall` | What happens |
|---------------|-------------|
| `true` | Template is built automatically before the clone proceeds — no operator input needed (e.g. `tappaas-winserver` uses `autounattend.xml`) |
| `false` | Install stops with an actionable error — operator must build the template manually first (e.g. `tappaas-nixos` requires completing the graphical installer) |

This flag lives in the **template's** JSON (`src/foundation/templates/tappaas-winserver.json`), not in the consuming module's JSON. If you are building a new template module, set `autoInstall: true` only if the entire install can run without anyone at the console.

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

**[module-fields.json](../../foundation/schemas/module-fields.json)**

### install.sh

Installation script called with the module name as an argument when the module is installed. 
See [README-install-sh.md](./README-install-sh.md) for details

### update.sh

Update script called periodically to keep the module updated.

- Called with module name as argument
- TAPPaaS calls this script on a periodic basis per the global `updateSchedule`
- Should handle incremental updates to the module

### myModule.nix

NixOS configuration file for NixOS-based modules.

- Used by the default `install.sh` to rebuild the VM configuration
- Remove this file for non-NixOS modules

## Providing a service

Beyond installing itself, a module can **provide services** that *other* modules depend on (declared
in its `provides`; consumed via another module's `dependsOn`). A provider implements lifecycle hooks
under `services/<service-name>/`, which TAPPaaS runs **on the provider** whenever a dependent module
is installed or updated.

```
<module>/
├── <module>.json
├── install.sh                    # the module's own install
├── update.sh                     # the module's own update
└── services/
    └── <service-name>/
        ├── install-service.sh    # run when a dependent installs
        ├── update-service.sh     # run when a dependent updates
        └── fields.json           # only if this service owns declared fields
```

`install-service.sh` is called with the **dependent** module's name; it reads that module's config
from `/home/tappaas/config/<dependent>.json`, provisions what the dependent needs, and configures the
service to support it. `update-service.sh` is the same for updates. (Deletion runs the dependency
chain in reverse — see [ADR-003](<../../../docs/ADR/ADR-003 - Dependency management in TAPPaaS.md>).)

### Optional integrations — `integratesWith`

`dependsOn` is a **hard** requirement: a provider that is not installed blocks the install.
`integratesWith` (#501) is the **soft** counterpart — same `provider:service` shape, same
`install/update/delete-service.sh` wiring — but a provider that is not installed is silently
ignored instead of blocking, and when that provider is *later* installed it auto-wires the
pre-existing integrators. Use it for a capability the module can run without (e.g. LiteLLM
`integratesWith: ["vllm-amd:inference"]` — it uses a local inference backend if one exists,
and functions fine if none is deployed). A coordinate belongs in exactly one of the two lists.

Writing a service script:

1. Create `<module>/services/<service-name>/`.
2. Add `install-service.sh` (initial provisioning) and `update-service.sh` (ongoing updates).
3. `source` the shared helpers (`common-install-routines.sh`) for `get_config_value`, `check_json`, …
4. Read the dependent's fields with `get_config_value` (respecting defaults).
5. Use `set -euo pipefail` for strict error handling.

### If your service owns declared fields — `fields.json`

A field in [module-fields.json](../../foundation/schemas/module-fields.json) whose
`usedBy` names your `<module>:<service>` coordinate is **yours**, and you must
declare what changing it costs after install: a `fields.json` alongside the
scripts, or `module-manager validate` errors. That declaration is what lets an
operator run `module modify <m> --set yourField=…` instead of hand-editing
deployed config (ADR-020).

Most services own nothing — fourteen of TAPPaaS's twenty-five do registration and
wiring, which is not field drift — and need no `fields.json` at all.

**→ [README-service-provider.md](README-service-provider.md)** walks through it:
choosing a change class, when `apply: "reconcile"` is the right answer (usually),
and when you additionally need a `report-service.sh`.

Real examples to copy from: `cluster/services/vm/install-service.sh` (creates a VM for a dependent),
`cluster/services/ha/update-service.sh` (HA / ZFS replication), and
`network/services/proxy/install-service.sh` (Caddy reverse-proxy registration for a dependent's
`network:proxy`). The full field reference for what a dependent can pass is
[module-fields.json](../../foundation/schemas/module-fields.json).

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
The VMID is in the module's JSON file (`vmid` field) and listed in `src/module-catalog.json`.

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
