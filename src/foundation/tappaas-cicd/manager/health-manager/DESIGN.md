# health-manager — design notes

## Language and build

- **Language:** TypeScript (ADR-007 §Health / Remaining-outstanding #3), built
  with `tsc` and zero npm dependencies (the shared ambient
  `../../lib/ts/src/env.d.ts` declares the Node built-ins used). `default.nix`
  is a thin import of the shared `../../lib/nix/ts-manager.nix` builder, which
  compiles + wraps a `bin/health-manager` Node entry. Shared CLI plumbing
  (colors/`die`/`guarded`, the `--help` renderer) and the ssh/pvesh cluster
  helpers come from `../../lib/ts/src/`. The legacy
  `*.sh` scripts stay live and on `PATH`; **`install.sh` is not yet wired to the
  nix build** (deliberate, this pass).
- **`update.sh`** re-runs `install.sh` (idempotent relink of the `*.sh`).

## Verb surface (read-only manager)

health-manager owns **no config domain** — it reads existing module/zone config
and the live cluster — so the CRUD verbs (`add`/`modify`/`delete`/`reconcile`)
are **N/A**. The surface:

| Verb | Maps to | Notes |
|------|---------|-------|
| `list vm` | — | **MOVED out of health-manager** (was the port of the retired `inspect-cluster.sh`) |
| `list vm --diff` | — | **MOVED** → `module-manager list --diff` (per-module drift rollup) |
| `show vm <name>` | — | **MOVED** → `module-manager reconcile <m>` (read-only), native `module-manager/src/inspect.ts` |
| `assess [--only <ci> \| --alert <host>,<module>] [--dry-run]` | the gates, alerts, sweep, thresholds, observations, metrics, scan | the one writer of `conditions`: settles, ages, derives, writes one report (below) |
| `emit` | the CMDB's history of `conditions` | health events to the journal, critical-root notices through `site-notify.sh`, flapping |
| `show`, `list`, `roots [--all]`, `history` | the conditions | reads |
| `ack`, `unack`, `maintenance <ci> \| end <ci>` | the `acknowledgements` attribute; a window file | the operator's word; assess projects it |
| `rules list\|check` | the health records, the relations | one sentence per record; `check` refuses a record it cannot place and a conflict, and reports dependency cycles |
| `validate` | the conditions (`--live`: assess first) | **special**: asserts the *live* system is healthy (below) |
| `update-os <name> <vmid> <node>` | `update-os.sh` | special **action**; thin pass-through to the script |
| `reboot <module>` | `reboot-guest.sh` | special **action** (#730): resolves the module to its VMID and live node, then update-os.sh's own `reboot_guest` path |

Common options: `--config-dir DIR` (config root), `--json` (machine output for
`list`/`show`), `--diff` (`list vm` rollup), `--threshold PCT` (`validate` disk
gate). `--json` emits the typed result object (`ClusterInspection` /
`ClusterDiff` / `VmInspection`) so the verbs are scriptable.

### `validate` — the health gate (special meaning)

For the config managers `validate` means "config is well-formed". For **health**
it means "**the live system is healthy**": `assess` runs these gates against the
running cluster, and `validate` reads the conditions they became, **exiting
non-zero on a critical one that counts** (see *Assess* below).

| Gate | Source | FAIL condition | SKIP condition |
|------|--------|----------------|----------------|
| `service-liveness` | `pvesh /cluster/resources` | a managed config module's VM is not `running` | — |
| `disk-threshold` | SSH `df /` per managed guest | reachable guest `/` usage ≥ threshold (default **80%**) | no guest reachable |
| `memory-commitment` | one `pvesh /cluster/resources` | a node's memory committed to RUNNING guests ≥ threshold of its physical RAM (default **100%**) | cluster unreachable / no nodes |
| `guest-memory` | `pvesh` + one SSH per node (`ps`, `qm status`, balloon statistics) | a module using ≥ 90% of its declared memory (WARN ≥ 75%), or allocated above the declared limit | cluster unreachable / nothing running |
| `backup-status` | `backup-manager list --json` | a module disabled, or enabled-but-not-in-PBS-job | backup tooling absent / unparseable |
| `pending-reboot` | one SSH probe per guest (booted system vs profile; Debian `reboot-required`) | never — **WARN** per waiting guest (#730) | no reachable guest |
| `site-timezone` | the primary location's timezone (`site.json` `locations[primaryLocation].timezone`) + one `timedatectl` per node and per guest | never — **WARN** per node or guest on another zone, or when site.json has none (#837) | nothing answered |
| `pulse` | the backup node's `tappaas-pulse --status` | never — **WARN** when its timer is not running or a target is down (ADR-031) | no backup node, or it does not answer |
| `quorum` | `pvecm status` on the first answering node | never — **WARN** on two votes without a QDevice (#835) | no node answers |
| `switch-ports` | `switch-manager list-ports --json` (read-only: the switch as last read, by the delta's rules) | never — **WARN** per port with no record that is not parked, and per port set otherwise than its record (#853) | no switch-manager, or no switch |
| `cve-status` | `config/sbom/cve-status.json` | never — **WARN** on a failed scan, an ACT, or a scan older than 8 days (ADR-011) | no scan yet |

`--threshold` (default 80) and `--memory-threshold` (default 100) apply
cluster-wide. The disk gate is **read-only**: the 50%-auto-grow that
`check-disk-threshold.sh` performs is a *mutation* and stays in the script — it
is not part of the health assertion. The gate order is service-liveness →
disk-threshold → memory-commitment → guest-memory → backup-status →
pending-reboot → site-timezone → quorum → lan-uplink → ipv6-egress → switch-ports → pulse →
cve-status; `validate`
returns 0 only when zero gates FAIL (SKIP does not fail the assertion).

`guest-memory` renders one row per module beneath its own line (`CheckResult.rows`),
ordered by reclaimable gap and totalled per column. Its row status measures a
module against ITS OWN declaration — short of memory is a fault, over-declared is
not — while the gap column measures what ballooning could return. Those are
different questions and a single number cannot answer both. `warn` is a status
that reports without failing the assertion. Used is total minus available from
the balloon statistics (`src/balloon.ts`), because Proxmox's `mem` counts page
cache as used; a VM with no available figure keeps Proxmox's and says so.

**Why the two thresholds differ.** A full disk stops a guest, so 80% leaves
runway to act. Committed memory at 100% is not yet a fault: a node may promise
every byte it physically has. It becomes one past that, where the node has
promised memory it does not own — which is why the memory gate accepts 1..500
rather than 1..99. A site running deliberate overcommit with ballooning can say
so (`--memory-threshold 150`) instead of switching the gate off.

**Committed, not used**, and the distinction is load-bearing: without ballooning
a guest's declared memory is pinned by the host whether the guest wants it or
not, so committed is what decides whether another guest fits. A node's *used*
figure may legitimately exceed its committed one, because ZFS ARC and host
overhead are not guest memory — a gate written against `used` would fail a
healthy node with a warm cache. Stopped guests are excluded (they hold nothing),
and an idle node is reported at 0% rather than omitted, so an empty node beside
a full one shows up as the placement problem it is.

## Architecture (TS modules)

- `src/types.ts` — entity model (`RunningGuest`, `ConfigModule`, `ClusterRow`,
  `DriftRow`, `VmInspection`, `ClusterDiff`, `CheckResult`, `HealthReport`) +
  the **`ClusterClient`** interface (the Proxmox/cluster boundary).
- `src/config.ts` — loads module JSONs from `config/` (skips non-module configs
  with no `vmid`), resolves the git source JSON via `moduleSource`, and reads the
  cluster's node list, the `pvehost` instances (`siteNodeHostnames`, through lib/ts `nodes.ts`).
- `src/inspect.ts` — pure inspection logic: `inspectCluster` (`list vm`),
  `inspectVm` (`show vm` three-way), `clusterDiff` (`list vm --diff` rollup).
- `src/checks.ts` — the health gates + `runHealthGates` aggregation.
- `src/assess.ts` — `assess`: the sources' findings settled against what was
  stored, then the one report. Its reads are `AssessIO`, so tests stub the CMDB.
- `src/assess-sources.ts` — gates, alerts, sweep, thresholds and the scan as
  findings; `GATES` maps each gate to its condition type and reason.
- `src/assess-model.ts` — a condition, and `SiteIndex`: a gate's subject → its object.
- `src/assess-validate.ts` — `validate` as a read.
- `src/derive.ts` — the engine: impact, root causes, follows and roll-ups, driven by the health records. Pure.
- `src/rules.ts` — the records and the metamodel from the service; `rules list|check`.
- `src/rule-text.ts` — a record as one sentence.
- `src/client.ts` — `CliClusterClient`: the real `ssh`/`ping`/`pvesh`/`qm`
  shell-out FFI. Inspection + gate logic depend only on `ClusterClient`, so unit
  tests inject `FakeClusterClient` and never touch SSH.
- `src/main.ts` — verb dispatch, option parsing, table/JSON rendering, entry guard.
- `src/emit.ts`, `events.ts`, `ack.ts`, `emit-read.ts`, `emit-verbs.ts`, `emit-cmdb.ts` — the
  emitting half; see below. The CMDB is behind `HealthCmdb`, so the unit tests run on a stub.
- `src/notices.ts` — the critical-root mail: notices opened and closed from the root-cause set.
- `src/windows.ts` — the maintenance windows (the files the alert receiver reads too).

## The emitting half

- **What changed is read from the attribute's periods**, not from `since`: two transitions between
  runs, and a condition that went away, leave no trace in the current value. Reading every
  object's history per run would be a request per object, so `candidates` picks those with a
  recent `since`, a different status set from the object as of the cursor (`at`), or flapping.
- **The cursor is a change id**, because a report's time is when its run began: a slow `assess
  --only` can commit behind a time cursor that a faster run has already moved. Reports from two
  overlapping assess runs can still commit out of id order; that window is one transaction. The
  cursor also keeps the root set told, the critical-root notices open and the windows told open.
- **Flapping counts intervals, not transitions.** Nagios's percentage is of results that changed,
  and the history holds changes only, so "the last 20 transitions" would always be 100 %. Twenty
  intervals give the same ratio, with `health.assessInterval` as the check period, and let a
  condition stop flapping with no further transition.
- **One writer per attribute.** assess alone writes `conditions`. The ack verbs write the object's
  `acknowledgements` (per condition type the operator's last word, an ack or none, with its time),
  emit writes `flapping` (per type the status held while it flaps). assess takes a word newer than
  the one a condition last took (`operatorAt`), keeps the ack's lifecycle (its `until`, a status
  change for a plain ack, ok for a sticky one), computes a root's ack onto its impacts (`via`), and
  projects flapping, so every reader reads one shape. An ack made during an assess run is written
  to an attribute that run does not write, so it is never lost; it shows on the condition at the
  next run.
- **Every write is an assessment** (`assessment: true`, the object by id): no sighting, so it
  neither holds off a CI's expiry nor revives an unseen one.
- **assess ends an ack**, so emit sees it gone rather than ending: `endedBeforeEmit` compares with
  the objects as of the cursor and tells the `unack` (expired, recovered, changed). An unack by the
  verb told its own event.
- **The critical-root mail follows the root-cause set** (`notices.ts`). A notice opens when a
  critical root that is not silenced enters the set, whether or not its own status changed, and
  closes when it leaves, for any reason, saying which: recovered, eased, no longer checked,
  retired, acknowledged, in maintenance, now a symptom. emit plans them; `runEmit` delivers them
  through `site-notify.sh` (`--key health-root:<ci>:<type>`, `--resolve` for the close, so the
  RESOLVED threads under its ALERT) before the cursor records them, and one that did not go out is
  tried again on the next run. A flapping root holds its notice. Not a notice of its own: a
  warning, a performance root, a module's CVE level (cve-level-up mails it), a zone's score.
- **Maintenance windows** are files (`windows.ts`); emit tells one opening and ending from the
  cursor's list.
- **What stays a log rule** is matched on the line, so keys keep their order: the digest reads
  `"to":"warning"…"kind":"causal"…"silenced":false`, a performance root's `digestOnly` after
  `silenced`; `emit.test.ts` runs the rule file's matches against `eventLine` output.

## Assess: what is expected, what is derived

ADR-041 D2 and D3 decide the what. The decisions under them:

**Who may take a failure back.** A condition has one writer but several sources.
Each condition stores its `owner` (the gate or source that raised it; `derive`
for what derivation computes). `settle()` applies one rule: a failure recovers
only when its owner ran and looked at that object. So a gate reports `judged`,
the objects it actually reached; without that, a guest that stopped answering its
disk probe would turn green. Skips are no judgement: below ok among findings. A
condition stored before the owner was gets it from its reason.

**Ageing.** When the owner looked and has nothing to say, a failure is over (ok)
and an ok or unknown it no longer gives is dropped: absent reads as ok. When the
owner did not look, the judgement holds for its interval (an hour; the sweep 49
hours; the scan its staleness plus a day; a failure at least a day) and is then
`unknown`, "not checked since …"; an unknown nobody looks at for a week goes. An
ok stored before the owner was, that nothing gives now, is dropped at once. A
threshold or observation over an object no source has reported for 48 hours (its
`seen`, its `lastSeen`) is `unknown`, "not observed since …".

**What derive computes is computed again, whole.** Impact, roll-ups and follows
(owner `derive`) are dropped before `settle`, and their message is recomputed
every run; one that was failing and is no longer produced is written once as ok.

**The engine and the records.** `src/derive.ts` is one engine, the same on every
site. At each point where it decides something about a particular node, edge or
condition it asks the health records (`lib/ts/src/health-records.ts` holds the record,
the match language and the check; the core records are
[`metamodel/health/`](../../controller/cmdb-controller/metamodel/health/README.md)):

| Stage | The engine does | The records decide (kind) |
|---|---|---|
| Spread | builds the graph from the relations and computes the least fixpoint of "what reaches what" | `propagate`: whether and as what a failure crosses an edge. `combine`: how edges that back each other up count together |
| Roots | finds which failing conditions another explains, which stand as roots, and counts impact | `explain`: which arriving failure explains (derived) or covers an own condition |
| Follow | colours what nothing judges | `follow`: whose colour it takes |
| Roll up | sums collections and places from a snapshot of the stages above | `rollup`: who the members are and how they are summed |

For one decision several records may match. A record another matching record names
in `overrides` is out; so is one another matching record is strictly more specific
than. What is left agrees, or it is a conflict: `rules check` refuses the set, and if
one is ever evaluated the more severe outcome is taken, so the answer stays
deterministic. Layer and file order never decide.

**What holds whatever the records say.**

- *A critical is never the symptom of a warning.* A crossing carries two levels: the
  impact it gives and the level up to which it explains, which is the status it left
  its provider with, capped by its root's own status. A root is covered only by an
  impact whose root is at least as severe as the impact and as the condition covered.
- *Only the owner clears.* The engine never turns a failure into ok.
- *Matches read inputs only* (classes, attributes, relations, the condition crossing),
  never what was derived, and records only add states. So the spread ends and has one
  answer, whatever order objects, relations and records are visited in.
- *Rules do not invent edges.* A failure travels only along a relation in the CMDB.
- *Groups.* A `combine` record groups relations (by an edge attribute such as
  `redundancyGroup`, or every matched relation into one dependant) and gives steps:
  "one down: a warning", "all down: the failure itself". A member is down when a
  provider on that relation, other than the dependant, is failing. The message names
  the earliest failed member. A group's verdict never explains its own failed members,
  and a group whose verdict can reach its own members counts them from a run without it.

**Expected or derived.** A failing condition is **derived** when a failure reaches its
object and an `explain` record says it explains it there (shipped: a failure of the same
type, up to the level above). It does not count and is never a root. A failure of its
own on an object a critical reached is **covered**: still its own, but not listed or
mailed as a root while that stands (shipped: any critical covers).

**Cycles.** `connects` has no direction, so both ends of a dead cable reach each
other. Of two that reach each other the earlier `since` is the root.

**Roots.** A root is a failing, non-derived condition that is not covered. Roots are
ordered critical first, then by what they impact, then by `since`. An object reached by
several roots names the one that gave its worst status. A zone's and an environment's
CVE score is their own (an `own` roll-up record): derived, never a root. There is no
common-ancestor rule: a standing warning on a machine was made the root of unrelated
stopped guests by it.

**Roll-ups** read their members from a snapshot taken before any roll-up, so a room
counts its rack's own conditions, never the rack's sum. A roll-up never
replaces an impact the spread gave (a cluster that lost quorum keeps saying so).

**A group fed by its own verdict.** Where a group's verdict can reach its own members
(the quorum: a cluster's failure travels back to its nodes), the crossing a group gave
carries the members that counted as down for it, and is no impact on, explanation of
or cover for them; and the group counts its members from a run with such groups
switched off, so a member the verdict took down is not counted as a cause of it. On a
site with no such group this costs nothing: there is one run.

**Maintenance windows** cover what the records say (`src/windows.ts`): the object a
window names whole, and on each object a simulated `operational critical` failure of it
reaches, the conditions that failure would explain or cover there. One extra spread
per object an open window names, with nothing else failing, so a second fault that the
window did not plan for is still heard.

**What a finding becomes** (`src/classify.ts`), before settle: each failing finding is
matched against the `classify` records (its source, type, status, reason, labels and age,
and the object). The winner may re-rate it (the condition keeps `raw`: the source's
status, since when the source has said it, and the record; `finding.age` reads that
since, so an age-based raise never resets its own clock), mark it a sum of others
(`aggregate`: derived from the start, never a root), or quiet it (`quieted`: kept with the
source's status, silenced like an acknowledgement without an end, and the impacts whose
only root it is are quiet with it). An ok or unknown finding is never touched, so only
its owner ever clears a condition.

**How a root is told** (`src/notices.ts`): the engine still decides who can be told (a
failing root of its own, nothing silenced); the `notify` record that wins for the root's
object and condition says at once, in the digest, or not at all. With no installed set,
emit uses the core notify records, kept equal to `notify.json` by a test.

**Where the records come from** (`src/rulestore.ts`). The engine reads
`config/health/rules/` (before the first merge, the core records of the release).
`rules merge` compares, per origin and per rule id, what was last installed
(`base/`), what is released now and what is installed, and never changes a rule the
site edited or brings back one it deleted; the merged set is checked, a released
rule that conflicts with a local one is held, and a module's rule must name the
module at one end and has its reach measured by simulation. The verbs
(`src/rules-verbs.ts`) change the installed set on a fresh copy, check it, run the
contract scenarios and show the difference on the site before `--apply` writes. A
changed active set runs assess and emit at once; emit marks that run's transitions
`cause: "rules"` (by the site's `assessment.rules.hash` against its cursor's) and
keeps them out of the flapping count.

**Tracing.** Every derived condition carries `rule`: the record behind its crossing,
explanation, follow or roll-up. With `trace` on (`rules explain`), the engine also
keeps the crossings, the record and step behind each, and the records that matched
and lost each decision.

**Dependency cycles.** A cycle over required relations makes one failure reach
everything on it and come back. `rules check` reads the CMDB's relations for them,
and the sweep lists each as a difference.

**What the CMDB cannot place** lands on the site, naming its subject (`module
ghost: …`). A guest the cluster runs and the CMDB does not have is a `drift`
warning (`not-in-cmdb`), not a site outage.

**Maintenance.** The open window that covers an object (`windows.ts`: the site,
or what a window names and what runs on it) is the `maintenance` of every one of
its conditions; nothing carries a window over.

**Why `validate` keeps a stored table.** The console and scripts read each gate's
rows, with detail no condition keeps (one condition per type per object, so two
gates feeding `capacity` merge). The last run's lines go on the `site` object as
`assessment`, whose members are volatile and never history; the verdict is the
conditions'.

**History.** `conditions` is one attribute, so any change but `lastChecked` opens
a period. The store compares without the members marked `volatile` and rewrites a
value that differs only there, which is why an unchanged site costs no rows.

## Performance and trend capacity (ADR-046 D6, `assess-performance.ts`)

`assess` reads the metrics store (logging's Prometheus on :3121, its trends under `/trends/`,
the mothership's admin credential on curl's stdin; `metrics-read.ts`) when logging and the
credential are here.

- **`performance`**: each signal of `lib/ts/src/perf-signals.ts` with a threshold for the CI's
  class (D6's defaults: pool write latency, guest CPU pressure — the steal it sees —, memory and
  I/O pressure of guests and nodes, a route's p95 and 5xx ratio), a foundation module's declared
  `performance.thresholds` over them on its guest and its routes. A level is entered once held
  for the whole window (`min_over_time` over `for`) and left once under it for the window
  (`max_over_time`). Reason `perf-<signal>`; a CI measured before with no numbers now is
  `unknown` (`perf-no-numbers`), never critical. A store that does not answer judges nothing,
  and what this source set stands (owner `performance`, not looked).
- **trend `capacity`**: pools (Proxmox's storage numbers, by node and storage name), backup
  datastores (PBS's) and node memory, "full in N days" from the last 7 days' slope; within the
  site's `performance.capacityHorizonDays` (14) a warning (`capacity-trend`), beside the usage
  thresholds.
- **correlation**: two core `propagate` records cross a pool's performance warning or critical
  over `stored-on`, and a node's over `runs-on`, as a `warning` impact.
- **mail**: a performance root is no critical-root notice of its own; its transition carries
  `digestOnly` after `silenced`, so the daily digest's match takes it; symptoms are never mailed.

## State it reads

- **Module config** `config/<module>.json` (vmid, node, zone, diskSize, vmname,
  location, the `status` field — `archived` / `external` / implicit-active).
- **Node records** `config/<node>.json` — the `pvehost` instances are the cluster
  node list (with a `tappaas1..9` scan fallback).
- **Zone config** `config/zones.json` — for the NIC-drift VLAN mapping (consumed
  by the deferred NIC follow-up, not the scalar diff in this pass).
- **The git source JSON** (via the module's `moduleSource`) for the Released column.
- **Live cluster state** via Proxmox over SSH.

## How it talks to the cluster

Directly over SSH to the Proxmox nodes (`root@<node>.mgmt.internal`), with `ping`
reachability probes against the cluster's node list (the `pvehost` instances). `pvesh get
/cluster/resources` enumerates VMs/CTs; `qm config` / `qm status` give live VM
detail; the disk gate SSHes to the guest (`tappaas@<vmname>.<zone0>.internal`)
and reads `df /`. It drives no control-plane controller.

## Testing

- **`test.sh`** keeps the fast bash smoke (every `*.sh` parses + resolves on
  `PATH`) and adds the TS unit tier: `tsc --noEmit` on `src` and the unit
  tsconfig, then runs the offline unit suite.
- **`test/unit/inspect.test.ts`** — offline unit tests (no SSH, no Proxmox) with
  an injected `FakeClusterClient`: cluster classification, the three-way `show vm`
  drift levels, the `--diff` rollup (managed-only, unreachable degradation), the
  health gates (pass/fail/skip), and the node source (the `pvehost` instances). 23 assertions,
  no deep/live tier (the live tooling has no self-contained disruptive test).

## Deferred follow-ups (coordinator-approved, TODOs in source)

- **NIC-drift rows** (`show vm` / rollup): port `cluster/lib/vm-net.sh`
  (`vmnet_parse` / `vmnet_resolve_trunks` / `vmnet_zone_vlantag`) for the
  bridge/zone/VLAN/trunks/MAC rows + the `ALL` trunk-sentinel expansion; HANode /
  description rows fold in here.
- **Nested-config normalizer** — the bash `normalize_module_config`
  ("Pattern A → flat"); the TS port reads flat keys only for now.
- **`cluster` / `node` entities** — ADR-007 lists them alongside `vm`; entity
  model TBD.
- **Guest-agent liveness** — extend `service-liveness` with `qm guest cmd <vmid>
  ping` beyond `pvesh` running-state.
### How a guest rebuild classifies its own failure

`update-os.sh` retries a rebuild **only** on a lost connection; every other exit is
`nixos-rebuild`'s own deterministic verdict, and retrying it repeats the failure under a
misleading connectivity banner.

| exit | meaning | what happens |
|---|---|---|
| 0 | activated | done |
| 255 | ssh lost the connection | probe, then retry (up to 3) |
| 124 / 137 | **our** ceiling (`REBUILD_MAX_SECONDS`, default 3600) fired | treated as 255 |
| anything else | the configuration was rejected — including exit 4, units that failed to reload | fails immediately, no retry |

Two things make that work rather than hang (#720). The rebuild's ssh carries
`ServerAliveInterval=30 ServerAliveCountMax=6`, because `ConnectTimeout` bounds only the
handshake: once connected, ssh waits for a peer that is never coming, and a `switch` restarting
sshd or dbus-broker is exactly how the peer stops coming. That stranded one guest for 93 minutes
with no output, the retry unreachable because the attempt never ended. Keepalives turn the silence
into a 255 within ~3 minutes, which is the case the retry already handled.

And before calling a lost connection a failure it asks the guest what is activated, comparing
`/run/current-system` against its value before the attempt. In #720 the remote had already printed
*Done. The new configuration is …* — the switch had succeeded and only the connection was lost, so
"done, connection lost" is the correct verdict, not "failed". `/run/current-system` is the right
signal because a switch that reached activation moves it; comparing the running nixpkgs revision
instead would lie whenever the guest was already on the pinned revision and only its config
changed.

- **Full `update-os` TS port** — today the verb pass-throughs to `update-os.sh`.
- **`install.sh` → nix build** — link the compiled `health-manager` bin (kept on
  the `.sh` link path for now).

## The security scan (`security.ts`, ADR-011 v0.3)

`scan security` is three steps over one I/O boundary, `SecurityIO`, so the unit
tests run it whole against canned probe and scanner output:

1. **Probe.** One POSIX script (`LINUX_PROBE`) for every Linux target, over three
   transports — `sh -s` on the mothership, `ssh tappaas@<guest> sh -s`,
   `ssh root@<node> pct exec <vmid> -- sh -s` for an LXC. It prints the closure
   (NixOS) or `os-release`/`debian_version`/dpkg status (Debian), then one line
   per running container with its registry digests, then `@@end` — output
   without the marker was cut short and fails coverage. The firewall runs
   `OPNSENSE_PROBE` (`pkg query`, `pkg audit`, `pkg upgrade -nU`) with its own
   key; `-U` keeps the catalogue as OPNsense last fetched it, so nothing on the
   firewall changes.
2. **Inventory.** Store paths → components (`parseStorePath`: the version starts
   at the first segment that begins with a digit; trailing output names and
   API-level directories such as `dbus-1` are dropped). One `nix-instantiate`
   for every Nix package name on the site maps names to
   `meta.identifiers.cpeParts`; a name nixpkgs gives no vendor keeps
   vendor = product and says so (`tappaas:cpe-source`).
3. **Match and judge.** grype for Nix (CPE, no fix-state → *triage*), trivy for
   Debian roots rebuilt in a temp dir and for images by digest, `pkg audit` for
   OPNsense. `summarize` applies VEX, counts unique CVE ids, checks coverage and
   picks the verdict. `diffScans` against the previous status sets `new` and
   decides the notice.

The scan writes nothing but `config/sbom/`; its exit code is non-zero only when
every target failed (a scan with findings has succeeded). The scanner databases
are updated once per run, before any target is matched; a database that cannot
be fetched and is too old fails the targets that need it, through coverage,
rather than reading clean.

