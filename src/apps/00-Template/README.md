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

## Module documentation (ADR-013)

Every module carries Diataxis-split documentation ([ADR-013](<../../../docs/ADR/ADR-013 - Documentation Structure and Standards.md>) §4). Copy the skeletons and fill them in:

| File | Copy from | Audience | Required? |
|------|-----------|----------|-----------|
| `README.md` | [`README-template.md`](./README-template.md) | end user — *what / why / what-not* | **Mandatory** (catalog lint) |
| `INSTALL.md` | [`INSTALL.md`](./INSTALL.md) | TAPPaaS admin — *how to install / operate* | **Mandatory** (catalog lint) |
| `DESIGN.md` | [`DESIGN-template.md`](./DESIGN-template.md) | module developers — *how / why it is built* | Expected where internals are non-trivial |

`README.md` and `INSTALL.md` are public web pages (synced to tappaas.org); `DESIGN.md` stays
in-repo for contributors. The cross-module "how to build any module" walkthrough is
[DEVELOP.md](./DEVELOP.md) — a different artifact from a module's own `DESIGN.md`.

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
    "cloudInit": "true",
    "dependsOn": ["cluster:vm", "templates:nixos", "backup:vm", "network:proxy", "network:rules"],
    "provides": []
}
```

`dependsOn` is how the module composes with the rest of the platform — a VM,
a template to clone, a backup job, a reverse-proxy entry, firewall rules. See
[Dependencies and services](#dependencies-and-services) below for the full model.

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

## Dependencies and services

TAPPaaS modules compose through **services**. A service is a capability one module
offers and another consumes, named by a `provider:service` **coordinate** — e.g.
`cluster:vm`, `network:proxy`, `identity:identity`. A module declares the coordinates
it needs; TAPPaaS derives install order from those declarations rather than hardcoding
it ([ADR-003](<../../../docs/ADR/ADR-003 - Dependency management in TAPPaaS.md>)), then
runs each provider's hooks to wire the dependent up.

Three `<module>.json` fields express this:

| Field | Meaning | If the provider is not installed |
|-------|---------|----------------------------------|
| `dependsOn` | **hard** requirement — the module cannot run without it | install is blocked |
| `integratesWith` | **soft** — used if present | silently skipped; auto-wired if the provider is added later |
| `provides` | the services **this** module offers to others (names only) | — |

### Depending on other services — `dependsOn`

Almost every VM-backed module needs a VM created, a template to clone, a backup job,
and usually a reverse-proxy entry and firewall rules — declared as coordinates.
Nextcloud, for example, consumes six services and provides one:

```json
{
    "dependsOn": ["cluster:vm", "templates:nixos", "backup:vm", "network:proxy", "network:rules", "identity:identity"],
    "provides": ["fileservice"]
}
```

`module-manager module add nextcloud` installs each provider first (if it is not
already present), then calls that provider's `install-service.sh` with `nextcloud`
as its argument, so each one provisions exactly what nextcloud declared — a VM, a
backup enrolment, a Caddy entry, firewall rules, an SSO client. `module modify` runs
the `update-service.sh` counterparts; deletion runs the chain in reverse.

### Optional integrations — `integratesWith`

`integratesWith` is the **soft** counterpart to `dependsOn`: same `provider:service`
shape, same `install`/`update`/`delete-service.sh` wiring — but a provider that is not
installed is silently ignored instead of blocking, and when that provider is *later*
installed it auto-wires the pre-existing integrators. Use it for a capability the
module can run without — LiteLLM `integratesWith: ["vllm-amd:inference"]` uses a local
inference backend if one exists and functions fine if none is deployed. A coordinate
belongs in exactly one of the two lists.

### Foundation services you can depend on

The foundation layer offers these `provider:service` coordinates — the building blocks
nearly every module composes from. Each links to its contract: what it does for a
dependent, and which `<module>.json` fields the dependent passes to it.

| Coordinate | What it does for your module |
|------------|------------------------------|
| [`cluster:vm`](../../foundation/cluster/services/vm/README.md) | Creates and converges the module's Proxmox QEMU guest — the VM most modules run in. |
| [`cluster:lxc`](../../foundation/cluster/services/lxc/README.md) | Creates and converges a Proxmox LXC container instead of a full VM. |
| [`cluster:ha`](../../foundation/cluster/services/ha/README.md) | Places the guest under Proxmox HA, with node-affinity and ZFS replication. |
| [`backup:vm`](../../foundation/backup/services/vm/README.md) | Enrols the guest in the managed Proxmox Backup Server job — a whole-guest snapshot. |
| [`backup:filesystem`](../../foundation/backup/services/filesystem/) | Captures **named paths inside** the guest instead of the whole guest. Needs `backup.filesystemPaths`; NixOS guests only. |
| [`network:proxy`](../../foundation/network/services/proxy/README.md) | Publishes the module through Caddy — its public face and TLS termination. |
| [`network:rules`](../../foundation/network/services/rules/README.md) | Compiles the module's declared firewall surface into OPNsense rules. |
| [`network:dns`](../../foundation/network/services/dns/README.md) | Registers the module's DNS record on the resolver. |
| [`network:nat`](../../foundation/network/services/nat/README.md) | Adds destination-NAT (port-forward) rules on OPNsense. |
| [`network:discovery`](../../foundation/network/services/discovery/README.md) | Relays mDNS / broadcast discovery across zone boundaries. |
| [`identity:identity`](../../foundation/identity/services/identity/README.md) | Wires the module into single sign-on — OIDC client, redirect URIs, group access. |
| [`templates:windows`](../../foundation/templates/services/windows/README.md) | Windows VM lifecycle (OOBE and beyond) for Windows-based modules. |

A few further coordinates have no standalone page yet — `templates:nixos` and
`templates:debian` (the Linux template clones most modules use) and
`identity:accessControl` — documented on their parent module:
[templates](../../foundation/templates/README.md), [identity](../../foundation/identity/README.md),
[backup](../../foundation/backup/README.md). The full reference for every field a dependent
can pass is [module-fields.json](../../foundation/schemas/module-fields.json).

### Getting your module backed up

Backup is **opt-in**: a module is backed up only if it asks to be.

```jsonc
"dependsOn": ["backup:vm"],            // the whole guest, the usual choice
"backup": {
  "schedule": "weekly",                // daily | weekly | monthly | HH:MM
  "retention": "1y",                   // overrides the environment/site default
  "exclude": ["/var/cache"]
}
```

- **Pick a kind.** `backup:vm` snapshots the whole guest. `backup:filesystem`
  captures only `backup.filesystemPaths` from inside it — narrower and faster to
  restore, but only where TAPPaaS knows the guest layout (NixOS).
- **Declare neither if you want no backup.** Hardware modules and scratch/test
  modules should not be in a backup job; that is a deliberate choice, not an
  oversight, and nothing will add them behind your back.
- **`integratesWith` instead of `dependsOn`** when your module must come up
  *before* the backup server can exist (the foundation VMs). It wires the same
  service without imposing install ordering (#501).
- **Schedules resolve Site → Environment → Module**, and are **capped at once a
  day** — a sub-daily request is rejected by name, not rounded down. Set a
  *longer* interval for a module whose state rarely changes.

See [backup](../../foundation/backup/README.md) and its
[RESTORE](../../foundation/backup/RESTORE.md) for recovery.

### Providing a service to others — `provides`

Beyond installing itself, a module can **provide** services that *other* modules depend
on: list the service names in `provides`, and implement lifecycle hooks under
`services/<service-name>/`, which TAPPaaS runs **on the provider** whenever a dependent
module is installed or updated.

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
| Foundation modules | `src/foundation/<name>/` |
| Application modules | `src/apps/<name>/` |
| Community modules | `src/<contributor>/<name>/` (in the `TAPPaaS/Community` repo) |

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
