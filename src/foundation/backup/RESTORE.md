# Restoring a TAPPaaS system

Primary audience: TAPPaaS admin, mid-incident.

**A backup with no rehearsed restore is not a backup.** Every procedure marked
**rehearsed** below has been run end to end on a live cluster; the transcript is
in the [ADR-012 implementation tracker](../../../docs/design/ADR-012-implementation.md#package-logs).
The ones marked **unrehearsed** are written from the code and are honestly
labelled as such.

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
safer to regenerate from declared state.

| Module | Backed up? | How it comes back |
|---|---|---|
| App / data-bearing modules | `backup:vm` (opt-in) | restore the VM — [§1](#1-a-module-is-misbehaving--roll-it-back), [§2](#2-restoring-a-module-onto-a-system-that-never-had-it) |
| `network` (the firewall) | `backup:vm` | **prefer rebuilding** from declared state — [§4](#4-network-rebuild-rather-than-restore) |
| `tappaas-cicd` (mothership) | `backup:vm` **and** `backup:filesystem` | restore `config/` into a running one, or rebuild + restore the capture — [§5](#5-tappaas-cicd-the-machine-you-cannot-restore-from-itself) |
| `cluster` | **no** — provider-only, owns no VM | a node comes back via [§3](#3-a-node-is-lost); the module is reinstalled — [§6](#6-cluster-and-backup-nothing-to-restore) |
| `templates` | **no** — provider-only, owns no VM | rebuild from source images — [§7](#7-templates-rebuilt-never-restored) |
| `backup` itself | **no** — PBS is apt-on-a-node, not a VM | reinstall the module — [§6](#6-cluster-and-backup-nothing-to-restore). The **datastore** is what must survive; if it does not, recover from a buddy — [§8](#8-recovering-from-an-off-site-buddy) |
| Hardware / test modules | **no**, deliberately (declare neither capability) | reinstall |

**Use `backup-manager restore`**, not the module's `restore.sh` directly. The
manager resolves a *module name* to its VMID from the deployed config and
forwards everything else to the same tested script, so you name the thing you
are recovering rather than a number you have to look up, and options after the
module name pass straight through (`--node`, `--storage`, `--target-vmid`, and
`--vmid` to read a *different* source VMID — see
[§2](#2-restoring-a-module-onto-a-system-that-never-had-it)). `restore.sh` in
the backup module remains the implementation underneath.

`module-manager` and `backup-manager` resolve a module by name from the deployed
config or a repository catalog, so none of these commands need you to be in a
particular directory. The exception is installing a module that is in **no**
catalog — then run `module-manager module add` from its source directory.

Check any module's actual coverage rather than assuming:

```bash
backup-manager list                     # OPTED-IN vs IN-PBS-JOB per module, + policy
backup-manager restore list <module>    # what snapshots exist for one module
backup-manager restore list-all         # every backup in the datastore
backup-controller job-status            # the live jobs and their members
```

---

## 1. A module is misbehaving — roll it back

**Rehearsed.** The everyday case: a module was working, an update or a change
broke it, and you want yesterday back.

### 1.1 Look before you leap

```bash
backup-manager restore list nextcloud   # snapshots for this module; note the date
module-manager show nextcloud           # what the declared config says today
```

A restore rolls the guest back to what it was **at snapshot time**, including
anything the platform has configured inside it since. That is the point, and it
is also the trap: the declared config in `config/` did *not* roll back, so the
guest and its declaration are now out of step.

### 1.2a Restore in place

The direct route: overwrite the running guest with the snapshot.

```bash
backup-manager restore restore nextcloud     # prompts before overwriting
```

This will:

- **Stop an HA-managed guest through the CRM and confirm it stopped.** `qm stop`
  on an HA resource only *requests* a stop; a script that sleeps and moves on is
  racing the cluster. That race (#434) once left this site's gateway down for
  7h41m. If the stop cannot be confirmed, nothing is destroyed.
- **Destroy with `--purge --destroy-unreferenced-disks`**, so the VMID leaves the
  backup/replication jobs and HA cleanly, and **no disks from the previous
  incarnation are left behind**. A restore that inherits a stale volume gives you
  a guest that boots from one disk while another quietly consumes the pool.
- **Restore the snapshot** into that VMID, on the node and storage you name (or
  the originals).
- **Verify the guest exists afterwards**, rather than trusting the restore
  command's own report.

### 1.2b Or restore beside it first, if you can afford the disk

When you are not certain the snapshot holds the good state — or the guest is
still limping along and you would rather not destroy it yet:

```bash
backup-manager restore restore nextcloud --target-vmid 940 --node tappaas1 --storage tanka1
```

This will:

- restore into VMID **940** and leave the original untouched;
- leave the copy **stopped**, and give it **fresh MAC addresses**;
- refuse outright if 940 is already in use.

Inspect it, confirm the snapshot is what you want, then discard it
(`qm destroy 940 --purge`) and do the real restore with 1.2a.

Never start a copy on the same network as its running original: two guests
answering for one identity is worse than the guest being down.

### 1.3 Re-apply the declaration, then check it works

The restored guest is at snapshot state; `config/` is at today's state. Put them
back in step — this is the step that is easiest to skip and most often the
reason a "successful" restore misbehaves:

```bash
module-manager module update nextcloud     # re-applies declared config, re-wires services
module-manager module test nextcloud --deep
```

`modify` re-runs the module's converge: dependency services are re-applied
(`backup:vm` re-registers it in the right schedule bucket, `network:proxy`
re-publishes it, `identity` re-wires SSO), and the module's own `update.sh`
re-asserts what it owns.

### 1.4 Confirm HA and replication came back

`--purge` removed the VMID from HA and replication on the way out; the restore
does not put them back. If the module declares `cluster:ha`:

```bash
module-manager drift nextcloud --service cluster:ha    # what is missing
module-manager module update nextcloud                 # re-applies it (step 1.4 does this)
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
module-manager module add nextcloud
#    Its VMID/node/zone now exist in config/nextcloud.json and on the cluster.

# 2. Restore the backup OVER that fresh guest.
#    --vmid names the SOURCE (the VMID inside the backup); --target-vmid names
#    where it lands (the VMID the install just chose). Without --vmid the module
#    would resolve to its new VMID and find no backup under it.
backup-manager restore restore nextcloud \
    --vmid <VMID-IN-THE-BACKUP> --target-vmid <VMID-JUST-INSTALLED>

# 3. Re-apply the declaration and validate (§1.3, §1.4).
module-manager module update nextcloud
module-manager module test nextcloud --deep
```

Two things to get right:

- **The backup's VMID and the new VMID usually differ.** `--vmid` and
  `--target-vmid` together bridge them. Restoring into the *installed* VMID keeps
  the platform's view (config, DNS, proxy, firewall rules) intact and swaps only
  the disks.
- **The restored guest carries the old system's identity inside it** — hostname,
  SSH host keys, certificates, and whatever the old site's IP was. `module
  modify` fixes what the platform declares; anything baked inside the guest is
  yours to reconcile. For a module whose data is separable, restoring only the
  *data* into a freshly installed guest is often less work than reconciling a
  transplanted machine.

---

## 3. A node is lost

**Unrehearsed.** Recovering a node is four separate jobs, and they must happen
in this order.

### 3.0 First: find out what is still running, and where

**Do not assume the guests died with the node.** Anything HA-managed and
replicated has most likely been **failed over to a surviving node already** —
that is what HA is for, and restoring a guest that is running elsewhere gives you
two of it.

This matters most for the two modules a site cannot work without. If the lost
node was the one hosting **`network`** (the firewall — everything reaches the
world through it) or **`tappaas-cicd`** (the mothership — where these very
commands run), then either they were evacuated and the site is limping along on
another node, or they were not and you are recovering blind. Establish which
before touching anything:

```bash
# Which modules are NOT where they are declared to be — i.e. what HA moved.
# `node` is the declaration, `actualNode` is where the guest is really running.
module-manager list --json \
  | jq -r '.modules[] | select(.actualNode != null and .node != "" and .actualNode != .node)
           | "\(.name): declared \(.node), running on \(.actualNode)"'

# The same question asked of the cluster itself, for when the mothership's view
# is stale or you are working from a node.
ssh root@<surviving-node>.mgmt.internal \
    "pvesh get /cluster/resources --type vm --output-format json" \
    | jq -r '.[] | "\(.vmid)\t\(.name)\t\(.node)\t\(.status)"' | sort -n

# What HA thinks it is managing, and where it placed each resource.
ssh root@<surviving-node>.mgmt.internal "ha-manager status"
```

*(A module reported with `declared null` simply does not pin a node — that is a
missing declaration, not a displacement.)*

Three outcomes, and they lead to different work:

| What you find | What it means | What to do |
|---|---|---|
| `network` / `tappaas-cicd` running on **another** node | HA evacuated them; the site is up, degraded | Do **not** restore them. Recover the node (§3.1–3.2), then migrate them **back** (§3.4) |
| They are **not running anywhere** | They were not HA-managed, or HA could not place them | Restore them first (§3.3) — start with `network`, since nothing else is reachable without it |
| The **mothership itself** is gone | You have no `module-manager`/`backup-manager` | Recover it first from a node — [§5.2](#52-rebuilding-a-lost-mothership) — then come back here |

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

**Which guests were those?** Two sources, and you want both:

```bash
# 1. What the platform DECLARES should run on that node — the recovery list.
module-manager list --json \
  | jq -r '.modules[] | select(.node=="tappaas2") | "\(.name)\t\(.vmid)"'

# 2. What actually ran there, from the dead node's own guest configs. /etc/pve is
#    cluster-replicated, so these survive the node being down and are readable
#    from any surviving node.
ssh root@tappaas1.mgmt.internal \
    "ls /etc/pve/nodes/tappaas2/qemu-server/ /etc/pve/nodes/tappaas2/lxc/ 2>/dev/null"
```

The two can differ, and the difference is informative. The first is the
declaration — what the platform intends to run there, and therefore what should
end up back on the replacement. The second is the historical record of what the
dead node was actually carrying, including anything that had been migrated onto
it without the declaration being updated.

**Skip anything §3.0 found running elsewhere.** For each remaining VMID — one at
a time, validating each:

```bash
backup-manager restore restore <module> --node tappaas2 --storage tanka1
module-manager module update <module>
module-manager module test <module> --deep
```

Guests that were **HA-managed and replicated** may already be running on a
surviving node — the cluster failed them over, which is what HA is for. Do not
restore those: check `ha-manager config` first. Restoring a guest that is running
elsewhere gives you two of it.

### 3.4 Bring the evacuated modules home, and re-establish HA

The guests HA moved in §3.0 are still running on whichever node took them. They
work there — but the site's declared placement says otherwise, and leaving them
put means the next failure has fewer places to go.

**Migrating is declaration-driven**: `module-manager migrate` realises the
placement the module *declares* and takes no node argument, so the fix for "this
is running in the wrong place" is to run it, not to name a destination:

```bash
module-manager migrate network          # back to its declared node
module-manager migrate tappaas-cicd
module-manager list                     # NODE now matches the declaration
```

Two cautions:

- **The mothership migrating itself** moves the machine your shell is on. It is
  a live migration, so the session normally survives — but do it when you can
  afford to lose the connection, and not in the middle of another recovery.
- **Check the declaration is what you still want** before migrating. If the node
  that died is not coming back, the right fix is to change where the module is
  declared to live (`module-manager modify <module> --set node=<other>`) rather
  than migrating it onto a node that no longer exists.

Then re-fold HA affinity and ZFS replication over the new node set — both are
declared per module and realised per topology, so they need re-applying whenever
the set changes:

```bash
site-manager update        # folds HA + replication over the new topology
module-manager list --diff    # what is still out of step
ssh root@tappaas1.mgmt.internal "ha-manager status; pvesh get /cluster/replication"
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
module-manager module update network
# and if the VM itself is gone, re-run the module install, then:
site-manager update        # re-applies every module's proxy/rules/dns/nat
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

`/etc/secrets` comes out of the **same snapshot** as a **second archive**, and it
has to be restored **as root**:

```bash
sudo install -d -m 700 /tmp/restore-secrets
sudo -E proxmox-backup-client restore host/tappaas-cicd/<TIME> etc-secrets.pxar /tmp/restore-secrets \
    --repository "$REPO" --ns fs/tappaas-cicd --keyfile /etc/secrets/backup-fs.key

sudo diff -r /etc/secrets /tmp/restore-secrets
sudo rm -rf /tmp/restore-secrets        # it holds the site's secrets in the clear
```

`sudo` is needed because the archive carries root-owned files: run unprivileged,
the extraction fails partway with `failed to set ownership: Operation not
permitted`, leaves a **partial** tree behind and exits non-zero. `-E` is what
carries `PBS_PASSWORD` and `PBS_FINGERPRINT` through sudo. `config/` has no such
problem — every file under it is owned by `tappaas`, which is why the command
above it needs no privilege.

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
3. `site-manager update` to re-converge the estate.

**Reinstalled instead of restored?** Then the mothership has a **new SSH key**,
and nothing trusts it yet: the nodes are key-only (#19), and each VM received
the old key once, through cloud-init, when it was created. Before step 3:

1. Put the new key on the nodes — in any node's web-GUI *Shell* (the file is
   cluster-wide, so once is enough):
   ```bash
   echo '<contents of ~tappaas/.ssh/id_ed25519.pub on the new mothership>' >> /etc/pve/priv/authorized_keys
   ```
2. On the mothership, **`cicd-key.sh recover`**. It reaches each VM through its
   QEMU guest agent from the nodes — no SSH to the VM needed — installs the new
   key, and removes every older mothership key, on the VMs and the nodes. A VM
   whose agent does not answer, and a Windows VM, are named for a manual fix.
   `cicd-key.sh recover --dry-run` shows the list first.

If the old key may have been **exposed** — a leaked backup, a lost disk — run
`cicd-key.sh rotate` instead, while it still works: it adds a new key
everywhere, proves it, switches, and only then revokes the old one.

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

## 6. `cluster` and `backup`: nothing to restore

These three own no guest, so there is no VM backup and nothing to restore:

- **`cluster`** provides `vm` / `lxc` / `ha` — it configures Proxmox itself.
  Recovering a node is [§3](#3-a-node-is-lost); the module is reinstalled.
- **`templates`** provides the NixOS/Debian template clones — rebuilt, never
  restored; see [§7](#7-templates-rebuilt-never-restored).
- **`backup`** is PBS installed by apt on a node, not a VM. Reinstalling it is
  routine; what must survive is the **datastore**, which lives on its own `tankc`
  pool precisely so a production-disk failure cannot touch it. If the datastore
  is gone, so is the history — that is why [§0](#0-before-anything-the-key) and an
  off-site copy exist.

If the PBS node itself is lost, rebuild the node ([§3](#3-a-node-is-lost)),
reinstall the module, and re-attach the datastore — the installer re-attaches an
existing chunk store rather than refusing a non-empty path. If the datastore
itself is gone, the surviving copy is off-site:
[§8](#8-recovering-from-an-off-site-buddy).

---

## 7. `templates`: rebuilt, never restored

**Rehearsed as a normal install** (it is the ordinary install path).

The `templates` module owns the VM templates other modules clone — NixOS and
Debian. They are **derived artifacts**: built from a published image plus the
module's own configuration. Backing them up would store something the build
already reproduces, and restoring an old template would hand every future module
install a stale base.

If a template is missing, corrupt, or simply out of date:

```bash
module-manager module update templates          # re-asserts what is declared
# or, if the template VM itself is gone:
module-manager module add templates --force     # rebuild from source images
module-manager module test templates --deep
```

Modules already cloned from an older template are **unaffected** — a clone is a
copy, not a link. Rebuilding the template changes what the *next* install gets,
which is usually the point.

The same reasoning covers anything else derived rather than authored: the
`backup` module's own installation, the manager binaries under `~/bin`, and the
NixOS system closure. Rebuild them; do not carry them in a backup.

---

## 8. Recovering from an off-site buddy

**Unrehearsed.** The case [§0](#0-before-anything-the-key) exists for: this
site's datastore is gone — the `tankc` pool failed, the PBS node burned, the
site was lost — and the surviving copy is the one a **buddy pulled** from you
(ADR-012 §1.4).

### 8.1 What you need before you start

- **The encryption key.** The buddy holds *ciphertext*; they cannot read your
  backups and neither can you without the key. This is the out-of-band copy from
  §0. Without it, stop — there is nothing further to try.
- **Read access to their datastore.** Off-site copies are pulled, so you hold no
  credential on them by design. Ask the buddy's operator to grant a read-only
  auth-id (`DatastoreReader`) on the namespace holding your copy, usually
  `remote/<your-site>`.

That asymmetry is deliberate: it is why a compromise of your site could not have
deleted their copy, and it is why recovery needs their cooperation.

### 8.2 Pull it back

Recover *into* a working local PBS — rebuild the node and reinstall the `backup`
module first ([§3](#3-a-node-is-lost), [§6](#6-cluster-and-backup-nothing-to-restore)),
then pull the buddy in as a source and sync in the reverse direction:

```bash
# On the rebuilt system: register the buddy as a pull source.
backup-manager peer add pull buddy        # prompts for the read-only auth-id they issued
backup-manager peers                                    # confirm it and its namespace

# Sync their copy of your data into the local datastore, then verify it.
ssh root@<pbs-node> proxmox-backup-manager sync-job run <job>
ssh root@<pbs-node> proxmox-backup-manager verify <datastore>
```

Then restore guests from the local datastore exactly as in
[§1](#1-a-module-is-misbehaving--roll-it-back) — by this point the data is local
and nothing about the restore is special.

### 8.3 If there is no local PBS to pull into yet

You do not have to rebuild a datastore first. Point the site at the buddy's PBS
as an **external** target and restore straight from it:

```bash
scripts/backup-manage.sh use-external <buddy-pbs-url> --datastore <their-datastore>
```

This registers their PBS as Proxmox storage, so `qmrestore` and
`backup-manager restore` can read it directly. Two cautions: the placement flip
is **sticky** — it is left only deliberately, with `backup-manager placement reset`
once a local datastore exists (§9.1) — and you are now restoring across whatever link separates you — a
full-site restore over a domestic uplink is measured in hours or days, which is
the argument for rebuilding a local datastore first if the hardware exists.

### 8.4 Being the buddy

Symmetrically, if you are the one holding a peer's copy, they need read-only
access to pull it back. That is a **remote** peer, and it is a one-liner:

```bash
backup-manager peer add remote their-site --auth-id theirsite@pbs
#   … recovery happens …
backup-manager peer delete remote their-site --purge   # revoke, and drop the login
```

It grants `DatastoreReader` and nothing else, **non-propagating** by default, so
the grant covers the namespace you name and not its children. Nothing else you
hold is useful to them anyway — the data is encrypted with their key, not
yours.

---

## 9. Relocating the datastore without losing history

**Unrehearsed.** When PBS itself moves — an old node to a new `tankc`, or an
external PBS to a local one — the old snapshots must not be discarded. Seed the
new datastore by **pulling** from the old one rather than starting empty:

```bash
backup-manager peer add pull old-pbs --host <old-pbs>   # register the OLD PBS as a pull source
#   … let the sync job run, then verify the snapshots arrived …
scripts/backup-manage.sh use-external <new-url> # or re-run the install to resolve node (.node = the new Host)
#   … restore something from the NEW target and confirm it works …
backup-manager peer delete pull old-pbs          # only now decommission the old datastore
```

This is plain pull replication (ADR-012 §4.3) — there is no special migration
path and nothing is rewritten. **Decommission only after the pull *and* a test
restore are green**: a copied datastore that has never been restored from is a
hypothesis, not a backup.

This is also why `backup-manage.sh use-external` refuses to run from a live
local PBS: doing it before the history has been pulled across would orphan a
datastore full of backups.

### 9.1 Leaving an external PBS for a local one (`placement reset`, #607)

`external` is sticky — no update ever re-decides it — so leaving it is one deliberate
command. It needs a `tankc` pool on some node (or on `backup.json` `.node`) for the local PBS;
without one it refuses and changes nothing, because a site that trades a working external PBS
for a shim has no backups at all.

```bash
backup-manager placement reset          # asks first; --yes to skip, --peer NAME to name the pull peer
#   … the pull from the old PBS runs on its schedule (04:00 by default) …
backup-manager restore list-all         # the history is under pull/<peer>; restore something from it
backup-manager placement finish-reset   # only now drop the old storage entry
```

What `reset` does, in order:

1. The old PBS's Proxmox storage entry is renamed `<pbsStorageName>_former`, with its login,
   fingerprint, password and encryption key, so everything on the old PBS **stays
   restorable from Proxmox the whole time**. (Leaving it under the module's own name would
   keep the nodes pushing to the old PBS for ever: the local install would find that name
   "already configured".) `backup.json` becomes `placementState: shim`, `pbsUrl` the local
   default, and `formerExternal` records what was left behind.
2. The old PBS is written down as a **pull** peer, `pull-former-<host>.json`.
3. The backup module is updated: the shim becomes `node` (the Host in `.node`) on the `tankc` pool, the local
   PBS is installed, and the nodes push there from the next backup on.
4. The pull peer is onboarded — it asks for a **read** login on the old PBS — and its sync job
   copies the history into `pull/<peer>` on the new datastore.

Nothing on the old PBS is ever touched; retiring it, and its data, is its owner's decision.
`finish-reset` removes only the `_former` storage entry, and only after it asks: run it after
the pull **and** a test restore from `pull/<peer>` are green. If step 3 fails, nothing is backed
up until `update-module.sh backup` succeeds — `reset` says so, and the old history is still in
`_former`.

---

## 10. Verifying, on a normal day

```bash
backup-manager validate                       # the hierarchy is consistent
backup-manager list                           # coverage, per module
backup-manager restore list-all               # what is actually stored
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
mothership that had never been in the backup job at all. The second rehearsal
(hrossen, 2026-09-18) found a fourth: `/etc/secrets` could not be restored by
following this page, because the command for it was not here and the obvious
adaptation of the `config/` one fails partway on file ownership (§5.1).
