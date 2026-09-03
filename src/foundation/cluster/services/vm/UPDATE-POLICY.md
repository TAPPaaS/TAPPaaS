# Update policy — `cluster:vm`

**Manifest:** [`fields.json`](fields.json) · **Vocabulary:**
[the seven change classes and five apply modes](../../../tappaas-cicd/UPDATE-POLICY.md#1-the-seven-change-classes)
· **Index:** [all services](../../../tappaas-cicd/UPDATE-POLICY.md#4-the-per-service-manifests)

26 fields — 5 `set` · 8 `composite` · 2 `hook` · 11 `none`.

The reference manifest: every class in the taxonomy appears here, each read off
what `update-service.sh` did before ADR-020.

| Field | Class | Apply | Normalize | Why this class |
|---|---|---|---|---|
| `vmname` | in-place | set | — | A live `qm set --name`. |
| `vmtag` | in-place | set | tags | The schema default `TAPPaaS` is desired state, and it is what both create paths apply — so an undeclared guest is in sync from install. `qm set --tags` replaces the list, so a tag added in the Proxmox UI is drift the converge writes back. |
| `cores` | in-place | set | integer | Hot-pluggable. |
| `memory` | in-place | set | integer | Hot-pluggable. |
| `cputype` | in-place | set | — | Proxmox spells it `cpu`. The #550 field. |
| `bridge0` | in-place-reboot | composite | — | A new L2 segment; the guest must re-DHCP. |
| `zone0` | in-place-reboot | composite | vlan | New tag, new subnet. |
| `mac0` | in-place-reboot | composite | — | A new MAC is a new identity: new lease, likely new IP, DNS must follow. Unpinned, the live MAC is carried across and nothing drifts. |
| `trunks0` | in-place | composite | trunks | A trunk-only change needs no reboot. |
| `bridge1` | in-place-reboot | composite | optional | Also the add/remove switch for the second NIC. |
| `zone1` | in-place-reboot | composite | vlan | As `zone0`. |
| `mac1` | in-place-reboot | composite | — | As `mac0`. |
| `trunks1` | in-place | composite | trunks | As `trunks0`. |
| `diskSize` | grow-only | hook | size | Grows via `resize-disk.sh`; a shrink is refused at apply time. The schema default 8G is what both create paths build with, so an undeclared guest is in sync from install. If the guest is grown outside the config path, config falls behind and the converge **adopts** the observed size rather than refusing a shrink forever. |
| `node` | migrate | hook | — | The ADR-019 bridge; routes HA vs non-HA internally. See [what happens today](../../../tappaas-cicd/UPDATE-POLICY.md#7-node-and-hanode--what-happens-today-adr-019s-starting-point). |
| `storage` | manual | none | — | An implicit `move-disk` is long and IO-heavy — an operator schedules it. The schema default `tanka1` is what both create paths build on, so an undeclared guest is in sync from install; the `manual` report is what tells you a disk was moved by hand. |
| `bios` | recreate | none | — | Firmware chosen at creation; the old script's only FATAL. An undeclared bios is not compared at all, so a guest on seabios does not drift forever. |
| `ostype` | recreate | none | — | A creation-time hardware hint. *See [recommendation 4](../../../tappaas-cicd/UPDATE-POLICY.md#4-clustervm-ostype-is-stricter-than-reality).* |
| `autoInstall` | recreate | none | boolean | Drives the unattended install; meaningless afterwards. |
| `sshAccess` | recreate | none | boolean | Seeds cloud-init at creation. |
| `vmid` | immutable | none | — | A different vmid is a different guest. |
| `os` | immutable | none | — | Auto-detected from the image at install. |
| `imageType` | immutable | none | — | clone vs download; not re-decidable. |
| `image` | immutable | none | — | What the guest was built from. |
| `imageLocation` | immutable | none | — | As `image`. |
| `cloudInit` | immutable | none | boolean | How it was provisioned. |

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
