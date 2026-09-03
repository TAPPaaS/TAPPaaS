# Update policy — `cluster:vm`

**Manifest:** [`fields.json`](fields.json) · **Vocabulary:**
[the seven change classes and five apply modes](../../../tappaas-cicd/UPDATE-POLICY.md#1-the-seven-change-classes)
· **Index:** [all services](../../../tappaas-cicd/UPDATE-POLICY.md#4-the-per-service-manifests)

26 fields — 5 `set` · 8 `composite` · 2 `hook` · 11 `none`.

The reference manifest: every class in the taxonomy appears here, each read off
what `update-service.sh` did before ADR-020.

The **Seed** column marks `defaultIsDesired: false` — the schema default is an
install-time starting value, not desired state, so an undeclared field is left
alone rather than reset. [What that means](../../../tappaas-cicd/UPDATE-POLICY.md#seed--a-modifier-not-a-mode).

| Field | Class | Apply | Normalize | Seed | Why this class |
|---|---|---|---|:--:|---|
| `vmname` | in-place | set | — | | A live `qm set --name`. |
| `vmtag` | in-place | set | tags | seed | Undeclared tags are left alone, not overwritten with `TAPPaaS`. |
| `cores` | in-place | set | integer | | Hot-pluggable. |
| `memory` | in-place | set | integer | | Hot-pluggable. |
| `cputype` | in-place | set | — | | Proxmox spells it `cpu`. The #550 field. |
| `bridge0` | in-place-reboot | composite | — | | A new L2 segment; the guest must re-DHCP. |
| `zone0` | in-place-reboot | composite | vlan | | New tag, new subnet. |
| `mac0` | **in-place-reboot** | composite | — | | A new MAC is a new identity: new lease, likely new IP, DNS must follow. Unpinned, the live MAC is carried across and nothing drifts. |
| `trunks0` | in-place | composite | trunks | | A trunk-only change needs no reboot. |
| `bridge1` | in-place-reboot | composite | optional | | Also the add/remove switch for the second NIC. |
| `zone1` | in-place-reboot | composite | vlan | | As `zone0`. |
| `mac1` | **in-place-reboot** | composite | — | | As `mac0`. |
| `trunks1` | in-place | composite | trunks | | As `trunks0`. |
| `diskSize` | grow-only | hook | size | seed | Grows via `resize-disk.sh`; a shrink is refused at apply time. |
| `node` | migrate | hook | — | | The ADR-019 bridge; routes HA vs non-HA internally. See [what happens today](../../../tappaas-cicd/UPDATE-POLICY.md#7-node-and-hanode--what-happens-today-adr-019s-starting-point). |
| `storage` | manual | none | — | seed | An implicit `move-disk` is long and IO-heavy — an operator schedules it. |
| `bios` | recreate | none | — | seed | Firmware chosen at creation; the old script's only FATAL. |
| `ostype` | recreate | none | — | | A creation-time hardware hint. *See [recommendation 4](../../../tappaas-cicd/UPDATE-POLICY.md#4-clustervm-ostype-is-stricter-than-reality).* |
| `autoInstall` | recreate | none | boolean | | Drives the unattended install; meaningless afterwards. |
| `sshAccess` | recreate | none | boolean | | Seeds cloud-init at creation. |
| `vmid` | immutable | none | — | | A different vmid is a different guest. |
| `os` | immutable | none | — | | Auto-detected from the image at install. |
| `imageType` | immutable | none | — | | clone vs download; not re-decidable. |
| `image` | immutable | none | — | | What the guest was built from. |
| `imageLocation` | immutable | none | — | | As `image`. |
| `cloudInit` | immutable | none | — | | How it was provisioned. |

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
