# cluster:vm service

Creates and converges a module's **Proxmox QEMU guest** — the VM most TAPPaaS
modules run in. It owns the guest's identity, sizing, disks and NICs, and is the
reference implementation of the ADR-020 change model: every change class in the
taxonomy appears here, and `report-service.sh` is the one read of a guest's
actual state that drift, test and health all share.

26 fields — 5 `set` · 8 `composite` · 2 `hook` · 11 `none`.

The reference manifest: every class in the taxonomy appears here, each read off
what `update-service.sh` did before ADR-020.

## The composite: how eight fields become two strings

`bridge0`/`zone0`/`mac0`/`trunks0` are not applied one at a time — they are the
four inputs to `net0`, and `net1` is built the same way from the `…1` set. The
converge renders one `qm set -net0 …` per NIC no matter how many of the four
drifted, and the NIC's **effective class is the worst of the inputs that actually
drifted**: `trunks0` alone stays `in-place`, but `trunks0` together with `zone0`
reboots. See
[the apply modes](../../../tappaas-cicd/UPDATE-POLICY.md#composite--one-provider-string-many-declared-fields).

`bridge1` doubles as the second NIC's on/off switch — `NONE` removes `net1`
entirely, which is why it normalizes as `optional`.

<!-- BEGIN GENERATED FIELDS -- edit the manifest, not this block -->

## Fields

`cluster:vm` owns **26** declared field(s). Each table below carries the field's full definition and, where the service applies it, its ADR-020 change semantics.

### `vmname`

Name of the VM, also used as module name and OS hostname

| Attribute | Value |
|---|---|
| Type | `string` |
| Default | `<computed from module name + environment>` |
| Pattern | `^[a-zA-Z][a-zA-Z0-9-]*$` |
| Example | `nextcloud` |
| Required by | *(none)* |
| Used by | `cluster:vm`, `cluster:lxc` |
| Change class | `in-place` |
| Apply mode | `set` |
| Reported as | `name` |
| Provider flag | `--name` |

**About the field.** ADR-007 P5: vmname is COMPUTED at install time and need not be authored in the module JSON. The installer derives it from the module name and the target environment: '<module>' when the environment is the default environment, else '<module>-<environment>'. An explicit vmname in the JSON still wins (back-compat). The field is retained in the schema for legacy module configs.

**Why this change class.** Proxmox spells the guest name 'name'. Only reconciled when the guest reports one.

### `vmtag`

Proxmox tags for the VM. Comma-separated list, no spaces.

| Attribute | Value |
|---|---|
| Type | `string` |
| Default | `TAPPaaS` |
| Format | `^[a-zA-Z0-9]+(,[a-zA-Z0-9]+)*$` |
| Example | `TAPPaaS,Foundation` |
| Required by | *(none)* |
| Used by | `cluster:vm`, `cluster:lxc` |
| Change class | `in-place` |
| Apply mode | `set` |
| Normalizer | `tags` |
| Reported as | `tags` |
| Provider flag | `--tags` |

**Why this change class.** Proxmox stores tags lowercased, de-duplicated and ';'-joined; module JSON may use mixed case and commas. The 'tags' normalizer is that canonicalisation, moved from update-service.sh's normalize_tags into the one differ. The schema default 'TAPPaaS' is DESIRED state, not just a create-time seed (ADR-020 D9): an undeclared vmtag means the guest should carry exactly 'TAPPaaS', which is also what both create paths apply, so config and guest agree from install without an adoption step. qm set --tags REPLACES the list, so a tag added in the Proxmox UI is drift and the converge writes it back — intended: config is authoritative.

### `cores`

Number of CPU cores allocated to the VM

| Attribute | Value |
|---|---|
| Type | `integer` |
| Default | `2` |
| Minimum | `1` |
| Maximum | `128` |
| Example | `4` |
| Required by | *(none)* |
| Used by | `cluster:vm`, `cluster:lxc` |
| Change class | `in-place` |
| Apply mode | `set` |
| Normalizer | `integer` |
| Reported as | `cores` |
| Provider flag | `--cores` |

### `memory`

RAM allocation in megabytes

| Attribute | Value |
|---|---|
| Type | `integer` |
| Default | `4096` |
| Minimum | `512` |
| Example | `8192` |
| Required by | *(none)* |
| Used by | `cluster:vm`, `cluster:lxc` |
| Change class | `in-place` |
| Apply mode | `set` |
| Normalizer | `integer` |
| Reported as | `memory` |
| Provider flag | `--memory` |

**About the field.** Value in MB (e.g., 4096 = 4GB)

### `cputype`

CPU type emulation for the VM

| Attribute | Value |
|---|---|
| Type | `string` |
| Default | `host` |
| Example | `host` |
| Required by | *(none)* |
| Used by | `cluster:vm` |
| Change class | `in-place` |
| Apply mode | `set` |
| Reported as | `cpu` |
| Provider flag | `--cpu` |

**About the field.** Use 'host' for best performance, or a specific CPU model for migration compatibility

**Why this change class.** Proxmox spells it 'cpu'. The undeclared default resolves to 'host' — from module-fields.json, via the one resolver, NOT from a cfg() ladder in this service (#550).

### `bridge0`

Proxmox bridge for the VM's first network interface (net0)

| Attribute | Value |
|---|---|
| Type | `string` |
| Default | `lan` |
| Example | `lan` |
| Required by | *(none)* |
| Used by | `cluster:vm`, `cluster:lxc` |
| Change class | `in-place-reboot` |
| Apply mode | `composite` |
| Reported as | `net0.bridge` |
| Composite input to | `net0` |

**Why this change class.** A bridge change moves the guest to a different L2 segment, so it must re-DHCP — hence the reboot.

### `zone0`

Security zone for net0. Must exist in zones.json.

| Attribute | Value |
|---|---|
| Type | `string` |
| Default | `mgmt` |
| Format | `^[a-z][a-zA-Z0-9]*$` |
| Example | `srvHome` |
| Required by | *(none)* |
| Used by | `cluster:vm`, `cluster:lxc` |
| Change class | `in-place-reboot` |
| Apply mode | `composite` |
| Normalizer | `vlan` |
| Reported as | `net0.tag` |
| Composite input to | `net0` |

**About the field.** Zone determines VLAN tag. 'mgmt' is untagged traffic. camelCase only — no underscores or hyphens (#278). ADR-007 P5: when zone0 is unset it DEFAULTS to the target environment's network.zone (read from config/environments/<env>.json); pre-cutover (no site.json/environments) it falls back to resolve_default_zone()'s behaviour. An explicit zone0 in the module JSON always wins.

**Why this change class.** The zone resolves to net0's VLAN tag; a new tag is a new subnet, so the guest must renew DHCP and re-register DNS.

### `mac0`

MAC address for the net0 network port

| Attribute | Value |
|---|---|
| Type | `string` |
| Default | `<randomly generated>` |
| Format | `^([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}$` |
| Example | `BC:24:11:00:01:10` |
| Required by | *(none)* |
| Used by | `cluster:vm`, `cluster:lxc` |
| Change class | `in-place-reboot` |
| Apply mode | `composite` |
| Reported as | `net0.mac` |
| Composite input to | `net0` |

**Why this change class.** A new MAC is a NEW IDENTITY on the wire: the guest takes a fresh DHCP lease, very likely a different address, and its DNS record must follow — exactly the reboot → wait-for-lease → re-register chain net0 already declares. Classed in-place until ADR-020 P6, inherited from a comment that grouped 'trunk- or MAC-only' changes as live; the two are not alike, because trunks is a BRIDGE-side allow-list the guest never sees while the MAC is the guest's own NIC. #194 already established that a netN property needing device re-creation (queues) is a disruptive hot-replug, and the MAC takes the same path. When the module pins no mac0 the field has no desired value at all and the LIVE MAC is carried across, which is why the manager assembles the finished netopts — so this only bites a module that deliberately re-MACs a guest.

### `trunks0`

Semicolon-separated list of additional zone names to trunk on net0. Zone names are resolved to VLAN tags. Used when a VM needs to see traffic from multiple VLANs on a single NIC (e.g., the firewall).

| Attribute | Value |
|---|---|
| Type | `string` |
| Default | `NONE` |
| Format | `^([a-z][a-zA-Z0-9]*(;[a-z][a-zA-Z0-9]*)*|ALL|\*|NONE)$` |
| Example | `srv;iot;dmz` |
| Required by | *(none)* |
| Used by | `cluster:vm`, `cluster:lxc` |
| Change class | `in-place` |
| Apply mode | `composite` |
| Normalizer | `trunks` |
| Reported as | `net0.trunks` |
| Composite input to | `net0` |

**About the field.** Zone names must exist in zones.json, camelCase only [a-zA-Z0-9]. Semicolon-delimited, no spaces. Sentinels: ALL/* expand to every Active zone; NONE = empty.

**Why this change class.** A trunk-only change applies live on the bridge — no reboot.

### `bridge1`

Proxmox bridge for the VM's second network interface (net1). The sentinel 'NONE' — which is also what an absent bridge1 resolves to — means the VM has only one NIC.

| Attribute | Value |
|---|---|
| Type | `string` |
| Default | `NONE` |
| Example | `lan` |
| Required by | *(none)* |
| Used by | `cluster:vm` |
| Change class | `in-place-reboot` |
| Apply mode | `composite` |
| Normalizer | `optional` |
| Reported as | `net1.bridge` |
| Composite input to | `net1` |

**About the field.** cluster:vm only — a container has ONE NIC in TAPPaaS: neither Create-TAPPaaS-LXC.sh nor cluster:lxc's install/update service mentions net1, so the cluster:lxc claim these fields used to carry (bridge1/mac1/zone1/trunks1) was ownership that did not exist, removed in ADR-020 P5. Only used if a second network interface is needed. The default was 'lan' until ADR-020 P1, which contradicted both acting paths — Create-TAPPaaS-VM.sh and cluster:vm/update-service.sh have always read it as 'NONE' — and made the drift report claim a desired second NIC that nothing would ever create. Declaring a bridge1 on a VM that has none ADDS the NIC; removing it (back to the 'NONE' default) DELETES the live net1, which reboots the guest.

**Why this change class.** Also the ADD/REMOVE switch for the second NIC. Its module-fields.json default is the sentinel 'NONE', so an undeclared bridge1 resolves to 'no second NIC' — the same reading Create-TAPPaaS-VM.sh and update-service.sh have always had. 'NONE' with a live net1 means the NIC is removed, which likewise reboots.

### `zone1`

Security zone for net1. Must exist in zones.json.

| Attribute | Value |
|---|---|
| Type | `string` |
| Default | `mgmt` |
| Format | `^[a-z][a-zA-Z0-9]*$` |
| Required by | *(none)* |
| Used by | `cluster:vm` |
| Change class | `in-place-reboot` |
| Apply mode | `composite` |
| Normalizer | `vlan` |
| Reported as | `net1.tag` |
| Composite input to | `net1` |

**About the field.** Only used if bridge1 is defined. Hyphens are NOT allowed — use underscores (#237).

### `mac1`

MAC address for the net1 network port

| Attribute | Value |
|---|---|
| Type | `string` |
| Default | `<randomly generated>` |
| Format | `^([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}$` |
| Required by | *(none)* |
| Used by | `cluster:vm` |
| Change class | `in-place-reboot` |
| Apply mode | `composite` |
| Reported as | `net1.mac` |
| Composite input to | `net1` |

**Why this change class.** As mac0: a new MAC means a new lease and a new DNS record, so it earns net1's reboot chain. Unpinned, the live MAC is preserved and nothing drifts.

### `trunks1`

Semicolon-separated list of additional zone names to trunk on net1. Same format as trunks0.

| Attribute | Value |
|---|---|
| Type | `string` |
| Default | `NONE` |
| Format | `^([a-z][a-zA-Z0-9]*(;[a-z][a-zA-Z0-9]*)*|ALL|\*|NONE)$` |
| Example | `srv;iot;dmz` |
| Required by | *(none)* |
| Used by | `cluster:vm` |
| Change class | `in-place` |
| Apply mode | `composite` |
| Normalizer | `trunks` |
| Reported as | `net1.trunks` |
| Composite input to | `net1` |

**About the field.** Only used if bridge1 is defined. Zone names must exist in zones.json, camelCase only [a-zA-Z0-9].

### `diskSize`

Disk size with unit suffix

| Attribute | Value |
|---|---|
| Type | `string` |
| Default | `8G` |
| Pattern | `^[0-9]+[GMK]$` |
| Example | `32G` |
| Required by | *(none)* |
| Used by | `cluster:vm`, `cluster:lxc` |
| Change class | `grow-only` |
| Apply mode | `hook` |
| Normalizer | `size` |
| Reported as | `diskSize` |
| Hook | `update-disk.sh` |

**About the field.** G=gigabytes, M=megabytes, K=kilobytes

**Why this change class.** A grow goes through resize-disk.sh. The direction is only knowable against the live size, so a SHRINK is refused at apply time (hook exit 20), not by the static pre-gate. The schema default 8G is DESIRED state (ADR-020 D9): it is also what both create paths build with, so an undeclared guest is in sync from install. When the guest is later grown outside the config path — check-disk-threshold.sh, resize-disk.sh by hand, qm resize — config falls BEHIND actual, which reads as a shrink and would be refused on every converge forever. That case is now ADOPTED instead: the converge writes the observed size into config, touching nothing on the cluster. Excluding undeclared modules from the comparison, as v0.5 did, never helped here: a DECLARED module — which is all of them — got the permanent refusal anyway.

### `node`

Name of the Proxmox/TAPPaaS node where the module should be installed. If null, defaults to the first node in configuration.json.

| Attribute | Value |
|---|---|
| Type | `string` |
| Default | *(none)* |
| Example | `tappaas1` |
| Required by | *(none)* |
| Used by | `cluster:vm`, `cluster:lxc` |
| Change class | `migrate` |
| Apply mode | `hook` |
| Reported as | `node` |
| Hook | `update-node.sh` |
| Side effects | `ha-repoint` |

**Why this change class.** The ADR-019 bridge. The hook routes HA-vs-non-HA internally: a module that dependsOn cluster:ha has its node drift handled by the HA rule (re-point), a plain module by qm migrate. Live-OK decides whether the migrate needs downtime, so this refuses (exit 10) rather than migrating offline without --force. module-fields.json gives node NO default, so a module that declares none has no desired placement and is left where it runs. update-service.sh instead defaulted it to the FIRST site node, which would silently migrate an undeclared guest back to node 0 after any failover or manual move — a latent hazard that only stayed invisible because the estate's undeclared guests happen to sit on node 0. Expressing no placement is not the same as asking for node 0.

### `storage`

Name of the storage pool for the module

| Attribute | Value |
|---|---|
| Type | `string` |
| Default | `tanka1` |
| Example | `tanka1` |
| Required by | *(none)* |
| Used by | `cluster:vm`, `cluster:lxc` |
| Change class | `manual` |
| Apply mode | `none` |
| Reported as | `storage` |

**About the field.** Storage pool must exist on the target node

**Why this change class.** A storage change means moving the disk, and update-service.sh has always WARNED rather than acting, because an implicit qm move-disk is a long, IO-heavy operation an operator must schedule. Not pre-gated: writing the intended storage into config and reporting the gap is useful, so only the apply refuses. The schema default 'tanka1' is DESIRED state (ADR-020 D9) — it is what both create paths build on, so an undeclared guest is in sync from install. Nothing in TAPPaaS ever moves a disk, so this can only diverge when an operator runs qm move-disk by hand, and reporting exactly that is what the manual class is for; Excluding undeclared modules from the comparison suppressed exactly that report, which is the opposite of what manual means.

### `bios`

BIOS type for VM creation

| Attribute | Value |
|---|---|
| Type | `string` |
| Default | `ovmf` |
| Allowed values | `ovmf` — UEFI firmware (recommended for modern OSes)<br>`seabios` — Legacy BIOS (for older OSes or special cases) |
| Required by | *(none)* |
| Used by | `cluster:vm` |
| Change class | `recreate` |
| Apply mode | `none` |
| Reported as | `bios` |

**Why this change class.** Firmware is chosen when the guest is created; changing it on a live VM is refused (main's update-service made it the script's only FATAL). Pre-gated, so config is never left claiming a firmware the guest does not have. Proxmox OMITS the bios: line for seabios, so an absent value decodes to seabios rather than unknown. The schema default 'ovmf' is DESIRED state (ADR-020 D9) and is what Create-TAPPaaS-VM.sh builds with, so a guest TAPPaaS created always matches it. The residual risk is a guest built ELSEWHERE and adopted while declaring nothing — on seabios it would report recreate drift that fails the converge and can never be resolved in place. install-service.sh therefore records the observed firmware into config at install, which closes that case at the only moment it can be closed.

### `ostype`

Proxmox guest OS profile. Controls QEMU clock, ACPI, and balloon-driver behaviour — it does NOT install the OS. The letter in 'l26' is a lowercase L (Linux), not the digit 1.

| Attribute | Value |
|---|---|
| Type | `string` |
| Default | `l26` |
| Allowed values | `l26` — Linux kernel 2.6 and later — NixOS, Debian, Ubuntu, and any modern Linux distro. Enables KVM paravirtual clock<br>`l24` — Linux kernel 2.4 — legacy, rarely needed.<br>`win11` — Windows 11 / Windows Server 2022 / Windows Server 2025. Enables Windows-specific ACPI, local-time hardware clo<br>`win10` — Windows 10 / Windows Server 2016 / Windows Server 2019. Same Windows treatment as win11 but with an earlier AC<br>`win8` — Windows 8.x / Windows Server 2012 / Server 2012 R2.<br>`win7` — Windows 7 / Windows Server 2008 R2.<br>`win2k25` — Explicit alias for Windows Server 2025. Equivalent to win11 in Proxmox — win11 is preferred.<br>`win2k22` — Explicit alias for Windows Server 2022. Equivalent to win11 in Proxmox — win11 is preferred.<br>`win2k19` — Explicit alias for Windows Server 2019. Equivalent to win10 in Proxmox — win10 is preferred.<br>`other` — Generic / unknown OS — minimal hypervisor optimisation.<br>`solaris` — Solaris / OpenSolaris / OpenIndiana. |
| Required by | *(none)* |
| Used by | `cluster:vm` |
| Change class | `recreate` |
| Apply mode | `none` |
| Reported as | `ostype` |

**About the field.** Pick the value that matches your guest OS. Wrong ostype causes clock drift or incorrect power-management behaviour but does not prevent the VM from booting.

**Why this change class.** A creation-time hint that selects emulated hardware defaults; never reconciled on a live guest.

### `autoInstall`

Whether this template can be built fully automatically without operator input. Used by cluster:vm/install-service.sh when a required template is missing — if true, the template is auto-built before the clone proceeds; if false, the operator must build it manually first.

| Attribute | Value |
|---|---|
| Type | `boolean` |
| Default | `false` |
| Allowed values | `true` — Fully unattended build — no console interaction required (e.g. tappaas-winserver with autounattend.xml)<br>`false` — Requires manual installation — operator must run install-module.sh and complete the setup (e.g. tappaas-nixos  |
| Required by | *(none)* |
| Used by | `cluster:vm` |
| Change class | `recreate` |
| Apply mode | `none` |
| Normalizer | `boolean` |

**Why this change class.** Drives the unattended install at creation. Meaningless afterwards.

### `sshAccess`

Whether TAPPaaS can manage this guest over SSH. Set false for sealed appliance images that expose no login shell (e.g. Home Assistant OS). When false, cluster:vm test-service skips its SSH-based health checks (connectivity, disk, memory) and relies on the module's own test.sh for app-level health — so a working appliance is not falsely reported as failing (which would otherwise abort updates).

| Attribute | Value |
|---|---|
| Type | `string` |
| Default | `true` |
| Allowed values | `true` — TAPPaaS manages the guest over SSH (NixOS VMs, OPNsense as root)<br>`false` — Unmanaged appliance — no SSH; skip SSH-based cluster:vm tests |
| Required by | *(none)* |
| Used by | `cluster:vm` |
| Change class | `recreate` |
| Apply mode | `none` |
| Normalizer | `boolean` |

**Why this change class.** Seeds the cloud-init SSH configuration at creation.

### `vmid`

Unique VM ID across all TAPPaaS nodes

| Attribute | Value |
|---|---|
| Type | `integer` |
| Minimum | `100` |
| Maximum | `999999` |
| Example | `200` |
| Required by | `cluster:vm`, `cluster:lxc` |
| Used by | `cluster:vm`, `cluster:lxc` |
| Change class | `immutable` |
| Apply mode | `none` |
| Reported as | `vmid` |

**Why this change class.** The guest's identity. Changing it IS a different guest — delete + reinstall.

### `os`

Operating system family of the VM. Drives OS-specific cloud-init bootstrapping (e.g. attaching the Debian vendor-data snippet that pre-installs qemu-guest-agent).

| Attribute | Value |
|---|---|
| Type | `string` |
| Default | <auto-detected from image filename: debian-*, ubuntu-*, *nixos* -> matching value; else unknown> |
| Allowed values | `debian` — Debian-family cloud image (apt). Receives the tappaas-debian vendor-data snippet.<br>`ubuntu` — Ubuntu-family cloud image (apt). Receives the tappaas-debian vendor-data snippet.<br>`nixos` — NixOS template VM. No vendor-data snippet.<br>`windows` — Windows Server clone VM. Create-TAPPaaS-VM.sh builds and attaches a per-VM OOBE answer ISO. No cloud-init.<br>`unknown` — OS family is unknown. No vendor-data snippet. |
| Example | `debian` |
| Required by | *(none)* |
| Used by | `cluster:vm` |
| Change class | `immutable` |
| Apply mode | `none` |
| Reported as | `os` |

**About the field.** Optional. If omitted, Create-TAPPaaS-VM.sh falls back to sniffing the 'image' filename. Set explicitly to override the sniff.

**Why this change class.** Auto-detected from the image at install and never changed in place. Reported from the QEMU guest agent (get-osinfo), whose distro id the reporter maps into this schema's vocabulary — Windows spells itself 'mswindows'. The agent only answers for a RUNNING guest with the agent installed; otherwise the reporter omits the key and the field records as not-reported rather than drifting against an empty actual.

### `imageType`

How the guest's image/rootfs is sourced. Applies to both VMs (cluster:vm) and containers (cluster:lxc); whether the guest is a VM or an LXC is determined by dependsOn (cluster:vm vs cluster:lxc), not by this field.

| Attribute | Value |
|---|---|
| Type | `string` |
| Default | `clone` |
| Allowed values | `{"clone": {"description": "cluster:vm \u2014 VM cloned from an existing Proxmox VM template. cluster:lxc \u2014 container created (pct create) from a CT template in local:vztmpl, downloaded via pveam if absent.", "image_field": "cluster:vm: VMID of the template to clone. cluster:lxc: CT template filename (e.g. debian-12-standard_12.12-1_amd64.tar.zst)"}, "iso": {"description": "VM is created with a CD-ROM drive attached to the ISO. ISO is downloaded and placed in local:iso. (VM only.)", "image_field": "Name of the ISO file", "requires": "imageLocation"}, "img": {"description": "VM disk imports the image (downloaded and unzipped if compressed). Image is discarded after import. (VM only.)", "image_field": "Name of the image file", "requires": "imageLocation"}, "apt": {"description": "Package is a simple apt package to be installed", "image_field": "Name of the apt package(s) to install"}}` |
| Required by | `cluster:vm`, `cluster:lxc` |
| Used by | `cluster:vm`, `cluster:lxc` |
| Change class | `immutable` |
| Apply mode | `none` |

**Why this change class.** clone vs. download decides how the guest was built; it cannot be re-decided in place.

### `image`

Image identifier. Interpretation depends on imageType.

| Attribute | Value |
|---|---|
| Type | `string` |
| Required by | `cluster:vm`, `cluster:lxc` |
| Used by | `cluster:vm`, `cluster:lxc` |
| Change class | `immutable` |
| Apply mode | `none` |

### `imageLocation`

URL or local path where the image file is located. For images already on the Proxmox node use the local directory path (e.g. '/var/lib/vz/template/iso/'). For remote images use an https:// URL.

| Attribute | Value |
|---|---|
| Type | `string` |
| Format | `^(https?://.+|/.+)$` |
| Example | `https://releases.ubuntu.com/24.04/` |
| Required by | *(none)* |
| Used by | `cluster:vm` |
| Change class | `immutable` |
| Apply mode | `none` |

**About the field.** For apt, if present, names an additional package repository to add

### `cloudInit`

Whether the VM supports cloud-init for initial configuration

| Attribute | Value |
|---|---|
| Type | `string` |
| Default | `true` |
| Allowed values | `true` — VM supports cloud-init (SSH keys, hostname, etc.)<br>`false` — VM does not use cloud-init |
| Required by | *(none)* |
| Used by | `cluster:vm` |
| Change class | `immutable` |
| Apply mode | `none` |
| Normalizer | `boolean` |
| Reported as | `cloudInit` |

**Why this change class.** How the guest was provisioned; not re-decidable in place. Observed as the presence of the '<storage>:vm-<vmid>-cloudinit' drive, which is always readable from qm config, so this is reported for every guest — 'false' means the guest genuinely has no cloud-init drive.

## Composites

### `net0`

Built from `bridge0`, `zone0`, `mac0`, `trunks0`.

| Attribute | Value |
|---|---|
| Change class | `in-place-reboot` |
| Apply mode | `hook` |
| Reported as | `net0` |
| Hook | `update-net.sh` |
| Side effects | `reboot`, `wait-ip`, `dns` |

**Why this change class.** The primary NIC: one qm value 'virtio=<mac>,bridge=<b>,tag=<vlan>[,trunks=…][,queues=…]' assembled from four declared fields. The MANAGER builds the finished string because it must preserve two LIVE values the config never carries — the MAC when the module pins none, and queues, which must never change on a running NIC (#194). in-place-reboot is the CEILING: the runner escalates only when bridge0 or zone0 actually drifted; a MAC- or trunk-only change stays in-place, exactly as today.

### `net1`

Built from `bridge1`, `zone1`, `mac1`, `trunks1`.

| Attribute | Value |
|---|---|
| Change class | `in-place-reboot` |
| Apply mode | `hook` |
| Reported as | `net1` |
| Hook | `update-net.sh` |
| Side effects | `reboot`, `wait-ip`, `dns` |

**Why this change class.** The optional second NIC. Adding it, or changing its bridge/tag, reboots; a trunk- or MAC-only change applies live. Removing it (bridge1 gone from config while the guest still has net1) is a `qm set --delete net1` and also reboots.

<!-- END GENERATED FIELDS -->
