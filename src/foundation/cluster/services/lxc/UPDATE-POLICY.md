# Update policy — `cluster:lxc`

**Manifest:** [`fields.json`](fields.json) · **Vocabulary:**
[the seven change classes and five apply modes](../../../tappaas-cicd/UPDATE-POLICY.md#1-the-seven-change-classes)
· **Index:** [all services](../../../tappaas-cicd/UPDATE-POLICY.md#4-the-per-service-manifests)

15 fields — 5 `set` · 4 `composite` · 6 `none`.

A container is not a VM with different words: one NIC, no firmware, and nothing
it is safe to relocate or resize under a bind-mount. Compare
[`cluster:vm`](../vm/UPDATE-POLICY.md) — the differences below are deliberate.

| Field | Class | Apply | Normalize | Why this class |
|---|---|---|---|---|
| `vmname` | in-place | set | — | Proxmox calls it `hostname`; also the DNS name. |
| `vmtag` | in-place | set | tags | As cluster:vm: the schema default `TAPPaaS` is desired state and is what `Create-TAPPaaS-LXC.sh` applies, so an undeclared container is already in sync. |
| `cores` | in-place | set | integer | A cgroup limit; no restart. |
| `memory` | in-place | set | integer | A cgroup limit. |
| `swap` | in-place | set | integer | Container-only. Read for years, declared in ADR-020 P5. |
| `bridge0` | in-place-reboot | composite | — | Restarts the container to re-DHCP. |
| `zone0` | in-place-reboot | composite | vlan | New subnet; DNS re-registers. |
| `mac0` | in-place-reboot | composite | — | Spelled `hwaddr=`. Same reasoning as cluster:vm; under masqdns the container's name follows its lease. |
| `trunks0` | in-place | composite | trunks | Live on the bridge. |
| `node` | manual | none | — | **Not** cluster:vm's `migrate`: a GPU passthrough or bind-mount makes live migration unsafe, and those are the workloads TAPPaaS puts in containers. |
| `diskSize` | manual | none | — | Not grown by this service. main's header promised a warn its code never implemented, so the size was invisible; `manual` restores the report. The schema default 8G is what the creator builds with, so an undeclared container is in sync from install, and nothing grows a rootfs behind config's back — a divergence means someone ran `pct resize` by hand. *See [recommendation 3](../../../tappaas-cicd/UPDATE-POLICY.md#3-reconsider-clusterlxc-disksize-as-grow-only).* |
| `storage` | manual | none | — | For a bind-mounted CT this is not a move at all. As cluster:vm, the schema default `tanka1` is what the creator builds on, so an undeclared container is in sync from install. |
| `vmid` | immutable | none | — | Container identity. |
| `image` | immutable | none | — | The template it came from. |
| `imageType` | immutable | none | — | Not re-decidable in place. |

## Where it diverges from `cluster:vm`

| | `cluster:vm` | `cluster:lxc` |
|---|---|---|
| `node` | `migrate` — the hook moves the guest | `manual` — refused; passthrough and bind-mounts make it unsafe |
| `diskSize` | `grow-only` — grown by `resize-disk.sh` | `manual` — no grow path implemented |
| second NIC | `bridge1`/`zone1`/`mac1`/`trunks1` | none — one NIC only |
| firmware | `bios` is `recreate` | not a container concept |
| `swap` | not a VM concept | `in-place` |
