# templates

Primary audience: TAPPaaS admin.

The TAPPaaS VM base images — prebuilt, preconfigured templates (NixOS today, Windows
Server as an add-on) that every other TAPPaaS VM is cloned from, plus the per-OS service
hooks that keep consumer VMs configured.

## What you get

| Capability | Access from | How |
|------------|-------------|-----|
| NixOS VM template (`tappaas-nixos`, VMID 8080) | consumer modules | `dependsOn: ["templates:nixos"]`; module json `imageType: "clone"`, `image: "8080"` |
| Windows Server 2025 template (`tappaas-winserver`, VMID 8081) | consumer modules | `dependsOn: ["templates:windows"]` — see [winserver/README.md](winserver/README.md) |
| NixOS config apply on consumer VMs | module lifecycle | `services/nixos/*.sh` hooks (nixos-rebuild on the consumer VM) |
| Debian/Ubuntu config apply on consumer VMs | module lifecycle | `services/debian/*.sh` hooks |
| Windows baseline (OOBE, disk, updates, RDP, SSH) | module lifecycle | `services/windows/*.sh` hooks — see [services/windows/README.md](services/windows/README.md) |
| Version-gated template refresh | TAPPaaS admin | `update-module.sh templates` (only downloads when the pinned version changes) |

## What is not included

- Guest provisioning itself — VMs are created by the `cluster:vm` service
  (`Create-TAPPaaS-VM.sh`); this module supplies the images it clones and the OS hooks.
- Application configuration — each consumer module's own `.nix`/scripts.
- The Windows Server and VirtIO ISOs — you download those yourself
  (see [winserver/README.md](winserver/README.md)).
- Updates of already-cloned VMs — clones are full and independent; they update via their
  own `nixos-rebuild` (driven by the service hooks), not by template refreshes.

## Requirements

- The `cluster` module installed (the template is a Proxmox VM on `tanka1`).
- Internet access on the node to fetch the prebuilt image (~700 MB) from the GitHub
  Release pinned in `tappaas-nixos.json`.
- Windows template only: the evaluation and VirtIO ISOs staged under
  `/var/lib/vz/template/iso/` on the target node.

## Dependencies

| Depends on | Purpose |
|------------|---------|
| `cluster:vm` | Creates the template VMs (8080/8081) on the cluster |

(`templates.json` itself declares no `dependsOn`; the per-template build configs
`tappaas-nixos.json` / `tappaas-winserver.json` depend on `cluster:vm`.)

For installation steps see [INSTALL.md](./INSTALL.md).

Design and implementation detail: [DESIGN.md](./DESIGN.md). Test coverage:
[TEST.md](./TEST.md).
