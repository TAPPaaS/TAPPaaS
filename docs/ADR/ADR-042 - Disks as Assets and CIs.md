# ADR-042 — Disks as Assets and CIs

| | |
|---|---|
| **Status** | **Accepted** (operator, 2026-10-31) |
| **Version** | 1.0 |
| **Date** | 2026-10-31 |
| **Author** | Lars Rossen |
| **Deciders** | @LarsRossen, @ErikDaniel007 |
| **Closes / addresses** | ADR-040 O4 (disks become assets and CIs of their own, in an ADR of their own). Amends ADR-040 D3 (a `disk` class), D5 (a disk's identity), D7 (a disk's placement is a bay in another asset), D15 (what the sweep does with a disk it finds); ADR-041 D3 (a pool's vdev is a redundancy group). Related: ADR-019 (storage), ADR-039 (alerts). |
| **Changelog** | v1.0 (2026-10-31) — first version, from the operator's direction of 2026-10-31 ("let us do disks as well in assets and CIs"): a disk is an asset with the serial as its identity and a bay in a server as its placement, a `disk` CI `part-of` its asset, and the thing a pool is `built-on` — one redundancy group per mirror or raidz vdev, so a failed disk degrades its pool (ADR-041 O6) and is the root cause the operator is mailed about. |

A disk is the part of a site that fails most, moves between machines, and has to be wiped before
it leaves. ADR-040 kept disks as attributes of the server (`disks[]`) and of the pool (`vdevs[]`)
in its first implementation and left them to this ADR (O4). With ADR-041 O6 closed — a partly
failed redundancy degrades, and what is mailed is the root cause — the disk is the missing root:
today a failed disk shows as a `DEGRADED` pool whose message names a serial, and the pool is the
root cause. This ADR makes the disk the asset and the CI, and the pool its dependant.

## Context

- **What is known today.** site-manager's discovery (`cmdb-discover.ts`, ADR-040 D15) reads every
  disk of a node from `pvesh /nodes/<n>/disks/list` and `lsblk`: by-id name, device, model, serial,
  size, type (nvme, ssd, hdd, usb), bus, Proxmox's `health`, what it holds and its partitions; and
  every ZFS pool's vdevs with their members by device and serial and state. storage-manager's
  `inventory` reads SMART (attributes, temperature, wearout) and judges each disk (`smart`, `zfs`,
  `wear`, `temperature`), which health-manager's `storage-disks` gate collects — the slowest gate,
  27 of assess's 91 seconds on hrossen, because SMART is read on every run.
- **Where it is stored today.** On the `server` asset's CI (`nics[]`, `disks[]`) when the node has
  an asset, else on the `machine`; the pool's `vdevs` carry the members. Neither is a CI: nothing
  has a condition, a history or a relation of its own.
- **The asset side.** ADR-040 D7 records an asset's lifecycle (ordered, stock, placed, disposed) and
  D9 its ports as `ports[]` in `positions.json`; a port became a `port` CI `part-of` its asset
  (D3). A disk is the same shape one level down: a part of an asset, with an identity of its own
  (serial), that can be taken out and put into another asset.
- **The installer's hook (ADR-040 D8).** `node add` records a new machine's NICs as the asset's
  ports from the identity the installer posts; disks are not posted yet.

## Decision

### D1 — A disk is an asset; its placement is a bay in another asset

A disk is an asset of kind **`disk`** in asset-manager's register (`positions.json` `assets`,
ADR-040 D7), named by the next tag `dsk-NN` (ADR-040 O5) with its by-id name as display name. Its
record: `vendor`, `model`, `serial`, `wwn`, `size` (bytes), `kind` (`nvme`, `ssd`, `hdd`, `usb`),
`bus`, `firmware`, and the lifecycle fields every asset has — `stage`, `faulty`, `procurement`,
`disposal`. **Its placement is a bay of another asset**, not a rack: `placements` gains a third
form beside `{rack, u}` and `{room}`: `{ in: <asset>, bay: <name> }`, where `bay` is the server's
slot label when known, else the by-id name. `asset-manager place <disk> --in <asset> [--bay <b>]`
places it; `unplace` takes it out (it goes to stock, D7); placing a disk that is in one asset into
another is the move. A disk in a server's bay shows on the server's card in the Physical view and on
the asset's page; a disk in stock shows in the Assets view under its location.

### D2 — Identity: the serial

A disk's identity (ADR-040 D5) is its `serial`, then its `wwn`; vendors spell a serial differently
across tools (Proxmox's list, SMART, `lsblk`), so it is compared case-insensitively with
whitespace and dashes removed, and the stored form is Proxmox's. A by-id name is not an identity:
it changes with the controller and the slot.

### D3 — A `disk` CI, `part-of` its asset, and what a pool is `built-on`

cmdb-controller's metamodel (ADR-040 D3, D13) gets a class **`disk`** under `resource` beside
`port`: physical, keyed by its `asset` (`part-of`, required, immutable) and its `name` (the by-id
name), with `serial` unique across all disks, the record fields of D1, and volatile observations
— `health` (Proxmox's word: PASSED, FAILED, UNKNOWN), `wearout` (% of rated life left), `temperature`,
`smart` (the attributes that matter: reallocated, pending, uncorrectable, power-on hours),
`holds` (zfs, lvm, efi, a filesystem, nothing) and `partitions`. A disk `follows` its asset's
colour where nothing judges it (ADR-041 D3 FOLLOWS, as a port does).

A new relation type **`built-on`**: a `storage-pool` is built on its member disks (`dependant:
from`, `required: true`, `tree: false`). site-manager's report makes one per pool member, from the
pool's vdevs matched to disks by serial, and sets **`redundancyGroup` = `<node>:<pool>:<vdev>`**
on the members of a mirror or raidz vdev (none on a single-disk vdev; `logs`, `cache` and `spares`
members get `required: false`). With ADR-041 O6, one failed member degrades the pool (a `warning`
impact naming the disk as root), and a vdev with every member failed takes the pool down
(`critical`). The pool's own `zfsState` stays its own observation: when ZFS says `DEGRADED` and
the derivation says the same from the disk, the pool's condition is `derived` and the disk is the
root the operator is mailed about (ADR-041 D4); when ZFS says `DEGRADED` and no disk explains it
(a resilver, a removed device), the pool is its own root, as today.

The server's `disks[]` attribute and the pool's `vdevs[]` stay (the sweep's full depth, D15), so a
node without an asset, or a disk no asset records, is still seen; they are not CIs.

### D4 — Who records a disk: node add and the operator, never the sweep

ADR-040 D15 holds: a sweep never invents an asset. A disk becomes an asset in three ways:

- **`node add`** (ADR-040 D8's hook): the installer's post gains `disks[]` (by-id, model, serial,
  size, type, bus) beside its NICs; node-provisioner keeps them on the registration; site-manager
  records each as a `dsk-NN` asset placed in the node's server asset, as it records NICs as ports
  — and a disk whose serial an asset already records (a disk moved from another machine) is placed
  in the new server instead of recorded twice.
- **`asset-manager disk add <asset> --serial <s> [--model …]`** by hand, and the console's asset
  page; `disk remove`, `disk modify`.
- **`asset-manager disk adopt [<asset>]`** once, for the servers that exist today: records every
  disk the CMDB's server CI lists (`disks[]`, by serial) as an asset placed in that server. The
  console's Assets page offers it where a server's CI knows disks its asset does not record.

A disk the sweep finds that no asset records is *actual without desired* (ADR-040 D15:
`unmanaged`), listed in the digest with the `disk adopt` command, not drift.

### D5 — Health: the disk is judged from observations; the SMART read moves to the sweep

`assess` judges a `disk` from its observations (ADR-041 plan step 2, O3's direction): `health`
FAILED, or a `built-on` member state FAULTED or UNAVAIL in the pool's vdevs, is `operational`
`critical`; reallocated or pending sectors, `wearout` under 10 %, or `temperature` over the
threshold are `operational` `warning`, with the cause in the reason (`smart`, `wear`,
`temperature`, `zfs`) as storage-manager words them today. The **`storage-disks` gate retires**:
its disk rows come from the disk CIs, its pool rows from `storage-pool` (already judged from
`zfsState`), its replication rows move to a `replication` judgement on the `vm` from the inventory's
replication state, which stays a gate until the sweep carries it. SMART is read by the **discovery
sweep** (D15, nightly and on demand) and by `site-manager report --discover`, not by the 5-minute
report: Proxmox's `health` word in `disks/list` is cheap and comes every 5 minutes; attributes and
temperature once a day, which is what SMART is for. This takes about 27 seconds out of every assess.

### D6 — The console

The Assets view (ADR-040 D10) shows a disk under the server it is in, with its serial, size, kind,
health and the pool it is a member of; a disk in stock under its location. The asset's page lists
its disks with their bays; the Physical view's server card shows a bay row; the Storage view lists
a pool's members as disks with their state, each opening the disk's panel (its CI record, history
and allocations: which servers it has been in). Disposal of a disk asks whether it was wiped and
records it (ADR-040 D7's disposal note).

## Consequences

- One more asset kind and one more CI class; a third placement form (`in`), which the positions
  validator, asset-manager, the sweep's placement reading and the console's Physical view must know.
- The root cause of a disk failure is the disk, with the pool, the guests whose storage is on it
  (`storage-pool` → guests: the ADR-041 rule a site may add) and the services as its consequence —
  the mail the operator asked for.
- assess loses its slowest gate; the sweep gains the SMART read once a day.
- Moving a disk is recorded: the asset's history of placements shows which servers it has been
  in, which answers "where did that disk go" when a pool loses a member.

## Alternatives considered

- **Disks stay attributes, with a condition on the pool only.** Cheapest, but the root cause is
  wrong (the pool is not what failed) and a moved or spare disk has no record. Rejected by O4.
- **Every partition or vdev as a CI.** Partitions and vdevs are layout, not things that fail or move;
  they stay attributes of the disk and the pool.
- **Disks placed in a rack unit.** A disk is in a server, not in a rack; the `in` placement says so
  and keeps the rack drawing honest.

## Open questions

- **O1** *(open)* Whether a USB disk plugged into a node for a backup target (ADR-012) is an asset:
  proposed yes, kind `usb`, placed `in` the node while plugged; its comings and goings are history.
- **O2** *(open)* The wearout threshold (10 %) and the temperature threshold: site settings beside
  `health.assessInterval`, or fixed.

## Implementation plan

1. **Done.** Metamodel: the `disk` class, the `built-on` relation with its words, the health rule needs
   nothing new (ADR-041 O6's group handling); positions model: kind `disk`, the `in` placement,
   validation; asset-manager `disk add|modify|remove|adopt`, `place --in`; its CMDB report sends
   disks `part-of` their asset and their placement.
2. **Done.** site-manager: `disks[]` on the installer's post and the registration; `node add` records disks;
   `report` sends `built-on` with the groups; `report --discover` carries SMART.
3. **Done.** health-manager: the `disk` judgement from observations; `storage-disks` retired, replication
   kept as a gate; the storage-manager inventory's SMART read behind the sweep.
4. **Done.** Console: Assets view and asset page with disks; server card bay row; Storage view members;
   disposal with the wipe question.
5. Live on the test system: `disk adopt` on the three servers, a sweep, `topology --diff` and
   `health-manager assess --timing` before and after.
