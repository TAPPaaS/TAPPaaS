# cluster:lxc service

Creates and converges a module's **Proxmox LXC container**. A container is not
a VM with different words: one NIC, no firmware, and — because TAPPaaS puts GPU
passthrough and bind-mount workloads here — nothing it is safe to relocate or
resize underneath. Those differences are visible in the field table below.

15 fields — 5 `set` · 4 `composite` · 6 `none`.

A container is not a VM with different words: one NIC, no firmware, and nothing
it is safe to relocate or resize under a bind-mount. Compare
[`cluster:vm`](../vm/README.md) — the differences below are deliberate.

## Where it diverges from `cluster:vm`

| | `cluster:vm` | `cluster:lxc` |

<!-- BEGIN GENERATED FIELDS -- edit the manifest, not this block -->

## Fields

`cluster:lxc` owns **15** declared field(s). Each table below carries the field's full definition and, where the service applies it, its ADR-020 change semantics.

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
| Reported as | `hostname` |
| Provider flag | `--hostname` |

**About the field.** ADR-007 P5: vmname is COMPUTED at install time and need not be authored in the module JSON. The installer derives it from the module name and the target environment: '<module>' when the environment is the default environment, else '<module>-<environment>'. An explicit vmname in the JSON still wins (back-compat). The field is retained in the schema for legacy module configs.

**Why this change class.** Proxmox calls a container's name 'hostname'. It is also the DNS name the guest registers as.

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

**Why this change class.** Same canonicalisation and same rule as cluster:vm: the schema default 'TAPPaaS' is desired state, and it is what Create-TAPPaaS-LXC.sh applies when the module declares nothing, so an undeclared container is already in sync.

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

**Why this change class.** Applied live — a container's cgroup limit changes without a restart.

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

**Why this change class.** Also live, for the same reason.

### `swap`

Swap in MB for an LXC container. A container has no BIOS and no virtual disk controller, so its memory pressure is handled differently from a VM's — 0 means the container may not swap at all, which is the TAPPaaS default.

| Attribute | Value |
|---|---|
| Type | `integer` |
| Default | `0` |
| Minimum | `0` |
| Example | `512` |
| Required by | *(none)* |
| Used by | `cluster:lxc` |
| Change class | `in-place` |
| Apply mode | `set` |
| Normalizer | `integer` |
| Reported as | `swap` |
| Provider flag | `--swap` |

**About the field.** cluster:lxc's update-service.sh has always read this from config with a default of 0; it was simply never declared here, so no path could report or classify it. Declared in ADR-020 P5.

**Why this change class.** Container-only: a VM's swap is inside its guest, a container's is a host-side cgroup limit. Live, like cores and memory. TAPPaaS defaults it to 0 — a container that needs swap says so.

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

**Why this change class.** A bridge change moves the container to a different L2 segment, so it must re-DHCP — hence the restart.

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

**Why this change class.** The zone resolves to net0's VLAN tag; a new tag is a new subnet, so the container restarts and re-registers DNS.

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

**Why this change class.** Spelled `hwaddr=` on a container, and the same reasoning as cluster:vm's mac0: a new MAC is a new lease, and under masqdns the container's name follows that lease — so the restart and the stale-pin cleanup both matter. Preserved from the live NIC unless the module pins one, which is why both reporters emit the MAC under one key.

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

**Why this change class.** A trunk-only change applies live on the bridge — no restart.

### `node`

Name of the Proxmox/TAPPaaS node where the module should be installed. If null, defaults to the first node in configuration.json.

| Attribute | Value |
|---|---|
| Type | `string` |
| Default | *(none)* |
| Example | `tappaas1` |
| Required by | *(none)* |
| Used by | `cluster:vm`, `cluster:lxc` |
| Change class | `manual` |
| Apply mode | `none` |
| Reported as | `node` |

**Why this change class.** NOT cluster:vm's `migrate`. Live-migrating a container is unsafe when it has a GPU passed through or bind-mounts from the host — which is why TAPPaaS runs containers for exactly those workloads. The service reports the drift and leaves the move to an operator who can stop it, move it and start it deliberately.

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
| Change class | `manual` |
| Apply mode | `none` |
| Reported as | `diskSize` |

**About the field.** G=gigabytes, M=megabytes, K=kilobytes

**Why this change class.** Not grown by this service. main's update-service.sh header promised a warn for 'rootfs size' that the code never implemented — it read only vmname/node/zone0/bridge0/trunks0/cores/memory/swap — so the rootfs size was invisible rather than reported. Classed manual, which restores the report. The schema default 8G is DESIRED state (ADR-020 D9): it is what Create-TAPPaaS-LXC.sh builds with, so an undeclared container is in sync from install. Unlike cluster:vm diskSize there is no path that grows it behind config's back — check-disk-threshold.sh calls resize-disk.sh, which is qm-only — so a divergence means an operator ran pct resize by hand, which is exactly what manual exists to surface. Reclassifying to grow-only so pct resize could grow it live is a capability change (recommendation 3), deliberately not bundled here.

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

**Why this change class.** As cluster:vm, and for a bind-mounted container this is not a move at all. The schema default 'tanka1' is what Create-TAPPaaS-LXC.sh builds on, so an undeclared container is in sync from install and the manual-class report is restored rather than suppressed (ADR-020 D9).

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

**Why this change class.** The container's identity. A different vmid IS a different container.

### `image`

Image identifier. Interpretation depends on imageType.

| Attribute | Value |
|---|---|
| Type | `string` |
| Required by | `cluster:vm`, `cluster:lxc` |
| Used by | `cluster:vm`, `cluster:lxc` |
| Change class | `immutable` |
| Apply mode | `none` |

**Why this change class.** The template the container was created from.

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

**Why this change class.** How it was built; not re-decidable in place.

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

**Why this change class.** The container's only NIC — TAPPaaS gives a CT one interface, which is why bridge1/mac1/zone1/trunks1 are cluster:vm-only. Proxmox spells it 'name=eth0,bridge=…,hwaddr=…,ip=dhcp[,tag=…]'. in-place-reboot is the CEILING: a MAC- or trunk-only change stays in-place, and only a bridge/zone change restarts the container.

<!-- END GENERATED FIELDS -->
