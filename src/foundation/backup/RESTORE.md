# Restoring a TAPPaaS system

Primary audience: TAPPaaS admin, mid-incident.

**A backup with no rehearsed restore is not a backup.** Every procedure marked
**rehearsed** below has been run end to end on a live cluster; the transcript is
in the [ADR-012 implementation tracker](../../../docs/design/ADR-012-implementation.md#package-logs).
The ones marked **unrehearsed** are written from the code and are honestly
labelled as such — do not meet them for the first time during an incident.

---

## 0. Before anything: the key

Backups are **encrypted client-side**. The keys are escrowed on the mothership —
which is inside the system a full rebuild recreates — so that escrow cannot be
the only copy:

```bash
backup-manager key list                      # what is escrowed
backup-manager key export /media/usb-stick   # the mandatory out-of-band copy
backup-manager key import /media/usb-stick   # onto a REBUILT mothership, before restoring
```

Losing every copy of a key makes the data it encrypted permanently unreadable.
The compromise isolation that protects you from an attacker protects you from
yourself just as well.

## What can be restored, and what is rebuilt instead

Not everything should be restored from a backup — some things are cheaper and
safer to regenerate from declared state. Knowing which is which *before* an
incident is most of the recovery.

| Module | Backed up? | How it comes back |
|---|---|---|
| App / data-bearing modules | `backup:vm` (opt-in) | restore the VM — [§1](#1-a-module-is-misbehaving--roll-it-back), [§2](#2-restoring-a-module-onto-a-system-that-never-had-it) |
| `network` (the firewall) | `backup:vm` | **prefer rebuilding** from declared state — [§4](#4-network-rebuild-rather-than-restore) |
| `tappaas-cicd` (mothership) | `backup:vm` **and** `backup:filesystem` | restore `config/` into a running one, or rebuild + restore the capture — [§5](#5-tappaas-cicd-the-machine-you-cannot-restore-from-itself) |
| `cluster` | **no** — provider-only, owns no VM | a node comes back via [§3](#3-a-node-is-lost); the module is reinstalled |
| `templates` | **no** — provider-only, owns no VM | reinstall; templates are rebuilt from source images |
| `backup` itself | **no** — PBS is apt-on-a-node, not a VM | reinstall the module; the **datastore** is the thing that must survive |
| Hardware / test modules | **no**, deliberately (declare neither capability) | reinstall |

Check any module's actual coverage rather than assuming:

```bash
backup-manager list                 # IN-PBS-JOB per module, with effective policy
backup-controller job-status        # the live jobs and their members
./restore.sh --vmid <id> --list     # what snapshots exist for one guest
```

---

## 1. A module is misbehaving — roll it back

**Rehearsed.** The everyday case: a module was working, an update or a change
broke it, and you want yesterday back.

### 1.1 Look before you leap

```bash
./restore.sh --vmid 340 --list        # pick a snapshot; note its date
module-manager show nextcloud         # what the declared config says today
```

A restore rolls the guest back to what it was **at snapshot time**, including
anything the platform has configured inside it since. That is the point, and it
is also the trap: the declared config in `config/` did *not* roll back, so the
guest and its declaration are now out of step.

### 1.2 Restore beside it first, if you can afford the disk

```bash
./restore.sh --vmid 340 --target-vmid 940 --node tappaas1 --storage tanka1
```

Restores **alongside** the original — stopped, with fresh MAC addresses, and it
refuses a VMID already in use. Inspect it, confirm the snapshot really contains
the good state, then throw it away (`qm destroy 940 --purge`) and do the real
restore. Never start a copy on the same network as its running original: two
guests answering for one identity is worse than the guest being down.

### 1.3 Restore in place

```bash
./restore.sh --vmid 340               # prompts before overwriting
```

Three things this does that a hand-run `qmrestore` does not:

- **Stops an HA-managed guest through the CRM and confirms it stopped.**
  `qm stop` on an HA resource only *requests* a stop; a script that sleeps and
  moves on is racing the cluster. That race (#434) once left this site's gateway
  down for 7h41m.
- **Destroys with `--purge --destroy-unreferenced-disks`**, so the VMID leaves
  the backup/replication jobs and HA cleanly, and **no disks from the previous
  incarnation are left behind**. A restore that inherits a stale volume gives
  you a guest that boots from one disk while another quietly consumes the pool.
- **Verifies the guest exists afterwards** instead of trusting the restore
  command's own report.

### 1.4 Re-apply the declaration, then check it works

The restored guest is at snapshot state; `config/` is at today's state. Put them
back in step — this is the step that is easiest to skip and most often the
reason a "successful" restore misbehaves:

```bash
module-manager module modify nextcloud     # re-applies declared config, re-wires services
module-manager module test nextcloud --deep
```

`modify` re-runs the module's converge: dependency services are re-applied
(`backup:vm` re-registers it in the right schedule bucket, `network:proxy`
re-publishes it, `identity` re-wires SSO), and the module's own `update.sh`
re-asserts what it owns.

### 1.5 Confirm HA and replication came back

`--purge` removed the VMID from HA and replication on the way out; the restore
does not put them back. If the module declares `cluster:ha`:

```bash
module-manager drift nextcloud --service cluster:ha    # what is missing
module-manager module modify nextcloud                 # re-applies it (step 1.4 does this)
ssh root@tappaas1.mgmt.internal "ha-manager config; pvesh get /cluster/replication"
```

Confirm the resource is listed and `started`, and that a replication job exists
for each declared target. A guest that came back **without** HA looks perfectly
healthy right up until the node it is on fails.

---

## 2. Restoring a module onto a system that never had it

**Unrehearsed** — the mechanism is §1's, but this sequence has not been run end
to end.

A backup carries a guest's *disks and its Proxmox config*; it does not carry the
module's TAPPaaS declaration — the VMID, node, zone, sizing, proxy domain and
service wiring all live in `config/<module>.json` on the mothership. Restoring a
guest without that declaration gives you a running VM the platform knows nothing
about.

So: **declare first, restore second.**

```bash
# 1. Install the module normally — a bare-bones instance, correctly declared.
cd ~/TAPPaaS/src/apps/nextcloud && module-manager module add nextcloud
#    Its VMID/node/zone now exist in config/nextcloud.json and on the cluster.

# 2. Restore the backup OVER that fresh guest, into the VMID the install chose.
cd ~/TAPPaaS/src/foundation/backup
./restore.sh --vmid <VMID-IN-THE-BACKUP> --target-vmid <VMID-JUST-INSTALLED> \
             --node <node> --storage <pool>

# 3. Re-apply the declaration and validate (§1.4, §1.5).
module-manager module modify nextcloud
module-manager module test nextcloud --deep
```

Two things to get right:

- **The backup's VMID and the new VMID usually differ.** `--target-vmid` is what
  bridges them. Restoring into the *installed* VMID keeps the platform's view
  (config, DNS, proxy, firewall rules) intact and swaps only the disks.
- **The restored guest carries the old system's identity inside it** — hostname,
  SSH host keys, certificates, and whatever the old site's IP was. `module
  modify` fixes what the platform declares; anything baked inside the guest is
  yours to reconcile. For a module whose data is separable, restoring only the
  *data* into a freshly installed guest is often less work than reconciling a
  transplanted machine.

---

## 3. A node is lost

**Unrehearsed.** Recovering a node is three separate jobs, and they must happen
in this order.

### 3.1 Evict the dead node from the cluster

A replacement cannot take the old name while Proxmox still believes the old node
exists. From a **surviving** node:

```bash
ssh root@tappaas1.mgmt.internal
  ha-manager config                       # note what was pinned to the dead node
  pvecm nodes                             # confirm it is down, not merely unreachable
  pvecm delnode tappaas2
  rm -rf /etc/pve/nodes/tappaas2          # only after delnode, and only if empty of configs you need
```

Then drop it from the site register (this only edits `site.json` — it does no
cluster work, which is why the Proxmox step above is separate and first):

```bash
site-manager node delete tappaas2
```

> **Take the guest configs off the dead node first if you can.** `/etc/pve` is
> cluster-replicated, so a downed node's guest configs are still visible from a
> surviving node under `/etc/pve/nodes/<name>/qemu-server/`. They are the record
> of which VMIDs lived there.

### 3.2 Bring the replacement back in

```bash
site-manager node add tappaas2 --pool tanka1=single:nvme0n1     # adopt a hand-installed Proxmox
site-manager node add tappaas2 --pxe --boot-disk nvme0n1        # or PXE-install it
```

Reusing the same name is deliberate: module declarations, HA affinity rules and
storage entries all reference nodes by name, so a replacement called `tappaas2`
inherits its predecessor's role instead of needing every reference rewritten.

Node-add joins the cluster, captures the node in `site.json`, registers its pools
as cluster storage, and **reconciles the backup client onto it** (ADR-012 §2.4) —
without that last step, VMs later placed there would silently have no backups.

### 3.3 Restore the guests that lived there

For each VMID that was on the dead node — one at a time, validating each:

```bash
cd ~/TAPPaaS/src/foundation/backup
./restore.sh --vmid <id> --node tappaas2 --storage tanka1
module-manager module modify <module>
module-manager module test <module> --deep
```

Guests that were **HA-managed and replicated** may already be running on a
surviving node — the cluster failed them over, which is what HA is for. Do not
restore those: check `ha-manager config` first. Restoring a guest that is running
elsewhere gives you two of it.

### 3.4 Re-establish HA and replication across the new topology

HA affinity and ZFS replication are declared per module and realised per
topology, so they need re-applying once the node set has changed:

```bash
update-tappaas --force        # folds HA + replication over the new topology
module-manager list --diff    # what is still out of step
```

---

## 4. `network`: rebuild rather than restore

**Unrehearsed as a full rebuild** (the VM restore *is* rehearsed — see the
tracker).

The firewall VM is backed up, and restoring it works. But a restore is usually
the *worse* option, because the firewall is the most declaratively-generated
thing in the system:

- the VM is created from a **prebuilt OPNsense image**;
- its unique identity (API key/secret, root password) is **generated** at
  bootstrap and pushed in as a rendered `config.xml`;
- zones, VLANs, firewall rules, DNS records, NAT and the reverse proxy are then
  applied from `zones.json` and the module declarations by `zone-manager`,
  `dns-manager`, `caddy-manager` and `opnsense-controller`.

So a rebuild reproduces the *intended* firewall, while a restore reproduces a
firewall from a point in time — including any drift it had accumulated, and
missing every zone or rule declared since.

**Prefer:**

```bash
cd ~/TAPPaaS/src/foundation/network && module-manager module modify network
# and if the VM itself is gone, re-run the module install, then:
update-tappaas --force        # re-applies every module's proxy/rules/dns/nat
```

**Restore the VM instead when** the OPNsense configuration contains state that
TAPPaaS does not declare — hand-made GUI changes, VPN peers, DHCP static
mappings, captive-portal or IDS configuration. That state exists only inside the
guest, and only a restore brings it back.

> **The one credential that does not regenerate itself:** the mothership
> authenticates to OPNsense with `~/.opnsense-credentials.txt` (`key=` /
> `secret=`). OPNsense stores only a hash, so a lost file cannot be read back —
> create a new API key in the OPNsense GUI (System → Access → Users → API) and
> write the two lines. See §5's note: that file is **not** in the mothership's
> file capture.

---

## 5. `tappaas-cicd`: the machine you cannot restore from itself

**`config/` restore is rehearsed. Full mothership rebuild is unrehearsed.**

The mothership is backed up two ways on purpose:

- **`backup:filesystem`** captures `/home/tappaas/config` (the declared state of
  the entire site) and `/etc/secrets`, nightly at 20:30. This is the one that
  matters most: it restores in seconds into a running system, and — unlike a VM
  snapshot — it can be restored onto a **different** mothership.
- **`backup:vm`** snapshots the whole guest, for when the machine itself is gone.

### 5.1 Restoring `config/` (the common case)

```bash
export PBS_PASSWORD="$(sudo cat /etc/secrets/backup-fs.pw)"
export PBS_FINGERPRINT="$(jq -r .fingerprint ~/config/tappaas-cicd.fsbackup.json)"
REPO="$(jq -r .repository ~/config/tappaas-cicd.fsbackup.json)"

proxmox-backup-client snapshot list --repository "$REPO" --ns fs/tappaas-cicd
proxmox-backup-client restore host/tappaas-cicd/<TIME> home-tappaas-config.pxar /tmp/restore \
    --repository "$REPO" --ns fs/tappaas-cicd --keyfile /etc/secrets/backup-fs.key

diff -r /home/tappaas/config /tmp/restore     # look before you copy
```

Copy back only what you meant to. Restoring the whole tree over a live `config/`
rolls back every module installed or changed since the capture.

### 5.2 Rebuilding a lost mothership

**You cannot restore the mothership from itself** — `restore.sh` runs on
`tappaas-cicd` and drives the restore over SSH, so restoring VMID 130 from
VMID 130 destroys the machine running the command mid-flight. Drive it from a
**node** instead:

```bash
ssh root@tappaas1.mgmt.internal
  # pick the snapshot, then restore it as VMID 130 on a surviving node
  pvesm list tappaas_backup --vmid 130
  qmrestore <volid> 130 --storage tanka1
  qm start 130
```

Then, on the rebuilt mothership, in this order:

1. **`backup-manager key import /media/usb-stick`** — before anything that must
   decrypt. Without the out-of-band key, the encrypted backups are unreadable.
2. Restore `config/` (§5.1) if the VM snapshot is older than the file capture —
   the file capture usually is newer, and it is the site's source of truth.
3. `update-tappaas --force` to re-converge the estate.

### 5.3 What the capture does *not* include

`/home/tappaas/config` and `/etc/secrets` are captured. Two credential files sit
in `/home/tappaas/` itself and are **not**:

| File | What it is | If lost |
|---|---|---|
| `~/.opnsense-credentials.txt` | firewall API key/secret | create a new API key in the OPNsense GUI and rewrite the file (§4) |
| `~/.pbs-credentials.txt` | generated `tappaas@pbs` password (unattended installs) | reset it: `proxmox-backup-manager user update tappaas@pbs --password` on the PBS node |

A `.pxar` archive must be a directory, so single files cannot simply be added to
`filesystemPaths`. Keep copies of these two alongside the out-of-band encryption
key, or relocate them under `config/` so the capture covers them.

> `/etc/secrets` contains `backup-fs.key` — the key the capture itself is
> encrypted with. Capturing it is still worth doing (it restores the *other*
> secrets once you can decrypt), but it is circular: you need the out-of-band
> copy to open the backup that contains it.

---

## 6. `cluster`, `templates`, `backup`: nothing to restore

These three own no guest, so there is no VM backup and nothing to restore:

- **`cluster`** provides `vm` / `lxc` / `ha` — it configures Proxmox itself.
  Recovering a node is [§3](#3-a-node-is-lost); the module is reinstalled.
- **`templates`** provides the NixOS/Debian template clones. They are rebuilt
  from source images — backing them up would store a derived artifact.
- **`backup`** is PBS installed by apt on a node, not a VM. Reinstalling it is
  routine; what must survive is the **datastore**, which lives on its own `tankc`
  pool precisely so a production-disk failure cannot touch it. If the datastore
  is gone, so is the history — that is why [§0](#0-before-anything-the-key) and an
  off-site copy exist.

If the PBS node itself is lost, rebuild the node ([§3](#3-a-node-is-lost)),
reinstall the module, and re-attach the datastore — the installer re-attaches an
existing chunk store rather than refusing a non-empty path.

---

## 7. Relocating the datastore without losing history

**Unrehearsed.** When PBS itself moves — an old node to a new `tankc`, or an
external PBS to a local one — the old snapshots must not be discarded. Seed the
new datastore by **pulling** from the old one rather than starting empty:

```bash
./backup-manage.sh add-remote old-pbs     # register the OLD PBS as a pull source
#   … let the sync job run, then verify the snapshots arrived …
./backup-manage.sh use-external <new-url> # or re-run the install to resolve node:<new>
#   … restore something from the NEW target and confirm it works …
./backup-manage.sh remove-remote old-pbs  # only now decommission the old datastore
```

This is plain pull replication (ADR-012 §4.3) — there is no special migration
path and nothing is rewritten. **Decommission only after the pull *and* a test
restore are green**: a copied datastore that has never been restored from is a
hypothesis, not a backup.

This is also why `backup-manage.sh use-external` refuses to run from a live
local PBS: switching to an external one is permanent, and doing it before the
history has been pulled across would orphan a datastore full of backups.

---

## 8. Verifying, on a normal day

```bash
backup-manager validate                       # the hierarchy is consistent
backup-manager list                           # coverage, per module
TAPPAAS_TEST_DEEP=1 ./test.sh                 # unit suites + live PBS reachability
TAPPAAS_TEST_DEEP=1 ./services/vm/test-service.sh <module>          # backup age + job coverage
TAPPAAS_TEST_DEEP=1 ./services/filesystem/test-service.sh <module>  # capture age
./test-compromise-isolation.sh                # the §1.4.1 invariant, end to end
```

PBS verifies its own chunks nightly (04:00 verify-job, plus verify-on-write).
That catches bit-rot. It does not catch *"we never actually backed this up"* —
that is what `backup-manager list` is for — and it does not catch *"the restore
does not work"*, which is what a rehearsal is for.

**Rehearse §1 and §5.1 at least once per release.** The first time these were
rehearsed, three defects surfaced that were invisible from the outside: a backup
lookup that parsed a table header, a failed restore that reported success, and a
mothership that had never been in the backup job at all.
