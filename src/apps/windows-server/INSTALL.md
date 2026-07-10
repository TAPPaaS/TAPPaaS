# windows-server — Installation

Primary audience: TAPPaaS admin.

## Prerequisites

1. TAPPaaS foundation installed (`cluster`, `network`, `backup`). The `tappaas-cicd.pub`
   SSH key (deployed to the Proxmox node by the `tappaas-cicd` install) is injected into
   the VM during OOBE and is required for SSH access.
2. **Windows Server 2025 evaluation ISO** in `/var/lib/vz/template/iso/` on the Proxmox
   node — filename must match `image` in `src/foundation/templates/tappaas-winserver.json`.
3. **VirtIO drivers ISO** (`virtio-win-*.iso`) in `/var/lib/vz/template/iso/` — used to
   load the SCSI driver during Windows Setup.
4. **`local-zfs` storage on the target node.** The template VM requires `local-zfs` for its
   EFI and TPM disks. This is not configurable — Proxmox must create and write the OVMF
   VARS in a single operation, which only works reliably on `local-zfs`. See
   `src/foundation/templates/winserver/README.md` for the technical explanation.
5. **Internet access from the VM** — the baseline installer downloads VirtIO guest tools
   (from `fedorapeople.org`) if QEMU-GA is not already running, and Windows security
   updates from Windows Update (PSWindowsUpdate).

The Windows Server 2025 template (VMID 8081) is built automatically if missing —
`install-module.sh windows-server` detects a missing template and runs the full build
(~30 min) before proceeding with the clone.

> To deviate from the defaults in `./windows-server.json` (target node, storage,
> zone/VLAN, sizing, `windows.enableRDP`), copy the json to `/home/tappaas/config` and
> edit it before installing.

## Install

    install-module.sh windows-server

The install (driven by the `cluster:vm` and `templates:windows` dependencies):

1. Clones the Windows Server template into a new VM.
2. Boots the VM — OOBE configuration is injected via QEMU guest agent (tappaas account,
   SSH key, firewall rule, Administrator password); the VM reboots once to finalise.
3. Waits for SSH to become available (~3–5 min after the OOBE reboot).
4. Renames the VM hostname to match `vmname` from the JSON (requires a second reboot).
5. Extends C: to the configured `diskSize` (removes the Recovery Partition first).
6. Verifies / installs VirtIO guest tools.
7. Applies security-only Windows Updates (runs as SYSTEM via Scheduled Task, ~5–15 min).
8. Configures RDP per `windows.enableRDP`.
9. Verifies the `tappaas` account.

### Multiple instances

Use `deploy-instances.sh` to spin up several Windows Server VMs from the same base config.
It auto-assigns names (`windows-server`, `windows-server-2`, …) and finds the next free
VMIDs within the 500–599 block:

    deploy-instances.sh windows-server 3

It prints a confirmation table before installing anything; already-running instances are
never touched. For a completely custom name, copy the JSON and set `vmname` + `vmid`:

    cp config/windows-server.json config/fileserver.json
    # edit vmname → "fileserver", vmid → 501
    install-module.sh fileserver

## Post-install

None. To enable RDP later, set `windows.enableRDP: true` in the JSON and re-run
`install-module.sh windows-server`.

## Verification

    test-module.sh windows-server

| Check | Expected |
|-------|----------|
| `ssh tappaas@windows-server.srvWork.internal` | Windows command prompt, key auth, no password |
| `ssh root@<node>.mgmt.internal "qm agent <vmid> ping"` | exit 0 — QEMU guest agent alive |
| `Get-PSDrive C` via SSH | C: sized to the configured `diskSize` |
| `mstsc /v:windows-server.srvWork.internal` (if RDP enabled) | RDP login as `tappaas` |

## Troubleshooting

**Template build fails with a boot loop**
`local-zfs` is missing on the target node — the OVMF VARS disk cannot be created. Add
`local-zfs` storage and re-run the install (see Prerequisites).

**Install appears stuck during OOBE / first boot**
Take a live console screenshot from tappaas-cicd: `capture.sh <vmid> <node>`. Check the
TAPPaaS setup log written during OOBE + install:

    ssh tappaas@windows-server.srvWork.internal \
      'powershell -NoProfile -Command "Get-Content C:\tappaas-setup.log -ErrorAction SilentlyContinue"'

**VM unreachable over SSH**
Verify the guest agent responds (`qm agent <vmid> ping` from the node). SSH only becomes
available ~3–5 min after the OOBE reboot.

**Windows Update problems**
Check the update service and history via SSH (full diagnostics command cookbook in
[DESIGN.md](./DESIGN.md)):

    ssh tappaas@windows-server.srvWork.internal \
      'powershell -NoProfile -Command "Get-Service wuauserv | Format-List Name,Status,StartType"'

**Rolling back a bad update**
`update-module.sh windows-server` creates a Proxmox snapshot before starting, so the VM
can be rolled back if an update causes problems.
