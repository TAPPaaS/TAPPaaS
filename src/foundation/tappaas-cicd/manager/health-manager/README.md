# health-manager

Cluster / VM / disk / OS **health and maintenance** for TAPPaaS. health-manager
is a **read-only** manager: it surfaces the live cluster against the deployed
module config; it never authors a config domain of its own and never reconciles.
Because of that, the CRUD verbs (`add`/`modify`/`delete`/`reconcile`) are **N/A**
here, and `validate` carries a special meaning (see below).

This is the port (ADR-007 §Health). The
remaining bash scripts (`check-disk-threshold.sh` — a manual front end to
`cluster:vm`'s automatic disk growth — and `update-os.sh`) remain in
place and working; the manager re-implements the unambiguous read verbs on top
of a thin `ssh`/`pvesh`/`qm` shell-out boundary (no Proxmox logic is
re-implemented). health-manager is a **read-mostly orchestrator** under the
F12 runtime-state rule (see the "Runtime-state access rule" section in
`tappaas-cicd/README.md`): its cluster reads go through the shared
`lib/ts/src/cluster.ts` choke-point; its two write paths (`update-os` and
`reboot`) are documented delegations to `update-os.sh` and `reboot-guest.sh`,
pending the `update-os.sh` port.

## Verb surface

```
health-manager validate [--threshold PCT] [--memory-threshold PCT] [--json] [--config-dir DIR]
health-manager capacity [--install <instance>] [--memory-threshold PCT] [--json] [--config-dir DIR]
health-manager update-os <name> <vmid> <node>
health-manager reboot <module>
health-manager emit [--since <time>] [--json]
health-manager ack <ci> [--type <t>] --note <n> [--until <time>] [--sticky]
health-manager unack <ci> [--type <t>]
health-manager maintenance <ci> --until <time> --note <n>
health-manager maintenance end|cancel <ci>
health-manager show <ci> [--json]
health-manager list [--type <t>] [--status <s>] [--class <c>] [--root-causes] [--json]
health-manager roots [--json]
health-manager history <ci> [--since <time>] [--json]
health-manager scan security [--if-new-sweep | --rescan] [--notify]
health-manager report security [--cves] [--scan [--all]] [--json]
health-manager scan nix-list --components <file> [--nixpkgs <path>] [--no-db-update] [--no-vex]
health-manager scan images --refs <file> [--no-db-update] [--no-vex]
health-manager score [--details <file>] [--items <file>] [--json]
```

`scan nix-list` matches a JSON list of `{name, version}` against the CVE database as if those
packages ran — same CPE rule, matcher and VEX statements as `scan security`, writing nothing;
what a statement decides comes back as `suppressed` (`--no-vex` applies none). `scan images`
does the same for container images by registry reference. The release train's
`tappaas-train preview` uses it for the packages the next nixpkgs pin would bring (#788);
`--nixpkgs` points the CPE vendors at that pin. Prints `{"findings": [...], "error": ""}`.

`score` is the one CVE risk score (ADR-045 D3), computed in `lib/ts/src/score.ts` and nowhere
else. `--details` scores a release preview's details per module (no zone multiplier) and
gives the release's level (its highest module); the preview calls it. `--items` takes
`{modules: {<m>: [{id, state, severity, rating}]}, placement, zones}` and scores modules,
zones (× the tier multiplier), environments and the site. `--json` adds the weights, bands
and multipliers used.

> **MOVED (ADR-007):** the per-VM three-way drift inspect is no longer a
> health-manager verb. It is now `module-manager reconcile <m>` (the read-only
> report for one module) and `module-manager list --diff` (the rollup), native
> in `module-manager/src/inspect.ts` — the port of the retired `inspect-vm.sh`.
> The three sections below describe that behaviour and are kept here until the
> prose is relocated to module-manager's README.

### `list vm` — cluster overview (moved; was the port of the retired inspect-cluster.sh)

Read-only. Lists every running guest (VM/CT) across the Proxmox cluster (VMID,
name, node, type, status) and classifies each against the module configs in
`config/`: `managed` (in config), `[external]` (unmanaged guest), or
`NOT IN CONFIG`. It also lists configured modules whose VM is **not** running,
distinguishing genuinely-missing from `[archived]` and `[external]`-down.
This is a **report** — it does not exit non-zero on a discrepancy (that is what
`validate` is for).

### `list vm --diff` — per-VM three-way rollup (moved; now `module-manager list --diff`)

Runs the `show vm` three-way comparison (**orig/config/running**) for **every
managed module** and rolls up the drift, printing only the fields that differ per
VM plus cluster-wide warn/error totals. A VM that cannot be queried (node down,
not yet provisioned) is reported as *unreachable* rather than aborting the whole
rollup. Bare `list vm` stays the running-vs-config basics; `--diff` is the
drift view.

### `show vm <name>` — three-way diff for one module (moved; now `module-manager reconcile <m>`)

Prints a 3-column table for a module's VM: **Released** (the git source JSON via
the module's `moduleSource`), **Desired** (`config/<module>.json`), and **Actual**
(the running VM, via Proxmox). Yellow = config-vs-git drift; red = actual-vs-config
drift. This pass covers the scalar fields (identity, cores, memory, disk,
storage, BIOS, CPU type, tags). NIC drift rows are a deferred follow-up (below).

### `validate [--live]` — assert the live system is healthy (special)

Unlike the config managers (where `validate` = "config is well-formed"),
**health `validate` asserts the *live* system is healthy**. These are its gates;
`assess` runs them, and `validate` reads the result, exiting non-zero on a
critical condition that counts (see [Assess](#assess)):

| Gate | Source | FAIL when |
|------|--------|-----------|
| `service-liveness` | `pvesh /cluster/resources` | a managed config module's VM is not `running` |
| `disk-threshold` | `df /` per guest: over SSH, or through `pct exec` on its node for an LXC module | a reachable guest's `/` usage ≥ threshold (default **80%**, `--threshold PCT`) |
| `memory-commitment` | one `pvesh /cluster/resources` | a node's COMMITTED memory ≥ threshold of its physical RAM (default **100%**, `--memory-threshold PCT`) |
| `storage-pools` | `pvesh /cluster/resources` + one `zfs list` per node | a guest-disk pool **≥ 90%** used (**WARN** at 80%, the ceiling automatic disk growth stops at), or **WARN** when a pool's disks add up to more than it holds (thin disks); `storage-manager inventory` shows what each pool holds, guest by guest |
| `storage-replication` | `storage-manager inventory --json --no-smart` | never — **WARN** when a replication job (an HA guest's copy on its other node) is in error or behind its schedule, each row on its module. A disk is judged from its CI and a pool from its `zfsState` by `assess` (below), so the inventory is read without SMART |
| `cpu-impact` | `config/cluster-cpu.json` + one SSH probe per HA guest | never — **WARN** when an HA guest's processes use AVX-512 that its shared CPU level (`haCpu: common`) drops (see below) |
| `guest-memory` | `pvesh` + one SSH per node (`ps`, `qm status`, the balloon statistics by `qom-get`) | a module **using ≥ 90%** of its declared memory (**WARN** at 75%), or one whose allocated memory exceeds its declared limit. Used is total minus available, so page cache does not count; a VM that reports no available figure keeps Proxmox's and its row says `cache counts as used` |
| `backup-status` | `backup-manager list --json` | a module is backup-disabled, or enabled but not in the PBS job |
| `backup-keys` | `backup-manager key status --json` | never — **WARN** when the backup encryption keys changed after the last USB key stick was written, or no stick has been written; it stays until `backup-manager key export --usb` writes one |
| `pending-reboot` | one probe per guest (SSH, or `pct exec` for an LXC module) | never — **WARN** when a guest is waiting for a reboot (see below) |
| `site-timezone` | `site.json` + one SSH probe per node and guest | never — **WARN** when a node or guest runs another timezone than the site's, which is its primary location's (the next update of the guest, or the next cluster update for a node, sets it), or when the site has none |
| `pulse` | the backup node's pulse (a cluster node, or a `debianhost` machine by its address) | never — **WARN** when the pulse is not running on the backup node, or reports something down (a backup buddy, the uplink, the firewall, the mothership, the PBS); `backup-manager pulse` shows it |
| `open-alerts` | Grafana's alertmanager on the logging VM | never — **WARN** for each state alert firing now (a host silent, a replication failing…), placed on the module, machine or node it is about; `health-manager alerts` lists them with the recent events |
| `quorum` | `pvecm status` | never — **WARN** when the cluster has two votes and no QDevice: one node down and the other is fenced (see the cluster README, *Two-node clusters*) |
| `switch-ports` | `switch-manager list-ports --json` | never — **WARN** when a switch port has no record and is not parked (an access port in iotLocal), or the switch sets a port otherwise than its record — parked or in use (read from the switch as last interrogated — after every sweep by `tappaas-switch-read`, #860; `switch-manager reconcile` reads it again and previews the change); also **WARN** when a switch was last read more than 26 h ago, or never |
| `mlag-pairs` | `config/switch-configuration-actual.json` (switch-manager's MLAG pairs and the switches' last read) | never — **WARN** when a LAG across an MLAG pair has no member on one of its switches, or a switch has another mlag-id on a member than its record (`switch-manager mlag-pair list` reads the pairs live) |
| `ipv6-egress` | `ipv6-manager wan --json` (SSH to the firewall), then an HTTP HEAD over IPv6 from the cicd VM when it holds a global address, else a ping from a guest in a Service zone with IPv6 | never — **WARN** when the site runs IPv6 (`site.json` `ipv6`) and the firewall has no IPv6 default route, its router does not answer on the WAN, the router OPNsense records or the `WAN_DHCP6` gateway names another one, rtsold is not running, there is no delegated prefix, or no public IPv6 address answers from inside the site; **SKIP** when IPv6 is off (see below) |
| `lan-uplink` | the cluster module's `lan-uplink.sh show --json`, one SSH probe per node | never — **WARN** when a node with HA's watchdog armed has its `lan` on one port, a bonded leg is down, active-backup runs on its backup, LACP has no partner or a leg outside the aggregator, both legs reach the same switch (LLDP), MTUs differ, or the live layout differs from the declaration (see the cluster README, *Redundant LAN uplink*) |
| `cve-status` | `config/sbom/cve-status.json` (the last `scan security`) | never — **WARN** on a failed scan, a fixable Critical/High CVE, or a scan older than 8 days (see below) |
| `signature-status` | `config/sbom/signatures.json` (written by `check-repo-signatures.sh` after every repository sync, ADR-033) | **FAIL** when a staging/production checkout runs something that is not a verified release, or a repository signs nothing and `site.json` sets `requireSigned`; **WARN** when it signs nothing, runs past its last verified release or has uncommitted changes, a signing key expires within 60 days, or the check is older than 3 days |
| `cmdb` | the last discovery sweep's record (`cmdb sweep --last`, ADR-040 D15) | **FAIL** when the sweep found desired without actual or a source failed, or when there is no sweep in 48 hours; **WARN** on drift, unmanaged things or a difference from desired, and when the CMDB does not answer |
| `control-plane-trust` | `config/control-plane.json` (written by refresh and by module-manager, ADR-035) | never — **WARN** for each controller a module brought from a repository whose release is not verified that plugs into a foundation manager (`switch-manager`, `ap-manager`, …); the install said so too |

A gate with nothing to check (e.g. no reachable guests, backup tooling absent)
reports **SKIP**, not FAIL. `--threshold` applies cluster-wide. The disk gate is
### `guest-memory` — three numbers, because two mislead

Per module it reports **declared → allocated → used**:

- `declared − allocated` is memory the guest has **never touched**. QEMU backs a
  page on first write, so this costs nothing and there is nothing to reclaim.
- `allocated − used` is memory the guest **touched and then freed**, or keeps as
  page cache. The host still holds it. This — and only this — is what a balloon
  driver could give back.

Measured on a live estate: 60G declared, 31.9G allocated, ~20G used. A report
with only declared-and-used would have said "reclaim 40G"; the third column says
most of it was never taken.

It prints **one row per module, largest gap first**, and totals each column at
the end. The row status answers a different question from the gap: **is this
module short of memory?** — `used` against its own declaration, WARN at 75% and
FAIL at 90%. Over-declaring is waste and never fails; running out is a fault and
does. The first live run found `litellm` at 93% of 4G, which no amount of
looking at the reclaimable column would have surfaced.

**Used excludes page cache.** Proxmox computes a running VM's `mem` as the
balloon's total minus free, and free is Linux's MemFree, near zero on any busy
guest: a Nix builder with 1G in use and 14.6G of page cache read 93% of 16G. The
balloon's own statistics carry the right figure, `stat-available-memory`, but
Proxmox does not expose it, so the gate reads it on the node
(`qom-get /machine/peripheral/balloon0 guest-stats`, batched with the rest of the
node's probe) and sets used to total minus available. The row shows
`cache 12.7G`: that memory is in the gap, not in `used`, because the guest gives
it up as soon as anything asks. A guest with a balloon driver but no available
figure (Windows) keeps Proxmox's number and the row says `cache counts as used`,
so a high figure there is not yet a shortage. A container's `mem` leaves out file
cache already.

**Unmeasured guests are named, never numbered.** The signal is whether the
balloon statistics carry `free_mem`, *not* whether a guest agent answers: the
FreeBSD agent on an OPNsense firewall answers `ping` and `get-osinfo` while
providing no memory statistics, and Proxmox then reports the host's own view as
the guest's usage. That firewall read as 8.0G of 8.0G — "full" — while using
1.15G, with its reported `mem` exceeding its own `maxmem`, which no genuine
guest figure can do. Printing that number would steer an operator away from the
one VM on the system with real memory to reclaim.

LXC containers need no agent: their memory is the host's own accounting. Their
declared figure is a **limit** they may never reach, not an allocation the host
must find — so the report totals **VMs and LXC separately**. Summing them would
describe nothing: on a live estate the combined figure read 106G where the VMs
had actually been promised 60G.

PVE **templates are excluded**: a template is the image a module is cloned from,
holds no memory, and listing it as a stopped guest is noise.

### `guests [<node>] [--json]` — what uses a node, by module

Each guest's memory, declared, used and available as the `guest-memory` gate reads it from the
balloon, and the ZFS volumes behind it (`zfs list` on the node, `vm-<id>-*` and `subvol-<id>-*`),
each with the module of that vmid. A volume's `used` is what it holds on disk after compression
(`usedbydataset`) and `snapshots` what its snapshots hold; ZFS's own `used` is not shown, since on
a thick zvol it adds the whole reservation and reads larger than the disk. A volume of a guest running on another node is its replica
(`replica: true`). `--json` prints the node's document, or `{ nodes: [...] }` for every node. The
console's module pages read it. Changes nothing.

### `ipv6-egress` — the site reaches the internet over IPv6

When a site runs IPv6 every guest prefers it, and a broken IPv6 path hides behind
IPv4: names with an AAAA record stall or fail, everything else works. The gate
checks both ends:

- **The firewall.** OPNsense learns its IPv6 router once, from the advertisement
  that answers its own router solicitation, and sets a static default route to
  it. When the ISP replaces its router and the new one does not advertise on its
  own, the route keeps pointing at an address nobody answers. The gate reads the
  route, pings its router on the WAN (link-local, which the firewall may reach),
  and compares it with the router OPNsense records and the `WAN_DHCP6` gateway.
  The finding names the fix: `network-manager wan ipv6-relearn --check`, then
  `--apply` (it keeps the WAN's DHCPv6 lease).
- **The egress.** A public IPv6 address (`2606:4700:4700::1111`,
  `2001:4860:4860::8888`) must answer from inside the site: an HTTP HEAD from the
  cicd VM when it has a global IPv6 address, else a ping from the first of up to
  three guests in a Service zone with an `ipv6Subnet` that answers SSH. The
  firewall's own ping is no test: its filter lets the firewall itself reach
  link-local addresses only. A guest without a global address is reported as
  such: its zone's advertisements are missing, not the uplink.

Firewall findings sit on the `network` module, the egress finding on the site's
uplink (the ISP in the console's physical view).

### `pending-reboot` — guests whose update is waiting for a reboot

`update-os` does not always reboot after a rebuild: not with `automaticReboot`
off, not while a backup holds the VM, and never the controller that runs it.
Each of those prints a `DEFERRED:` line that the update sweep collects into
`deferred_changes` — but that record belongs to one run. This gate answers
"which guests are waiting **now**", from the guests themselves:

- **NixOS:** the booted system (`/run/booted-system`) is not the system profile
  (`/nix/var/nix/profiles/system`). When the two differ in release, the row says
  so: since #728 a nixpkgs release move is *staged* for the next boot, so a
  guest in that state still **runs the old release** — `release move 25.11 ->
  26.05 staged, still running 25.11`. One that was switched instead (the
  controller, which updates itself) runs the new release on the old kernel —
  `release move 25.11 -> 26.05 active, still on the 25.11 kernel`. Otherwise it
  is a newer generation of the same release (a kernel, a bootloader change) and
  the row names both builds.
- **Debian:** `/var/run/reboot-required`.

Nothing is stored: a flag in a module's config would go stale the moment
someone reboots by hand, the derived state cannot. The gate **WARNs and never
fails** — a pending reboot is debt, not an outage, and a site that reboots in
its own window is healthy while it waits. Take one with `health-manager reboot
<module>`, or with the update itself: `module-manager module update <module>
--allow-disruption`.

### `scan security` / `report security` — what runs, and what needs a fix (ADR-011)

`scan security` inventories everything running on the installation and matches
it against the CVE source of its layer, read-only on every target:

| Target | How it is found | Inventory | Matched by |
|---|---|---|---|
| the mothership | the module whose `vmname` is this host | its NixOS runtime closure (`nix-store -q --requisites`) | `grype` |
| a module's VM | every managed module with a `vmid` | its closure (NixOS) or its dpkg status (Debian), over ssh as `tappaas` | `grype` / `trivy rootfs` |
| a module's LXC | `kind: lxc` | the same probe, through `pct exec` on the node it runs on | `trivy rootfs` |
| a running image | the containers `podman`/`docker ps` lists inside each target | the image by its **registry digest**, never its tag — one target per image | `trivy image` |
| …its bundled native libraries | the same containers | what the container's own Python reports: FFmpeg in PyAV, libsndfile in soundfile, Pillow's codecs, OpenSSL in cryptography, OpenBLAS in numpy, Python's expat | `grype` by CPE, on the image's target |
| a node | the `pvehost` instances (`site-manager node list`) | its dpkg status | `trivy rootfs` |
| the firewall | the module that provides `network:rules` | `pkg query` | `pkg audit` + `pkg upgrade -nU` |

trivy sees an image's OS and Python packages but not the shared libraries a wheel
ships inside it, loaded in the application's own process. The scan asks each
container's Python for those versions (a script on stdin; nothing is installed),
matches them by CPE and counts them on the image. They carry no fix-state: the fix
is a new image. Wheel libraries it cannot attribute are counted in the image's note.

A Nix package's CPE vendor comes from the mothership's nixpkgs
(`meta.identifiers.cpeParts`), which is the estate pin every guest is built from
(ADR-028 D1): a guessed vendor (`glibc:glibc`) matches nothing in NVD.

Each target gets a **verdict**, not a CVE count:

| Verdict | Means |
|---|---|
| **ACT** | a Critical/High CVE with a fix published and not applied (OPNsense: a vulnerable package the channel has an update for) |
| **SCAN FAILED — not clean** | coverage failed: unreachable, no packages seen, no OS detected (a NixOS closure without glibc, or under 50 packages) |
| act (low/medium only) | fixable, but nothing Critical/High |
| triage (Nix) | matched by CPE; Nix carries no fix-state, so a person decides — and records it as VEX |
| watch | nothing fixable: waiting on upstream |

The firewall's `pkg audit` (VuXML) carries no severity; each CVE id's severity
is looked up in grype's database, NVD first. On a Debian host, findings only in
build-only packages (kernel headers, compilers, `-dev`) are counted apart
(`buildOnly`) and named under the report. Each target names its `module` (a node
is `pvehost`'s; an instance in another environment, such as `deconz-test`, is its
config's `moduleSource` module, so the module's VEX applies to it), and a node lists what is installed on it as packages (`apt`:
backup); Proxmox's own packages are matched by no feed, and the node's note says so.

**Output** goes to `config/sbom/`: `site.cdx.json` — one CycloneDX 1.4 document,
each target a component with its packages nested — and `cve-status.json`; the
scan before is kept as `cve-status.previous.json`, which is what makes "new"
mean something. `--notify` mails the site owner (through `site-notify.sh`, the
ADR-007e target) only when a fixable CVE or a failed scan is **new** since that
scan. **Triage decisions** are committed next to the module as
`<module>-vex.json` (CycloneDX VEX: `not_affected`, `false_positive`, `resolved`
suppress a finding; a versioned `affects` ref stops applying when the version
changes; `exploitable` keeps it counted and, in `scan nix-list`/`scan images`, marks
it `triage` with the risk from the statement's `ratings[]` entry whose source is
`TAPPaaS` — the risk in this deployment, which the release preview's RISK column
shows). A module's file decides for that module's targets (its VM and images)
only — whether a package's flaw is reachable depends on how the module uses it;
`templates-vex.json`, the shared base, decides for every target, and a Proxmox
node's findings are `pvehost`'s. They are read from the module directories of every repository in
`site.json` `.repositories` — Community modules included — and the scan's notes
say how many statements it applied and name any file it could not parse.

**When it runs.** `tappaas-security-scan.service` starts after every
`update-tappaas` run, failed or not, and scans only when that run wrote a sweep
result (`--if-new-sweep`). The scanner databases live in `~/.cache/{grype,trivy}`
on the root disk — about 6 GB — and the first scan refuses to download them
when they would take the root disk over 80%, the `disk-threshold` gate: every
target is then SCAN FAILED and the scan's note says to grow the mothership's
disk. With the databases present a scan of hrossen (21 targets)
takes about 30 s.

**The daily rescan.** `tappaas-security-rescan.timer` runs `scan security
--rescan` once a day (04:30, up to 30 minutes later): it refreshes the grype and
trivy databases and matches the last inventory (`site.cdx.json`) again — grype
for a Nix closure and a bundled library, `trivy sbom --offline-scan` for an OS
or image inventory. No guest is probed, no new SBOM is taken, no sweep runs, and
nothing but the scanners' database mirrors is contacted. The firewall's findings
come from its own audit, so they, and a target whose inventory failed, stay as
the last full scan found them. `cve-status.json` then says `inventory`: when the
inventory it matched was taken. The scan and the rescan share a lock
(`config/.security-scan.lock`).

`report security --scan` prints the last scan: ACT first, then failures, then the
rest, and the first ten findings to act on per target (`--all` for every one).
The `cve-status` gate in `validate` only ever WARNs — a CVE published upstream
must not be able to fail a sweep or a test run.

### The CVE risk score on the running site

Each scanned CVE has one of four states: **decided** (a VEX statement says not
affected, false positive or resolved, or a nixpkgs patch fixes it), **risk**
(analysed, exploitable here, with a TAPPaaS rating), **open** (critical or high,
not analysed) and **carried** (analysed for another version of the same
package, which no longer runs here: the earlier analysis is shown, and counts as
open until someone confirms it). The scan lists them per target (`items`), with
the VEX analysis text, never whether a fix exists.

The score is `score.ts` in `lib/ts` (the same function `health-manager score`
and the release preview use): only a module's highest category counts, each
further item at half the one before; risk items 25/10/3/1 by their rating, open
and carried 20/8. Levels: ok 0, low below 7, medium below 16, high below 30,
critical from 30. What is scored (`site-score.ts`):

| Unit | Its CVEs | Its zone |
|---|---|---|
| a module | its VM or container and the images running in it, one CVE counted once | its `zone0` (none: `no zone`, ×1) |
| a node | its Debian packages | the management zone |
| the firewall | its `pkg audit` | the management zone (it sits in every zone) |

A zone is its highest unit times its tier's multiplier (tier 0 ×2, 1 ×1, 2 ×0.75,
3 ×0.5, 4 ×0.25, 5–6 ×0.1, none ×1); an environment the highest of its zones; the
site the highest of its environments and of the zones in no environment. Every
scan and rescan adds the day's scores to `config/sbom/score-history.json` (30
days), which draws the console's 7-day sparklines.

`report security` prints it: the site, each environment, its zones with their
multiplier, and the units in them, each with level, score, what sets it,
open/risk/carried/decided counts and the last 7 days; `--cves` lists each unit's
counted CVEs under it. `--json` prints `cve-status.json` with the scores under
`score` (the console's `/api/security` reads that).

**Health.** The `security` condition of a module, a node, a zone and an
environment takes its status from the level: ok and low → ok, medium and high →
warning, critical → critical. The reason names the level (`cve-medium`,
`cve-high`, `cve-critical`), so a level change is a transition and an event even
while the status stays warning. A zone and an environment carry their own score,
with the multiplier, not the worst of their members. A target whose scan failed
is a `cve-scan-failed` warning; a scan older than 8 days is `cve-scan-stale` on
the site.

**Alerts** (`tappaas-cicd-alerts.json`). Each scan writes one line to the journal,
identifier `tappaas-security`: `cve-new` lists the critical/high CVEs new since
the last scan that nobody has analysed, and `cve-new-critical` mails it at once,
one mail per scan; `cve-changes` (a new risk or carried item, a level going down)
reaches the daily digest, whose mail gets a security section: the site's level
and the analysed and carried items. A module's level rising to high or critical
is emit's transition with `levelUp`, mailed by `cve-level-up`. A module whose
security condition is acknowledged or in maintenance is left out of all of it:
quieting is `health-manager ack <module> --type security` and maintenance
windows.

### What `cpu-impact` measures

An HA guest with `haCpu: common` runs the CPU level its two nodes share, which
on a mixed pair drops the newer node's extra instructions. For AVX-512 the cost
can be measured: the kernel records, per process, how long ago it last used it
(`/proc/<pid>/arch_status`). The gate lists, per HA guest still running its
node's full CPU, the processes that used AVX-512 in the last minute.

Read it as *what uses it*, not *how much it costs*. glibc picks AVX-512 string
routines on a CPU that has them, so nearly every process shows up — and falls
back to AVX2 versions of the same routines at a similar speed. A large impact
needs compute-heavy work among them (machine learning, media, databases); for
such a module, benchmark it before restarting it onto the shared level, or set
`haCpu: host`. There is no counter for AVX2 and below, a guest that already runs
the shared level has nothing left to lose, and a guest that cannot be reached
(the firewall) is listed as not measured.

### What `memory-commitment` counts, and what it deliberately does not

It reports, per node, the memory **committed to running guests** against the
node's physical RAM — the number that answers "will another guest fit". Three
choices are worth knowing:

- **Committed, not used.** Without ballooning a guest's declared memory is
  pinned by the host whether the guest wants it or not, so committed is what
  constrains placement. A node's *used* figure can exceed its committed one
  perfectly legitimately, because ZFS ARC and host overhead are not guest
  memory — a gate written against `used` would fail a healthy node with a warm
  cache.
- **Stopped guests hold nothing.** A stopped guest is not counted; counting it
  would report an overcommit the node is not living with.
- **A container counts at what it uses, not at its limit.** A VM counts at its
  configured memory: without ballooning the host keeps every page it has touched.
  A container's memory setting is a ceiling the kernel enforces, not memory set
  aside, so a running container counts at its highest use of the last week
  (Proxmox `rrddata`) plus 25%, at least 512 MB and at most its limit; with no
  history yet, at its limit. Counting limits made hrossen read 46 GB of container
  memory that used 2.9 GB.
- **Not counted:** night-time use, KSM, the guests' zram, the ZFS ARC and host
  swap. They are a margin the node runs on, not capacity it can promise.
- **An idle node is reported at 0%, not hidden.** An empty node beside a full
  one is a placement problem, and the report is where you see it.

`health-manager capacity` answers the same question for **after** an update:
each running guest counts at what it commits with the memory its config asks
for, because the update converges it to the config. A node whose VMs were sized
down by hand in Proxmox commits more once it is updated, and that is seen here
before it happens. The update sweep runs it first (threshold 95%):

| Node after the update | Verdict |
|---|---|
| under the threshold, nothing grows | pass |
| under the threshold, a guest grows | warning: memory changes |
| over the threshold, nothing grows | warning: it runs like that today, so the update goes ahead — rebalance when you can |
| a growth would take it to the threshold | **held**: that module is updated with its current memory, everything else goes ahead, and the next update tries again; `--force` applies it anyway |

Growth is let through smallest first, as long as the node stays under the
threshold; the rest is held. `--json` names the held modules (`held`: module,
node, from, to) — the sweep passes them to the converge, which leaves their
memory alone and reports the growth as held. A container whose limit is raised
grows only by what it uses.

Two more questions, for room the update needs only for a while (#891):
`--room-for <module>` — would starting this suspended module fit on its node — and
`--drain <node>` — would this node's HA guests fit on the other nodes for its reboot (the
others counted together, as the HA manager spreads them). Each answers with `pause`: the
`pauseOk` modules that would make it fit, lowest `pausePriority` first, equal ones largest
first, never a foundation module and never a non-HA guest on the node being drained (it
restarts with the node). Exit 1 when even pausing all of them would not do. The update
pauses them only in its maintenance window.

`install-module` runs it with `--install <instance>` before it creates the
guest: the new module's memory lands on its node, and an install that would
take the node to the threshold is refused (`--force` does not override it —
move the module with `--node`, or make room first). The update's patch pass for
suspended modules asks the same question before it starts a suspended guest.

**read-only** here. Growing a disk is the cluster service's: every module update
grows a VM disk or a container's rootfs that is filling up, when its pool has room
(see the `cluster:vm` README, *Automatic disk growth*). `check-disk-threshold.sh <vm> <threshold>`
makes the same decision on demand with a threshold of your choosing.

### `alerts [--module M] [--host H] [--node N] [--json]` — open and recent alerts

What the alert mails said, still to be seen (ADR-039): **open** — state alerts firing now, read
from Grafana on the logging VM (as admin, on that VM, the password never leaves it); **recent**
— event alerts of the last 24 hours, from the mothership's alert receiver
(`/var/lib/tappaas/alerts.jsonl`; an event fires only for its window, so it would not stay
open). Each is placed on the module, machine or node it is about: a rule's `module`, a host
resolved to its instance by vmname, a node to its `pvehost` instance. The heartbeat is never
listed. Read-only.

### `update-os <name> <vmid> <node>` — OS-patch action (special)

`update-os` stays a distinct **action** verb (it patches the OS; not CRUD). The
manager is a thin pass-through: it forwards `<name> <vmid> <node>` to
`update-os.sh` (overridable via `UPDATE_OS_BIN`) and propagates its exit code.
The OS-patch logic (NixOS rebuild / apt, IP+SSH wait, DHCP-hostname fix,
reboot guards, controller-self-reboot protection) lives in `update-os.sh` and is
not re-implemented here.

**When it reboots.** After a NixOS rebuild `update-os` reboots the guest and
waits until the module can serve (not merely until sshd answers) when
`automaticReboot` is on in `site.json`, **or** when the run was authorized with
`--allow-disruption` — `module-manager module update <m> --allow-disruption`
exports `TAPPAAS_ALLOW_DISRUPTION=1` (ADR-020 D8). Otherwise the reboot is not
taken, and so is it when a backup holds the VM (#686) or the VM is the
controller running the update. All three print a `DEFERRED:` line naming what
is waiting — the new generation, or a staged release move — which the update
sweep collects into its result (#730).

### `reboot <module>` — take a pending reboot (special)

```
health-manager reboot nextcloud
```

Reboots the module's VM and waits until the module can serve again: the same
reboot path `update-os` takes after a rebuild (`reboot_guest` in `update-os.sh`
— wait out a backup lock, `qm reboot`, SSH, then the module's readiness), on
demand and **without updating**. The manager resolves the module to its VMID
and to the node the VM **actually runs on** (HA may have moved it), reads the
guest's pending state before and after, and hands the reboot to
`reboot-guest.sh` (overridable via `REBOOT_BIN`):

```
  pending: booted 25.11.20260522.b77b3de, next boot 26.05.20260922.1bc55b9
  … reboot, readiness …
✓ nextcloud runs 26.05.20260922.1bc55b9
```

- Exit **0** when the guest came back ready; **1** on an error, a refusal, or a
  reboot that did not take the new system (it names what it still boots);
  **3** when a backup still holds the VM after the wait — nothing was rebooted.
- **Refused:** the controller itself (rebooting it would kill the command — the
  message gives the `qm reboot` to run from a node), a container (`pct reboot`),
  and a module with no VM.
- The reboot is the operator's explicit act, so it needs no `automaticReboot` or
  `rebootOk` — that is what separates it from the update sweep.

## Assess

## Emit — health events, acknowledgements, maintenance (ADR-041 D2, D4)

`assess` writes conditions to the CMDB; everything here reads them. `<ci>` is an id, a name or
`<class>/<name>`; a `<time>` is an ISO time or a span (`30m`, `2h`, `7d`).

### `emit`

One event per condition transition since the last run, as one JSON line in the journal,
identifier `tappaas-health`, which Loki holds and ADR-039's rules read:

```bash
journalctl -t tappaas-health --since today -o cat | jq -r 'select(.event == "transition") | "\(.name) \(.type) \(.from)->\(.to) \(.kind)"'
```

| `event` | Fields |
|---|---|
| `transition` | `id`, `ci`, `class`, `name`, `type`, `from`, `to`, `reason`, `message`, `kind`, `rootCause`, `correlated[]`, `since`, `at`, `flapping`, `root`, `symptoms`, `impacted`, `silenced` |
| `flapping` | the same, with `phase` `start` or `end` |
| `ack`, `unack` | `ci`, `class`, `name`, `type`, `by`, `note`, `sticky`, `until`, `why`, `symptoms[]` (ids), `at` |
| `maintenance` | `phase` `start`, `end` or `cancel`, `ci`, `class`, `name`, `by`, `note`, `until`, `why`, `at` |
| `rootcause` | `ci`, `class`, `name`, `type`, `symptoms[]` (ids), `impacted`, `cleared`, `at`; once per change of a root's set |

- `kind`: `recovery` on a return to ok; `symptom` for an `impact` or derived condition; `causal`
  when the object is in the site's `rootCauses` for that type; any other failure is a `symptom`.
- `root` says the object is a root cause, or was one until this recovery; `symptoms` is how many
  objects it impacts and `impacted` what they are, by class, most first (`3 vm, 2 service`;
  `nothing` on a symptom); `silenced` is acknowledged or in maintenance: told, never mailed.
- `correlated` lists the events of the same run with the same root.
- **Flapping** is judged over the last 20 assess intervals, each changed or not, the oldest
  weighted 0.8 and the newest 1.15: above 30 % it starts, below 25 % it ends. While it flaps one
  `flapping` start, at the worse status, and one end replace the transitions; the condition
  carries `flapping: true` and `flappingHeld`.

The cursor is `config/.health-emit-cursor`: the CMDB change id read up to, the time, and the roots
last told. Without one, a run tells only the current roots and starts from there. `--since` tells
a period again, mails included. Runs overlap under `config/.health-emit.lock`; a run that finds it
held leaves the work to the next. A CMDB that does not answer tells nothing, moves no cursor and
exits 0.

The console's change stream takes nothing from a client: it shows the change report `assess`
wrote, and the console reads the conditions, or these lines through Loki.

### `ack`, `unack`

An acknowledged condition keeps its status and stops counting for `validate`, mails and the
Overview. Without `--type`, every condition of the object that is not ok. It ends at `--until`, on
a return to ok, and at the next status change unless `--sticky`; emit tells the `unack` with its
`why`. An ack on a root cause (its condition of the type in `rootCauses`) silences every `impact`
condition naming that root, as an ack with `via: [<root ids>]`, while the root's holds: a symptom
that gets a root of its own is heard again, and `unack` restores them. Written as a change, with
the console's job id. Like any change on an object, it clears the object's drift mark (ADR-040 D6).

### `maintenance`

A window on every condition of the object, and on any that appears during it: transitions are told
with `silenced: true`. It ends at `--until`, or by `maintenance end` (done early) or `cancel`
(withdrawn). An object with no conditions yet is refused: run `assess` first.

### `show`, `list`, `roots`, `history`

`show`: an object's conditions, since when, its root cause or what it impacts, its acks. `list`: a
row per condition, worst first, everything not ok unless `--status` says otherwise. `roots`: the
site's root causes, most impact first, each with its objects. `history`: an object's transitions,
from the CMDB's attribute history. Each takes `--json`.

### The timer and the hooks

`health-assess.service` runs `health-manager assess && health-manager emit` as `tappaas`, after
every `cmdb-sweep.service` and on `health-assess.timer`, every `health.assessInterval` minutes of
`site.json` (1 to 60, default 5). `update-tappaas-schedule.sh` renders the timer; after editing
the setting:

```bash
sudo systemctl start update-tappaas-schedule.service
```

`tappaas-alert-receiver` runs `assess --only <ci>` and `emit` for each ALERT or RESOLVED it gets,
on a worker thread, placing the alert as `alerts` does; one about no known object assesses the site.

`tappaas-cicd-alerts.json` holds the three rules over these lines, and over `cmdb sweep`'s.
`HealthRootCause` mails a causal event that is not silenced and whose status is **critical**, with
what it impacts by class (`impacts: 3 vm, 2 service`), except a module whose CVE risk rose to critical, which
`CveLevelUp` mails instead; `HealthRootRecovered` mails the RESOLVED of a critical root's recovery.
`HealthDailyDigest` collects the rest once a day: a warning that became a root cause, and every
sweep difference nothing explains (drift, unmanaged, missing, differing from `config/`) — one mail
while the last 24 hours hold any such line, none on a quiet day. `health-manager digest` writes
the mail: what is new since the last one, what is still open, what cleared. With something new it
is an ALERT, else a STATUS; a known warning stops counting with `ack`, and a sweep's addresses are
one count, never a finding. Nothing mails a symptom. All are `event` rules: a log
rule's own resolve follows its window, not the recovery, so the RESOLVED is a mail of its own and
not a reply to the ALERT. Which events leave the site is the rule file's choice (ADR-039 D1).

## Reports to the CMDB

`health-manager assess [--only <ci>] [--json] [--dry-run] [--timing]` (ADR-041 D2) is the
calculating half, and the only writer of `conditions` on the CMDB's objects. It
gathers what the sources say and writes everything in one report:

| Source | Becomes |
|---|---|
| The gates | a condition on the object each row judged: `service-liveness`, `storage-replication`, `quorum`, `lan-uplink`, `switch-ports`, `mlag-pairs`, `pulse`, `ipv6-egress` → `operational`; `disk-threshold`, `memory-commitment`, `guest-memory`, `storage-pools` → `capacity`; `backup-status` → `backup`; `pending-reboot`, `site-timezone`, `backup-keys`, `cpu-impact` → `maintenance`; `signature-status`, `control-plane-trust` → `security` |
| Grafana's open alerts, the receiver's record | a `warning` on the alert's CI id, else where `alerts` places it: `security` for RootKeyChanged and FirewallCertChanged, `operational` for the rest |
| The last sweep's lists | `drift` on each object named: `critical` when missing, else `warning`. No sweep in 48 hours, or a source that failed: `critical` on the site |
| Thresholds over the CMDB's observations, never the plane | a `storage-pool`'s and `datastore`'s used/size (warning 80%, critical 90%) → `capacity`; a pool's `zfsState` (DEGRADED warning, FAULTED and worse critical) → `operational`; a cabled port's `link` down → `operational` critical; a `vpn-peer`'s `lastHandshake` over 7 days → `operational` warning; a certificate on the firewall's `discover` data, the newest per common name, under 30 days warning, under 7 critical → `security` |
| `cve-status.json` | `security` on the module or node: a `warning` on `act` or a failed scan, as its gate |
| Observations in the CMDB, class by class (`assess-observations.ts`) | see [What judges which class](#what-judges-which-class): the managers report, this judges, no plane is asked |

Then it derives impact, root causes and roll-ups (below). `open-alerts`,
`cve-status` and `cmdb` still print in `validate`; their conditions come from
the sources above, which read the same data per object.

A condition is written in ADR-041 D1's shape, one per type per object:

```json
{ "type": "operational", "status": "critical", "reason": "guest-stopped",
  "message": "not running", "since": "2026-10-30T02:14:00.000Z",
  "lastChecked": "2026-10-30T08:00:00.000Z", "source": "health-manager",
  "derived": false, "rootCause": null, "acknowledged": null, "maintenance": null }
```

- **Worst wins** over the sources for one type. A finding about something the
  CMDB does not have lands on the `site` object, so nothing a gate said is lost.
- **`since`** is when status or reason last changed. Unchanged, only
  `lastChecked` moves, and the message stays the one of the transition.
- **A failure stands until the source that raised it has looked again.** A gate
  that skipped, a guest it could not reach, or Grafana not answering takes
  nothing back, and `lastChecked` shows how old the verdict is.
- **What the operator set is kept:** `acknowledged` until its `until`, and a
  plain one until the status changes, a sticky one until ok; `maintenance` until
  its `until`.
- `--only <ci>` (the alert receiver's call) runs no gate: the other sources
  speak for that one object, and impact and root causes are worked out again.
- `--timing` prints each phase's duration on stderr as it ends, so stdout (and
  `--json`) stays the result: the CMDB reads (`cmdb objects`, `cmdb relations`,
  `cmdb ended`), every gate on its own line (`gate <name>`) and `gates` for all of
  them, `alerts`, `sweep`, `cve`, the working out (`thresholds`, `observations`,
  `settle`, `derive`), `cmdb write` and `total`:

  ```bash
  health-manager assess --dry-run --timing 2>&1 >/dev/null | sort -k2 -n -r | head
  ```
- An assessment is no sighting: it writes by id, creates nothing, and neither
  holds off a CI's expiry nor brings an unseen one back. Its report is not
  spooled: conditions are now, and the next run writes them. A CMDB that does
  not answer (cmdb-controller restarting) is no failure: `assess` warns, writes
  nothing and exits 0, as `emit` does; a report the CMDB refuses still fails.
- `health-manager report` is `assess` under the name every `cmdbSource` answers
  to (`--from <file>` takes the gates from a saved `validate --json`, `--json`
  prints the payload). `TAPPAAS_CMDB=off` writes nothing.

`validate` reads the result: the gates' table as the last assess left it, with
one more line, `conditions`, for what no gate prints. A row whose condition is
derived, acknowledged or in maintenance stops failing and says why; exit 1 means
a `critical` condition that is none of those. `--live`, or a threshold given,
assesses first. So does an assessment older than three intervals (30 minutes at
least): a verdict is never read from a timer that stopped. With no CMDB the gates
run as they always did.

The interval is `health.assessInterval` in `site.json` (minutes, default 5).

### What judges which class

Every class, what gives it a colour, and what a failure means. The managers report
observations and `assess` judges them (ADR-041 O3's direction): none of these asks a
plane. *Seen* is the lifecycle judgement: `operational` is `ok` while a source reports
the CI within its class's expiry, `warning` (`unseen`) once it does not.

| Class | Judged by | Failure, as `reason` |
|---|---|---|
| `vm`, `lxc` | gates (liveness, disk, memory, backup, reboot, timezone), alerts, CVE, sweep, seen; the newest restore point, 3 days → `backup` | `guest-stopped` and the gates' reasons, `restore-point-stale`, `unseen` |
| `machine` | gates (memory, disks, uplink, timezone), alerts, CVE, sweep, seen; a file backup's restore point | the gates' reasons, `restore-point-stale`, `unseen` |
| `device` | `switch-ports`, `mlag-pairs`, sweep, seen; a VLAN no zone declares, VLAN 1 aside → `drift` | `switch-port`, `vlan-undeclared`, `unseen` |
| `app`, `service`, `controller`, `manager` | its `runs-on` node; `version` against `release.version` → `maintenance` | `software-no-node` (none: a retired node ends the relation), `software-node-unseen`, `version-off-pin` |
| `zone` | its firewall `interface` and DHCP range; its VLAN against the switches' `vlans` | `zone-interface-disabled` (critical), `zone-no-interface`, `zone-vlan-uncarried` |
| `ssid` | its zone exists, an AP broadcasts it | `ssid-no-zone`, `ssid-not-broadcast` |
| `address` | who holds it: a node's addresses, a device's management address, a private name `<node>.<zone>.internal`; a reservation's MAC against NICs, ports and what they see | `address-holder-unseen`, `address-holder-retired`, `address-no-ci`. A lease nobody holds is `ok`: it carries no MAC yet, so a client is not told from a guest |
| `dns-name` | its target: an address, a node, another name. A public name's target is the WAN's: `ok` | `dns-no-target`, `dns-target-unknown`, `dns-target-unseen`, `dns-target-retired` |
| `proxy-route` | the node of its upstream | `route-target-unknown`, `route-target-unseen`, `route-target-retired` |
| `vpn-peer` | `lastHandshake`, 7 days; seen | `vpn-handshake-stale` |
| `storage-pool` | `zfsState`, used/size, `storage-pools`; seen. **What it is `built-on`**: a member disk failed degrades it (`impact` warning naming the disk) while its mirror or raidz vdev has a member left, and takes it down once none is; its own DEGRADED is then that failure seen from above, and the disk is the root cause | `pool-state`, `pool-usage`, `redundancy-degraded` |
| `disk` | Proxmox's `health` (every report); its state as a member of each pool `built-on` it; the sweep's `smart`, `wearout` and `temperature`; `faulty` → `maintenance`. **Nothing observed: follows its asset** | `smart` (critical: health FAILED; warning: reallocated, pending or uncorrectable sectors, media errors, an NVMe critical warning), `zfs` (critical: FAULTED, UNAVAIL or REMOVED; warning: DEGRADED), `wear` (warning under 10 % of its rated life), `temperature` (warning at 60 °C, an NVMe disk 70 °C), `asset-faulty` |
| `datastore` | used/size; `gc` last run → `maintenance`; seen | `datastore-usage`, `gc-failed` |
| `backup-peer` | `pulse`, `lastSeen` 3 days → `backup`; seen | `pulse`, `peer-stale` |
| `share` | every grant's consumer is a node | `share-consumer-gone` |
| `port` | cabled: `link`, and `linkSpeed` under the cable's recorded speed, else the slower end's. Not cabled: `link` against a declared `role`, `switch-ports`. **No link data: follows its asset** | `link-down` (critical), `link-slow`, `role-port-down`, `switch-port` |
| `server`, `network-device`, `appliance`, `passive-device`, `other-device` | `faulty` → `maintenance`. **`operational` follows its node** where it is allocated to one | `asset-faulty` |
| `organization`, `group`, `user`, `role` | seen only: nothing observes more | `unseen` |
| `site`, `cluster`, `environment` | seen, and the roll-up of their members; `quorum` on the cluster | `quorum-at-risk`, `roll-up` |
| `location`, `room`, `rack` | the roll-up of what is in them. **Not assessed by design** when empty: grey says nothing is there | `roll-up` |
| `node` | a placeholder's class: **not assessed by design**, a placeholder gets no conditions | — |

**Follows.** `FOLLOWS` in `lib/ts/src/health-rules.ts` names what nothing judges:
a port or a disk its asset, an asset its node. Such an object gets a `derived` `operational`
condition, reason `follows`, with the worst of the parent's `operational` and `impact`
(`ok` when the parent is judged only in other types). It is worked out on every run,
names the parent or its root as `rootCause`, and is never a failure or a root of its own.

A port's `link` with no declared role is never a failure: an operator's record of a
switch lists every free port. `linkSpeed` reaches the CMDB from a node's NICs
(`site-manager report --discover`) and from a switch whose controller gives it.

### Root causes

`metamodel/health-rules.json` says how a failure travels: each rule names a
relation type, optionally the class of either end, the source condition and the
impact it produces. A rule may also read the dependant: `"dependant": { "haNode": true }`
matches only a dependant whose attribute has that value (`true`: any value that is
set), and such a rule wins over one without it for the same crossing. Shipped:
`operational critical` crosses `runs-on`, `depends-on`, `member-of`, `connects` and
`built-on` (a disk to the pool built on it) as `critical` impact, except that over
`runs-on` a guest with `haNode` set (HA-protected) gets a `warning`: its node failed,
and it is moving or has moved. A pool's mirror or raidz members are one redundancy
group: one failed member degrades the pool, all of them take it down.
A warning crosses nothing. `health-manager rules list` shows them (`… crosses
runs-on to a dependant with haNode set as warning impact`); `rules check [--file F]`
validates them or a candidate, and exits 1 on what it cannot place, a dependant
clause naming an attribute no class has among it.

```json
{ "relation": "runs-on", "source": { "type": "operational", "status": "critical" },
  "dependant": { "haNode": true }, "impact": "warning" }
```

A crossing softer than the failure (a warning for a critical) still explains the
dependant's own condition of that type: the HA guest that stopped with its node is
`derived`, not a root of its own.

The relation types say which end is hurt (`dependant`) and whether it needs the
other (`required`). A relation row may override `required`, and may name a
`redundancyGroup`. Relations with one group name, anywhere on the site, are one
redundancy: a bond's two cables, an MLAG pair's peer links, a LAG's two legs.
While every member is down the rule's own impact crosses; while only some are,
the dependant of each failed member gets a `warning` impact, reason
`redundancy-degraded`, naming the failed member (`one of two in tappaas1:lanbond
down: port sw-01/5: link-down`), and its root as `rootCause`. Such a dependant is
no root cause: the failed member is. site-manager sets the group on a node's
bonded uplinks (`<node>:<bond>`), switch-manager on an MLAG pair's peer links
(`<pair>:peer`) and the legs of an MLAG LAG (`<pair>:<lag>`).

The site object carries the result as `rootCauses[]`, most impact first:

```json
[{ "id": "<the object's id>", "type": "operational", "impactedCount": 7 }]
```

Roll-ups: a `collection` and a `place` carry the worst of their members per type,
derived and counted (`3 of 12 critical`), leaving out what is acknowledged or in
maintenance. A collection's own worse condition stands. A roll-up is never a root.

## Common options

- `--config-dir DIR` — config root (default: `$CONFIG_DIR` or
  `/home/tappaas/config`). The one true common option across managers.
- `--json` — `validate`: every gate as `{name, status, detail, findings}`, each
  finding `{status, text, subject}` where `subject` is the `module`, `node`,
  `pool`, `peer` or `site` it is about (null on a total). The exit code is the
  text run's. The console (ADR-034) and `network-manager topology` read it.
- `--diff` — `list vm` only: the per-VM three-way rollup.
- `--threshold PCT` — `validate` only: the disk-usage gate threshold (1–99).
- `--memory-threshold PCT` — `validate` only: committed memory as a percent of a
  node's physical RAM before the gate fails (1–500, default 100).

## Node source

The cluster node list is the nodes' `pvehost` instances (lib/ts `nodes.ts`, the
`get_all_node_hostnames` equivalent). When none is registered,
health-manager falls back to scanning `tappaas1..9`. Either way each candidate is
ping-probed and only reachable nodes are used.

## Build

Built as `bin/health-manager` via `default.nix`. The CLI plumbing (colors,
`info`/`die`, the `guarded()` error guard, the `--help` renderer) and the
cluster ssh/pvesh helpers come from `../../lib/ts/src/` (`cli.ts`, `help.ts`,
`cluster.ts`, `config-io.ts`).

```
nix-build -A default default.nix
ln -sf "$PWD/result/bin/health-manager" /home/tappaas/bin/health-manager
```

> The legacy `*.sh` scripts are still linked onto `PATH` by `install.sh` and stay
> live; wiring `install.sh` to the nix build is intentionally **not** done in this
> pass.

## Deferred follow-ups (coordinator-approved)

These are intentionally **not** built in this pass — clean TODOs mark them in the
source:

- **NIC-drift rows** in `show vm` / the diff rollup (bridge / zone / VLAN /
  trunks / MAC) — requires porting `cluster/lib/vm-net.sh` (`vmnet_parse`,
  `vmnet_resolve_trunks`, `vmnet_zone_vlantag`: zone→VLAN resolution + `ALL`
  trunk-sentinel expansion). HANode / description rows fold in here too.
- **Nested-config normalizer** — the retired `inspect-vm.sh` ran each JSON through
  the bash `normalize_module_config` ("Pattern A → flat"); the port reads flat
  keys only, so nested/variant-shaped configs are not yet flattened.
- **`cluster` / `node` entities** — ADR-007 lists them alongside `vm`; their
  entity model (a node/cluster resource summary) is not yet defined.
- **Guest-agent liveness** — the `service-liveness` gate currently checks
  `pvesh` running-state only; adding `qm guest cmd <vmid> ping` is a follow-up.
- **Full `update-os` port** — today the verb shells out to `update-os.sh`.

## What `update-os` puts on a guest before it rebuilds

Beyond the module's own `.nix`, its sibling `.nix`, `.patch` and `.diff` files (#740) and its
companion JSON, one
generated file lands in `/etc/nixos` on every NixOS update (#472):

- **`tappaas-site.nix`** — from `config/site.json` via `lib/site-locale.sh`: time
  zone, locale, console keymap, and the zone gateway as the time source (#87),
  and the mothership's Nix signing key (`lib/nix-site-key.sh`). The module's
  `.nix` imports it.

The system built on the mothership is signed with that key and copied with
signatures checked: the guest takes it only signed by the site key or
cache.nixos.org, and the baseline asserts `require-sigs`. A guest that does not
trust the key yet — one updated before signing existed — takes one unchecked
copy, said in the log; the system it activates trusts the key. When the guest
has to build itself, it fetches the pinned nixpkgs by the lock's `narHash`
(ADR-033 D8).

The shared baseline `tappaas-common.nix` is deliberately **not** shipped: modules
still inline their own copies of it, so importing it fails the build on
conflicting definitions (#324).

A Debian guest has no fragment to import, so the same facts are *converged* there
instead — `timedatectl`, `localectl` and a `systemd-timesyncd` drop-in — and each
change is logged rather than made silently. Neither path invents a value: a site
that records nothing leaves the guest as it is.
