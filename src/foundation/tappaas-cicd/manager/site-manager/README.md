# site-manager

The **Site** manager. The Site is the umbrella over a whole TAPPaaS installation:
site-wide identity, its locations, its nodes (each a `pvehost` instance with its storage pools), backup,
update schedule, repositories, and the default environment and owning
organization by name. (Domain / DNS / identity are *per-environment*, owned by
`environment-manager`, not here. The organizations themselves are the files in
`config/identities/organizations/`, owned by `identity-manager`; the site keeps
no list of them.)

## What it owns

`config/site.json` (default `${TAPPAAS_CONFIG:-/home/tappaas/config}/site.json`),
validated against `site-fields.json`. A site from before 2.1 may still list
its repositories in the legacy `config/configuration.json`
(`.tappaas.repositories`); the repository tools and the config migrations read
them there while `site.json` has none.

## `site-manager`

The `site-manager` bin is the front door. It owns the Site as a **singleton**
and the `location` / `node` / `repository` sub-entities, following the same `<entity> <verb>`
shape as `network-manager`. The heavy git/cluster I/O stays in the still-live
bash tools, invoked as thin delegations: `add` → `create-site.sh`,
`repository add`/`delete` → `repository.sh`, `validate` → `validate-site.sh`.
The bin owns config CRUD (`site modify`, `node` CRUD, the `site.json` writes) +
`validate` + `reconcile`.

### Entities and verbs

```
site (singleton)   site show [--json]
                   site modify --set <field>=<value>... [--unset <field>] [--<shortcut> <value>]...
location           location list [--json]
                   location show <name> [--json]
                   location add <name> --country <CC> [--displayName <s>] [--kind site|remote]
                            [--city <c>] [--address <a>] [--timezone <tz>]
                            [--latitude <deg>] [--longitude <deg>] [--primary] [--check]
                   location modify <name> [--set <field>=<value>]... [--<shortcut> <value>]... [--unset <f,g>] [--check]
                   location delete <name> [--check]
node               node list [--json]
                   node add <N> [--adopt <ipv4>] [--boot-disk <d>] [--boot-mirror <d>] [--switch-port <sw>:<p>] [--mac <m>]
                            [--wan-port <if>|--no-wan] [--lan-ports <a,b>]
                            [--lan-mode <m>] [--lan-primary <if>] [--ttl <s>] [--no-reboot]
                            [--config-only [--storage-pools <a,b>]]
                   node storage <node> [--json]
                   node storage add <node> <pool> --disks <d,d> --layout single|mirror|raidz1|raidz2 [--wipe]
                   node usb <node> [--json]
                   node usb write <node> <device> --yes
                   node delete <name> [--apply] [--shutdown|--erase|--lost]
                               [--config-only]
                   node reconcile [--apply]
                   node qdevice add <host> [--user <u>] [--force] | remove | status
                   node network show <node> [--json]
                   node network set <node> [--lan-ports <a,b>] [--lan-mode <m>]
                            [--lan-primary <if>] [--mtu <n>] [--no-wan] [--switch-wait <s>]
                            [--config-only] [--apply] [--yes]
                   node network test <node> [--apply] [--yes]
repository         repository list [--json]
                   repository add <url> [--branch <b>] [--managed full|tracked] [--catalog <p>]
                            [--signer SHA256:<fp>]... [--unsigned]
                   repository introduce <name> [--signer SHA256:<fp>]...
                   repository delete <name> [--force]
                   repository reconcile [--apply]
                   repository sync <name> [--dry-run]                (#814)
                   repository hold <name> --reason <text> [--until <30m|12h|7d|date>]
                   repository release <name>
                   repository validate-catalog [<name>] [--strict]   (#463)
                   repository stash list [<name>]                    (#681)
                   repository stash show|restore|discard <name> <sha> [--force]
top-level          add --name <site-code> [--organization <org>] [create-site options]  (= create-site.sh)
                   validate [FILE] [--schema-dir PATH]     (= validate-site.sh)
                   (validate also checks updateSchedule and prints the OnCalendar it renders)
                   reconcile [--apply] [--deep]
                   update [--dry-run] [--force] [--no-git-pull]   (starts update-tappaas.service)
                   update --stop                                  (the running update stops after the module in progress)
                   test [--deep] [--verbose]                      (= module-manager test each; one line per module, output in ~/logs/site-test-<time>/)
```

`update` runs the whole-site update **now** by starting `update-tappaas.service`
— the unit the timer starts, so the operator exercises the scheduled path
(ADR-017 D4). It follows the run's journal; Ctrl-C only detaches. The options
travel in a one-shot request, `config/.update-request.json`, which the unit
claims. `--dry-run` starts nothing: it reports each repository against its
origin, then the sweep's plan. `--force` updates every module even when its
pre-update test failed fatally, and nothing more — it reboots nothing.
`--allow-disruption` opens the downtime window for that run: a module with
`rebootOk: true` may be rebooted or migrated offline, every other module keeps
its disruptive changes deferred, and `rebootOk: false` is never overridden
fleet-wide. For one module that is
`module-manager module update <module> --allow-disruption` (ADR-020 v0.10 D8, #633). `--no-git-pull` (`TAPPAAS_NO_GIT_PULL`) updates
whatever is checked out — refresh-control-plane.sh skips the per-repo pull — so local,
not-yet-pushed changes can be tested. `--dry-run` previews the plan.

`update --stop` ends a running update gracefully: the module in progress
finishes, every later module and the phases after them (suspended modules, node
reboots, collation) are skipped, and the run is recorded as `interrupted` with
who asked and what was not attempted. The next update takes the rest. The
request is `config/.update-stop`, naming the run's InvocationID; the sweep reads
it between modules, so a stop asked during a long step (a rebuild, a big module)
takes effect when that step ends, and one left behind never stops a later run.
To stop at once instead, `sudo systemctl stop update-tappaas.service` — the
module in progress is then cut off, not rolled back: run
`module-manager reconcile <module> --apply` on it afterwards.

`test` runs every deployed module's tests: it iterates
`module-manager list` (foundation + apps, from every registered repository) and
runs `module-manager test <m>`, forwarding `--deep`. Continue-on-failure; exits
non-zero if any module test failed.

Common options: `--config-dir DIR`, `--json` (machine output for list/show),
`--apply` (reconcile commits; default is preview), `--deep` (reconcile cascade),
`--force` (repository delete → `repository.sh remove --force`).

When a run fails, the site owner hears about it: `update-tappaas-failure.service` mails
`site.json` `email` through a Proxmox node's mail system, naming the step that failed
(#651; ADR-007e v1.3 owns the target), with a support bundle of the run attached to forward
to `site.json` `supportEmail`. The next clean run says so: "RESOLVED: update sweep OK
again", as a reply to the failure. Every run is also followed by a security scan of
what it left running (`health-manager report security`, ADR-011). `site show` prints the schedule as it is meant —
no weekday under `daily`/`none` (#447) — and the TAPPaaS version the site runs, read from its
checkout (`2.2`, or `2.2+14` between boundaries; ADR-028 D13), beside the one it was installed from.

`repository hold` stops the scheduled sweep from pulling one repository, so a test
site can run changes that are not pushed yet (#653). The marker is
`config/.repo-hold/<repo>.json`; every hold expires (default 24h), and an
expired hold is removed by the next sweep, which then pulls again.
`repository list` and `update` show active holds.

`repository sync <name>` brings one repository to the tip of its declared branch
without the sweep (#814). It keeps the sweep's guards (the hold, the auto-stash,
no commits that exist only in the checkout) and decides on the fetched tip before
anything moves. It **refuses**, and proposes `site-manager update`, when the tip
carries a config migration the ledger does not hold or changes the mothership's
own NixOS configuration: both need steps only the sweep runs. It names every
installed module whose source directory changes, and deploys none of them; a
change under `tappaas-cicd/lib/` is said to reach every module. When the
repository is the one the control plane is linked from, `refresh-control-plane.sh`
runs afterwards without a pull. `repository reconcile` now says how far behind
origin each checkout is, rather than calling a stale checkout "Converged".

`repository stash` is where the local changes a sync had to set aside go to be
found (#681). A dirty managed checkout is stashed so the pull can move and the
entry is put back afterwards; one that no longer applies is kept, and used to be
reported only as a number — `git stash list`, run by hand in a checkout the
operator is told not to edit, was the only way to see what the number meant. One
estate carried 12 such entries. `stash list` names every entry with its
repository, its age and the files it holds; `stash show` prints its diff;
`stash restore` puts it back when it still applies; `stash discard --force`
drops it. Entries an operator stashed by hand carry no repo-sync tag: they are
never listed, restored or dropped.

`repository validate-catalog` checks that a repository's module catalogue says true
things (#463): its shape and fields, a `moduleJson` that exists, `stack` and `vmid`
agreeing with the module's own file, one name and one VMID per module, and no module in
the tree left unlisted. With no argument it checks every `managed: full` repository. It
reports and exits 0 — every catalogue predates the check, and a stale one is no reason to
refuse a repository; `--strict` exits non-zero and is what CI and a contributor run before
opening a pull request. `repository add` runs it too, as a report.

**First trust for a clone (ADR-033 D5).** A release tag is verified against the signers of
the release the site last verified — but a fresh clone has verified nothing yet. On a
staging or production branch `repository add` therefore takes the fingerprints of the
keys the repository's owners sign with — `--signer SHA256:<fp>`, once per key, as
`ssh-keygen -l` prints it, from the owners, out of band. The branch's current release must
be signed by one of them (and listed by its own `allowed_signers`, with a matching tree
hash); no release number is given. They are written as the entry's `trust.signers`, and
the release verified goes to `config/.trust/<name>.json`, where every later update starts.
Without them the add is refused, unless `--unsigned` is given: for a repository that signs
nothing, or one taken on trust from the revision cloned now. On an unstable branch none
are needed; given ones must be keys the checkout lists. `repository introduce <name>` runs
the same check on an existing checkout — against its `trust.signers`, or against
`--signer` values, written to `site.json` once they hold, to confirm a repository's
signers or start from new ones; `repository reconcile --apply` runs it after cloning a
missing repository, and removes the clone again if it fails. The TAPPaaS repository's
fingerprints are written by the installer, from the ones published in the root
`INSTALL.md`.

`site modify --set <field>=<value>` sets a field by its name in `site-fields.json`, dotted
inside an object (`--set supportEmail=help@example.org`, `--set backup.target=pbs2`,
`--set updateSchedule.hour=3`); it repeats, and `--unset <field>` removes an optional one. The
options below are **shortcuts**, one field each (ADR-020 D11): `--email a@b.org` is
`--set email=a@b.org`, and both run the same checks. `supportEmail` — where an alert's support
bundle is to be forwarded — is one e-mail address (the schema refuses anything else), empty
by default and set as a day-two step. The shortcuts (scalar, site-wide): `--channel`,
`--displayName`, `--owner`, `--email`, `--supportEmail` (`''` clears it), `--automaticReboot`, `--snapshotRetention`, `--backupTarget`,
`--backupOffsite`, `--primaryLocation`, `--locale`, `--keyboard`, `--networkIsp`, `--networkPublicIp`, `--ipv6`, `--requireSigned`, `--dnssec`,
`--brandingLogo`, `--brandingLogoDark`, `--dnsBlocklistsLists|Zones|Allow` (comma lists, `''`
empties one), `--diskAutoGrowEnabled|Threshold|GrowPercent|MinGrowGB|PoolCeiling`, and the
update schedule. That is every field `site-fields.json` classes `in-place`. `name`, `version`
and `defaultEnvironment` are `immutable`: `--name`, `--version` and `--defaultEnvironment` are
refused, with the reason the schema gives, and nothing is written. The `locations` (use
`location …`) and the `repositories` list (own CRUD) are `manual`: **not** modifiable here. The
nodes are not a site field: they are their `pvehost` instances (use `node …`). The older `--locationCountry`,
`--locationTimezone`, `--locationCity`, `--locationBuilding`, `--locationLatitude` and
`--locationLongitude` are still accepted for one release and change the primary location;
`--locationLocale` and `--locationKeyboard` change `--locale` and `--keyboard`.

### `channel` — which release the site takes (ADR-028 D9, D11)

A **channel is a promise about risk**; the **branch is where the code sits**. They are separate
fields because they are separate statements, and an operator changing one before the other is a
normal moment, not an error.

| Channel | Branch (TAPPaaS repo) | What it means |
|---|---|---|
| `unstable` | `main` | development is proven here; the test site |
| `staging` | `staging` | soaks a revision under real use for one boundary |
| `production` | `stable` | what everyone else runs — the default for a new site |

```bash
site-manager site modify --channel staging          # the promise
site-manager repository modify TAPPaaS --branch staging   # the code
```

Either order works. Whichever you do first, the other command **warns** that the two disagree
and names the command that would settle it. It does not refuse: refusing would make the
two-step move impossible.

**Two moves need `--force`, because both take the site backwards:**

- **Towards production** (`unstable → staging → production`) moves to *older* code. Config
  migrations are forward-only (ADR-025), so a migration this site has already applied cannot be
  undone by changing channel — the older code simply reads a config shape it does not know.

**It checks every repository, not just TAPPaaS (ADR-028 D11).** Which branch realizes which channel
is declared by each repository in `channels.json` at its root, so setting a channel compares each
registered repository's branch against what that repository says, warns where they disagree — or
where no `channels.json` exists, in which case every branch in it reads as unstable — and prints the
`site-manager repository modify <name> --branch <b>` that would settle each. It never switches a
branch itself: that is a code change to a live site.
  `site modify --channel` refuses without `--force` and says why.
- **Onto a branch behind this site's migrations.** `repository modify --branch` reads the
  target branch's `migrations/` directly from the forge — no checkout needed — and compares its
  newest migration with the newest this site has applied (`config/.migrations/applied`). If the
  branch is behind, it refuses without `--force`. This is the same fact as above, caught from
  the branch side, and it also catches a hand-typed branch that belongs to no channel at all.

Both gates are passable on purpose. A release tool that cannot be overridden gets worked around
with a text editor, which is worse than an override that announces itself — and each one prints
what it is doing when `--force` lifts it.

Only the **TAPPaaS** repository is held to the train's branches: a community repository has no
`staging` or `stable` to track, so its branch is whatever its publisher uses.

### `location` — the site's places

A **location** is a place with an address: the site's own building, a provider's data
centre that runs one of its machines, a backup buddy's site. `site.json` keeps them in
`locations`, by name, each with a `country` (required), and optionally a `displayName`,
`city`, `address` (the street address, or the provider and data centre), `timezone`,
`latitude` and `longitude`. `kind` says whose place it is: `site` (the default) for this
site's own equipment, `remote` for another site's.

```bash
site-manager location list
site-manager location add hetzner-fsn1 --country DE --city Falkenstein --address "Hetzner FSN1-DC14"
site-manager location modify rodovre --timezone Europe/Copenhagen
site-manager location show hareskov          # its place, and what names it
```

The **primary location** (`primaryLocation`) is where the site is. Its timezone is the
site's: every node and guest is set to it at the next update, and the health check
compares them with it. It is also what `backup-manager validate` compares an off-site copy
with. The site's first own location becomes primary; `location add --primary` or
`site modify --primaryLocation <name>` moves it, to a location that records a timezone.

Anything else that is somewhere names a location — a backup peer today — and reads the
address from here. A location's name is how they name it, so it never changes: add the new
one, point them at it, delete the old one. `location delete` refuses the primary location
and any location something names, and says what does. `--check` on `add`, `modify` and
`delete` (and on `site modify`) says in one line what would change and writes nothing —
`[check] would modify location 'hareskov': displayName=Rasmus; site.json otherwise
unchanged` — or `[refused] <why>` with exit 1; `--check --json` prints the whole resulting
site.json. The apply reports the same line, done ("modified location 'hareskov': …"). `validate` reports a `primaryLocation`
that names no location or has no timezone, and anything naming a location the site does
not have.

#### Time and locale are the site's master data

Country, keyboard and timezone are answered by the operator **once**, on the first
Proxmox install, and that node is the only place the answers exist. `site add` reads
them back from it — `timedatectl`, `XKBLAYOUT`, `LANG` — rather than from the
mothership, which is a NixOS template whose clock says nothing about where the site is.
The country is the exception: the installer asks for it and stores it nowhere, so it
stays derived from the timezone. Country and timezone go to the primary location, which
`site add` names after the site code; `locale` and `keyboard` are site-wide fields, not
part of any location.

What is recorded here is what the rest of the estate is set from: the PXE answer file
(`node add`), the USB installer's defaults (`make-install-media.sh`), and the
per-OS convergence of guests and hosts. A value already in `site.json` is the operator's
and is never overwritten — a `site add --force` re-run fills in what is *missing* and
warns when the recorded value and the master disagree, naming the command that would
adopt the master.

`latitude` / `longitude` are operator-set: no node knows where it is. They exist for
modules that need a position rather than a country.

### The nodes are their `pvehost` instances

The cluster's nodes are not listed in `site.json`: each is a `pvehost` module instance,
`config/<node>.json`, with its `address`, `uplinks`, `location` and `storagePools` (the
tankXY zpools it carries). `node list` lists them (`--json`: name, address, storagePools,
location), in node order — by name, numbers as numbers; the first is the primary node.
`node add` registers one, `node delete` archives it, `node reconcile` registers a cluster
member that has no instance yet and fills a record's empty pools from the node. Every
manager and the bash layer list the nodes the same way (`lib/ts/src/nodes.ts`,
`lib/cluster-nodes.sh`), and `validate` refuses a `site.json` that still carries
`hardware`.

### `node add` — standing up a follow-on node (design N3/N4)

`node add <tappaasN>` is the operator front door for growing the cluster;
hardware-validated end-to-end on 2026-07-07. It stands the node up and nothing
more: Proxmox on a ZFS boot pool, the join, the cluster baseline, a reboot into the
kernel the baseline installed, and HA maintenance lifted. Its guests go to the boot
pool (`local-zfs`) until `node storage add` gives it a data pool (below). Three modes:

- **default (install)** — bare machine: registers the node's install answer with
  `node-provisioner`, opens the TTL-limited boot window, waits for the unattended
  install, then continues with the join pipeline. The machine boots the installer
  from the network (PXE) or from the USB stick image
  (`/var/lib/tappaas-pxe/tappaas-usb.iso`, the same for every node); either way it
  fetches its answer over HTTP from the mothership. The only console interaction is
  the boot-disk question on a network boot, and only when the boot-disk fields match
  nothing or with `--boot-disk ask`; a stick stops with the machine's disk list
  instead. Requires the netboot assets staged once per PVE version — done
  automatically by the cicd install (`prepare-netboot.sh`), and again by node add
  when they are stale. (`--install` and `--pxe` are former names of this mode.)
- **`--adopt <ipv4>`** — a Proxmox installed by hand, reached as root over ssh at
  `<ipv4>` with the cicd key authorized: verifies the hostname + `pveversion`, then
  runs the join pipeline, which moves the node to its mgmt IP (`tappaasN` →
  `10.0.0.<9+N>`). A node that is already clustered, at its mgmt IP, skips straight
  to capture. The install options do not apply. The console offers no adopt.
- **`--config-only`** — just write the node's `pvehost` record, `config/<N>.json`,
  with `--storage-pools` (no machine contact).

The join pipeline (shared by install and `--adopt`): asks for the WAN NIC and the
lan ports with the node's REAL ports listed (skip the questions with
`--wan-port <if>`/`--no-wan`),
serves the repo from the mothership on :8090 (committed branch state — no
GitHub dependency), runs the node step (`install.sh --join`), corrects
`/etc/hosts`, seeds node→tappaas1 ssh trust, `pvecm add`, and registers the
node as its `pvehost` instance (`module adopt`) with the tankXY zpools already on it
and its boot disks by serial (`bootDisks`), before it registers the node on those
pools' cluster storage entries and its boot pool as `local-zfs`. Every wait is
time-boxed and the boot window is closed on every exit path. Fully unattended example:

```
site-manager node add tappaas2 --switch-port "USW Pro XG 10 PoE:1" --no-wan
site-manager node add tappaas2 --mac aa:bb:cc:dd:ee:ff --no-wan
```

**Where it is cabled comes first.** `--switch-port <switch>:<port>` names the port on a
switch TAPPaaS programs: node add makes it a node trunk on the switch, then watches it
while the machine boots the installer (`switch-manager port-neighbors`) and pins the registration
to the one MAC that appears there and is no cluster node's. On a switch TAPPaaS does not
program, node add prints the port to configure — a trunk, the mgmt network untagged,
every active zone's VLAN tagged — and takes `--mac`. With neither a switch port nor a
MAC, the first machine that asks for an install answer while the window is open gets it;
keep `--ttl` short then. A registration that names no MAC never answers a machine that is
a cluster node. `--mac` takes a MAC only.

**Boot disks: two fields, blank is the default.** `--boot-disk` and `--boot-mirror`
each take a size (`2TB`, `1.92T`, `500GB`: within 10 %), a model (`"Samsung 990"`) or
a serial; the installer matches them against the machine's disks in its own boot, so
no Linux disk name is needed. Blank, the boot disk is the smallest SSD or NVMe disk
not on USB, and when the smallest two are the same model and size both are taken and
the boot pool is mirrored; `--boot-mirror none` keeps such a pair to one disk. A field
that matches nothing, or more disks than it may, makes the node's console ask. A
kernel name (`nvme0n1`) is accepted with a warning: it is the name the installer's
boot gives the disk, which NVMe drives do not keep between boots (#729 §3).

### `node storage` — a node's data pools (ADR-037 D4)

`node storage <node>` lists the node's pools and its disks in no pool — serial, size,
type, model, an old pool's label and SMART health (from `storage-manager inventory`) —
and proposes a pool on the healthy ones. `node storage add <node> <pool> --disks
<serial,...> --layout <l>` builds it on the node (`cluster/config-storage.sh`, fed from
this checkout), registers it as the node's storage and records it in `storagePools`.
It asks nothing: a pool name that is not `tank<…>` or that the node has, a disk count
the layout does not take, a kernel name, the boot disk, a disk in a live pool, or a disk
that carries data without `--wipe` is a refusal that says why, and nothing is changed.

```
site-manager node storage tappaas2
site-manager node storage add tappaas2 tanka1 --disks S7HENJ0X100001,S7HENJ0X100002 --layout mirror
```
### `node usb` — the installer stick

A machine that cannot network-boot is installed from a USB stick that carries the
installer stick image, `/var/lib/tappaas-pxe/tappaas-usb.iso` (staged on the mothership
by `scripts/prepare-netboot.sh`, the same image for every node). `node usb <node>` lists
the sticks plugged into a cluster node — the whole disks on the USB bus, as `lsblk`
reports them; never a SATA/NVMe disk — one line each: device, size, vendor, model and
serial, with `(in use: mounted)` (or `zfs_member`, `LVM2_member`, `swap`,
`linux_raid_member`) when something holds it, and `(key stick)` when a partition is
labelled `TAPPAASKEYS` (the backup key stick). `--json` is what the console reads:

```json
{ "node": "tappaas1", "reachable": true,
  "sticks": [ { "device": "/dev/sdb", "size": 30752000000, "vendor": "SanDisk", "model": "Ultra",
                "serial": "4C530001", "inUse": false, "why": null, "keyStick": false } ] }
```
`why` is `null`, `"mounted"` or the file system type that claims the stick. A node that
cannot be reached is an error in the human form; with `--json` it is
`{"node": …, "reachable": false, "sticks": []}` and exit 0, so the console can say so.

`node usb write <node> <device> --yes` streams the image over ssh onto the stick
(`dd`, then flush and eject) and **erases it**. It asks nothing and refuses, writing
nothing, without `--yes`, when the image is not staged, when the node cannot be reached,
when `<device>` is not a stick `node usb <node>` lists, or when the stick is in use.

```
site-manager node usb tappaas1
site-manager node usb write tappaas1 /dev/sdb --yes
```

After the install node add puts the installed disk first in the UEFI boot
order, and if the answer's ssh key did not survive the first boot it restores it
with the node's generated root password (`/home/tappaas/.node-secrets/<name>.pw`,
the operator's, 0600).

Afterwards run `site-manager update` to fold HA + replication.

### `reconcile` and the `--deep` cascade

`reconcile` is **shallow by default** — it converges the site's own concern:
validate `site.json`, then bring each `repositories[]` entry to a live clone
(clone if missing, checkout if the branch drifts). Default output is a
**preview**; `--apply` commits. `repository reconcile` is the repo-scoped
subset of the same engine.

`reconcile --deep` then cascades to the dependent managers in dependency order:

```
site reconcile --deep
  → identity-manager  reconcile          (people → Authentik)
  → network-manager reconcile          (the 4 network planes — ONE system-wide pass)
  → for each environment in config/environments/*.json:
       environment-manager reconcile <env> --deep --skip-network
```

people/network are single bins; environments fan out — one deep reconcile per
registered environment. The **network pass runs once for the whole site**:
`network-manager reconcile` has no zone or environment filter, so letting each
environment run its own would repeat the identical whole-platform operation once
per environment. Every leg is idempotent, so re-running is safe; this is
the natural whole-platform converge after `update-tappaas`.

A cascade that exits non-zero is reported by name and makes `site reconcile`
exit 1 — the remaining legs still run, so one bad environment does not strand
the rest.

### Build

Built by `default.nix` into `result/bin/site-manager` — mirroring
`identity-manager` / `network-manager`. `install.sh` is **not** yet wired to build
it (the bash tools below remain the installed entry points for now).

## Commands (legacy bash tools — kept live until cutover)

All scripts are bash, linked onto `PATH` by `install.sh`. `repository.sh` and
`validate-site.sh` remain live and are the tools the `repository add`/`delete`
and `validate` verbs delegate to; `create-site.sh` backs the `add` verb.

### `repository.sh` — manage module repositories

The tool behind `site-manager repository …`: it registers the module
repositories TAPPaaS pulls modules from (add / remove / modify / list) in
`site.json` `repositories[]`, cloning each under `/home/tappaas/<name>/` over
HTTPS. A repository is always cloned by `add`, never adopted from an existing
checkout elsewhere. A private repository is reached with a deploy key — see
[Private repositories](../../DESIGN-GIT.md#adding-a-private-repository).

```
repository.sh add <url> [--branch <b>] [--managed full|tracked] [--catalog <path>]
repository.sh remove <name> [--force]
repository.sh modify <name> [--url <new>] [--branch <new>]
repository.sh list
```

### `validate-site.sh` — validate site.json

This is the manager's `validate` operation, named `validate-site.sh` per the
script-manager `validate-<manager>.sh` convention; runnable directly.

```
validate-site.sh [FILE] [--schema-dir PATH] [--quiet]
```

- `FILE` — site.json to validate (default `$TAPPAAS_CONFIG/site.json`).
- `--schema-dir PATH` — directory holding `site-fields.json`.
- `--quiet` — errors/warnings only.

```bash
validate-site.sh
```

## Legacy tools (kept until the flag-day cutover)

These predate `site.json` and operate on the legacy `configuration.json`:

### `create-configuration.sh`

Create/update `configuration.json` by discovering the running Proxmox cluster.
Accepts named flags (`--upstream-git`, `--branch`, `--domain`, `--email`,
`--schedule monthly|weekly|daily|none`, `--weekday`, `--hour`, `--primary-node`,
`--update`) or legacy positionals
(`<upstreamGit> <branch> <domain> <email> <schedule> [weekday] [hour]`). Idempotent.

### `validate-configuration.sh`

Validate `configuration.json`. Flags: `--config <path>`, `--check-connectivity`
(ping nodes), `--check-cluster` (SSH the first node, compare cluster membership),
`--check-repos` (git ls-remote each repo URL), `--quiet`.

### `convert-json-to-config.sh`

Convert a flat module JSON into the canonical config-block form. CLI:
`convert-json-to-config.sh [--in-place|--dry-run] <module-json>`; or source it and
call `regroup_to_pattern_a`.
