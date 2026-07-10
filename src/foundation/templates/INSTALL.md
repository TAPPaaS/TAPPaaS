# templates — Installation

Primary audience: TAPPaaS admin.

The NixOS template is **not** installed with `install-module.sh` — it is imported
automatically during the foundation bootstrap. Only the optional Windows Server template
is installed by hand.

## Prerequisites

1. The `cluster` module is up (nodes, `tanka1` storage, internet on the node).
2. Windows template only: the Windows Server 2025 Evaluation ISO (exact filename from
   `tappaas-winserver.json` → `image`) and a `virtio-win-*.iso` staged in
   `/var/lib/vz/template/iso/` on `tappaas1` — see
   [winserver/README.md](winserver/README.md).

> To deviate from the defaults in `./tappaas-nixos.json` / `./tappaas-winserver.json`
> (target storage, sizing, pinned image version), copy the json to
> `/home/tappaas/config` and edit it before installing/updating.

## Install

**NixOS template (VMID 8080)** — imported by the first-node bootstrap, step [5/5]
(`install-platform.sh`, Phase A): it downloads the prebuilt qcow2 image from the GitHub
Release pinned in `tappaas-nixos.json` and finalises it into a Proxmox template — no
manual NixOS install. Nothing to run by hand on a normal install.

Kept current from the mothership (version-gated — a no-op unless the pinned version in
`tappaas-nixos.json` changed):

    update-module.sh templates

**Windows Server 2025 template (VMID 8081, optional)** — from the mothership:

    cd ~/TAPPaaS/src/foundation/templates && install-module.sh tappaas-winserver

Takes about 30 minutes, fully unattended (installs, syspreps, becomes a template). It is
also built automatically the first time a Windows-dependent module is installed.

## Post-install

None.

## Verification

    test-module.sh templates                      # fast: config + script sanity
    TAPPAAS_TEST_DEEP=1 test-module.sh templates  # + template VMs present on the cluster

| Check | Expected |
|-------|----------|
| Fast run | All template jsons valid; all `services/*/*.sh` parse |
| Deep run | Template VM 8080 (and 8081 if built) present on the primary node |
| `qm config 8080` on the node | `template: 1` |
| `cat /root/tappaas/nixos-template.version` on the node | Matches `nixos-template-v<version>` from `tappaas-nixos.json` |

Note: `services/nixos/test-service.sh` (the consumer-VM baseline test) is still a stub
with no assertions — see [TEST.md](./TEST.md).

## Troubleshooting

**Template update dies with "Release asset not reachable"**
The update pre-flights the release URL *before* destroying the existing template, so a
bad/missing release leaves the current template untouched. Check
`imageLocation`/`version` in `tappaas-nixos.json` and connectivity, then re-run.

**A VM cloned last week doesn't have the new template's changes**
Expected: template refreshes affect only **new** clones. Existing VMs are independent
full clones and pick up OS changes via their own `nixos-rebuild`
(`update-module.sh <module>`).

**Windows template build fails early**
Almost always the ISOs: wrong filename vs `tappaas-winserver.json` `image`, or missing
`virtio-win-*.iso`. See [winserver/README.md](winserver/README.md) for the full
runbook.
