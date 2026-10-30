# ADR-041 — Health in the CMDB, Root Cause and the Health View

| | |
|---|---|
| **Status** | **Accepted** (operator, 2026-10-30; O3, O5 and O6 still open) |
| **Version** | 1.2 |
| **Date** | 2026-10-30 |
| **Author** | Lars Rossen |
| **Deciders** | @LarsRossen, @ErikDaniel007 |
| **Closes / addresses** | #908. Amends ADR-007e (Health as a lens: the lens now reads and writes the CMDB), ADR-040 D10 and D11 (the `health` attribute becomes conditions; the Operations view becomes the Health view), ADR-039 D8 (open alerts are one source of a condition). Related: ADR-034 (console), ADR-031 (the pulse), ADR-011 (the CVE scan), ADR-017 (the update sweep's capacity checks), IT4IT 3.0.1 Event (§9.2.3.1: Type causal or symptom, Is Correlated) and the Configuration component's duty to "calculate and provide the business impact of the Event". |
| **Changelog** | v1.2 (2026-10-30) — **D5 redesigned (operator):** the one-graph-of-everything did not work in practice; the Health view becomes a containment tree, an ego graph one hop deep with plus/minus expansion, and the CI panel. · v1.1 (2026-10-30) — **critical roots only (operator):** `HealthRootCause` mails a critical root at once; warnings and the sweep's findings go to a daily digest rule (D4). · v1.0 (2026-10-30) — **Accepted** by the operator with O3, O5 and O6 open. O1: no hardcoded propagation — the rules are data, per relation type and class (D3); O2: the interval is a site setting (D2); O4: an acknowledgement on a root cause covers its symptoms (D4). Implementation starts on the plan below, on the `adr-040` branch. · v0.1 (2026-10-30) — first draft, from the operator's direction of 2026-10-30: health is stored on every CMDB object as several conditions; health-manager is split into an assessing half that writes them and an emitting half that raises events and answers questions; root causes are derived along the CMDB's relations and the console's new Health view centres on them. |

Health in TAPPaaS today is a verdict computed on demand and forgotten: `health-manager validate`
runs its gates against the live cluster, prints a table, exits 0 or 1, and the console caches the
table for ten minutes. Nothing records that a guest was short of memory for three days, nothing
says that six warnings are one broken switch, and the site has one health, not one per thing.
With the CMDB (ADR-040) every object the site has is a row with history and relations. This ADR
puts health on those rows — several conditions per object — derives which failures are causes and
which are their consequences, and gives the console one view that shows the site as a graph
coloured by health and centred on what is actually wrong.

## Context

### What health-manager is and keeps today

health-manager (ADR-007e, ADR-007f) is a read-only lens: it owns no config domain and reconciles
nothing. `validate` runs thirteen **gates** — service-liveness, disk-threshold, memory-commitment,
guest-memory, backup-status, pending-reboot, site-timezone, quorum, lan-uplink, ipv6-egress,
switch-ports, pulse, cve-status, and since ADR-039 open-alerts — each a read of a plane with a
verdict PASS / WARN / FAIL / SKIP, and exits non-zero on any FAIL. `capacity` answers whether an
install fits; `scan security` and `report security` are the CVE side (ADR-011); `alerts` lists
what Grafana holds open and what the alert receiver recorded in the last day; `update-os` and
`reboot` are two delegated actions.

**It stores nothing of its own.** The only state it writes is the CVE scan's
`config/sbom/cve-status.json`. What it reads as state belongs to others: Grafana's firing alert
rules on the logging VM (open state alerts), the alert receiver's `/var/lib/tappaas/alerts.jsonl`
on the mothership (event alerts, 24 h), the pulse's `--status`, PBS's job list. A gate's verdict
exists for the length of one `validate` run and in the console's cache; the Overview and the
Backup page show the last table. There is no history ("when did this start"), no per-object
record ("is nextcloud healthy", other than by reading every gate's rows), and no relation between
verdicts: a node down produces a failed service-liveness row per guest, a pulse warning, a backup
warning, and three mails, none of which says "the node".

ADR-039 gave the site a second health source — Grafana rules over Loki, per module, mailed as
ALERT/RESOLVED — and D8 let health-manager read them back. ADR-040 D11 then gave every CI a
`health` attribute written by health-manager "after each validate", and a sweep that marks drift.
That is three partial answers; this ADR makes them one.

### What the industry does

Surveyed 2026-10-30 from each tool's documentation:

| Tool | Health model | Dependencies and root cause |
|---|---|---|
| **Zabbix** 7.x | a *problem* per trigger, severity 0–5, tags; a *service tree* whose leaves bind to problems by tag, parents by rules (most critical of children, N or N % of children at a status, weights), with per-child propagation (as is, raise, lower, ignore) | a problem is a *cause* or a *symptom* of exactly one cause — **classified by hand**; automatic correlation is an open request (ZBXNEXT-10449); symptoms are not closed with their cause |
| **Icinga 2** | one state per host or service, hard after `max_check_attempts` | `Dependency` objects (parent, the parent states that satisfy it, `redundancy_group` OR-ed, otherwise AND); a child whose required parent is down is **unreachable** and its notification suppressed; transitive. *Dependency Views* (2025) draw the map and show the root problem at the top of each affected object — behind a paid subscription |
| **Checkmk** BI | an aggregation tree: leaves are host and service states, inner nodes rules — `worst`, `best`, `count_ok` with thresholds | upward roll-up only; parent scan and a topology map (2.3) beside it |
| **Nagios / Naemon** | host and service states | `parents`: a host behind a down parent is UNREACHABLE, not DOWN; flapping from the last 21 results, newest weighted higher, start above 30 % changes, end below 25 % |
| **Keep** | alerts with a service topology | groups alerts of services in one application within a 15-minute window into one incident; no root ranking |
| **Alertmanager** | alerts with labels | `inhibit_rule`: mute targets while a source fires and the `equal` labels match; mutes, never resolves |
| **Kubernetes** | `status.conditions[]`: `{type, status True/False/Unknown, reason, message, lastTransitionTime}`, one per type, absent is Unknown, a summary `Ready` | — |
| **IT4IT** 3.0.1 | Event with *Type* causal or symptom, *Is Correlated*, Event to Event n:m | the Configuration component "shall calculate and provide the business impact of the Event" |
| Dynatrace, ServiceNow (reference) | Smartscape / CI relationships | walk the topology, rank root-cause candidates by impact; impact rules per relation kind (cluster member, infrastructure dependency, network path) |

Three things stand out. The model for *several kinds of health on one object* is Kubernetes'
conditions, and nothing else has it: the monitoring tools have one state per host or service.
Root cause done by hand (Zabbix) is the thing operators give up on; done from a dependency graph
(Icinga, Nagios, Dynatrace) it is deterministic and cheap, and TAPPaaS already has the graph. And
every tool emits health the same way: one event per state transition, with the previous and the
new state, plus separate events for acknowledgement, flapping and maintenance windows.

## Decision

### D1 — Health is a set of conditions on every CMDB object

Every object in the CMDB (a CI, a resource, a place) carries **`conditions[]`**, one per *kind* of
health, in the shape Kubernetes gives a resource's `status.conditions`:

```json
{ "type": "operational", "status": "critical", "reason": "guest-stopped",
  "message": "VM 130 is stopped on tappaas2", "since": "2026-10-30T02:14:00Z",
  "lastChecked": "2026-10-30T08:00:00Z", "source": "health-manager",
  "derived": false, "rootCause": null, "acknowledged": null }
```

| `type` | Asks | Fed by |
|---|---|---|
| `operational` | is it up and doing its job | the liveness gates, Grafana's open alerts (ADR-039), the pulse (ADR-031), the switch and AP controllers' port and client state, PBS job results |
| `drift` | is it what its desired record says | the discovery sweep (ADR-040 D15: desired vs actual, actual-without-desired, desired-without-actual) and `validate`'s drift |
| `capacity` | is it running out of room | disk-threshold, memory-commitment, guest-memory, a pool's usage, a datastore's usage, PoE budget |
| `security` | is it exposed | the CVE scan (ADR-011), a certificate near expiry, an unexpected open port, a changed root key or firewall certificate (the ADR-039 rules that say so) |
| `maintenance` | is something waiting on the operator | pending-reboot, a timezone off the site's, a backup key not escrowed, a faulty asset (ADR-040 D7's flag) |
| `backup` | is it protected | backup-status, restore points' age, the buddy's last pull |
| `impact` | is it hurt by something else | **derived** (D3): never set by a source |

`status` is ordered, not boolean, because the view needs a severity: Kubernetes' True/False/Unknown
would lose the difference between a disk at 85 % and a disk full.

`status` is `ok`, `warning`, `critical`, `unknown`, and a condition may be in **maintenance**
(a window the operator set, or the update sweep's own, during which transitions are recorded but
neither mailed nor counted). `since` is when the status last changed, not
when it was last confirmed, so "how long has this been so" is a read. An object's **worst
condition** is its colour (D5); `unknown` ranks between ok and warning and is shown as grey, not
hidden, because an object nobody can assess is a finding. The old gates stay as the *checks* that
feed conditions; a gate's row becomes the condition of the object it was about (a guest, a node, a
pool) rather than a line in a site-wide table. The site's own health (the `site` CI's conditions)
is the roll-up of D3.

`conditions` is an attribute like any other in the store (ADR-040 D13): every change of `status`
opens a new validity row, so the history of an object's health is its attribute history, and
"what was unhealthy last Tuesday" is a query. The transitions are also events (D4).

### D2 — health-manager is split: assess writes, emit tells

health-manager keeps its name and stays a lens (it owns no desired record), but its inside is two
halves with one direction of data flow between them:

**`health-manager assess`** — the calculating half. It gathers what the sources know and writes
conditions to the CMDB; it is the *only* writer of `conditions` (through the controller's API,
like any reporter). It:

- runs the checks (the gates of today, each now naming the object it judged by class and name);
- reads the open alerts from Grafana and the receiver's record (ADR-039 D8) and turns each into an
  `operational` or `security` condition on the CI the rule is about (a rule's `module`, a host
  resolved to its instance, a node to its `pvehost`) — the alert's label carries the CI id (ADR-040
  D14), so no name matching is needed where the source speaks OpenTelemetry;
- reads the last sweep record and sets `drift` on every object the sweep listed;
- reads the controllers' observations already in the CMDB (a port's link, a client's signal, a
  datastore's GC, a pool's used) and applies thresholds to them — these are *not* re-read from the
  plane: the CMDB is the source, which is why the sweep had to exist first;
- then **derives** (D3): impact, root cause, the roll-ups;
- writes every condition whose status or reason changed, with `since`, in one report to the CMDB
  (an unchanged condition only moves `lastChecked`, which is volatile and never history).

It runs from `health-assess.timer` every `health.assessInterval` minutes (a `site.json` setting,
default 5; a one-box site may set 15), after every `cmdb sweep`, and when the alert
receiver gets an ALERT or RESOLVED (the receiver already runs on the mothership; it calls
`health-manager assess --only <ci>` for the one object). One run is a few seconds: everything it
needs is in the CMDB or a cached plane read; it never polls what the sweep polls.

**`health-manager emit`** — the telling half, and the read side. It never computes health; it
reads conditions and their history from the CMDB and:

- emits one **health event** per condition transition (D4) to the journal — the stream Loki holds
  and ADR-039's rules and the alert receiver act on — and to the console's change stream;
- answers questions: `health-manager show <ci>` (its conditions, since when, its root cause or
  what it impacts), `health-manager list [--type drift] [--status critical] [--class vm]
  [--root-causes]`, `health-manager history <ci> [--since]`, `health-manager roots` (the
  current root causes, each with what it impacts), and the existing `alerts`;
- keeps **`health-manager validate`** as the one-shot verdict scripts and the update sweep rely
  on: it is now a read (exit 1 when any `critical` condition is not derived and not acknowledged),
  with `--live` to run `assess` first, so a cold site still gets the old behaviour.

`capacity`, `scan security`, `report security`, `update-os` and `reboot` stay as they are; `scan
security` becomes one more source `assess` reads.

### D3 — Derivation: impact and root cause along the relations

A failure travels along the CMDB's relations, and the direction is known per relation type
(ADR-040 D3's table). **How far it travels is not hardcoded:** the propagation is a set of
**correlation rules**, data beside the metamodel (`metamodel/health-rules.json`, in the shape of
ADR-020's declarations and extensible by a module the way classes are, ADR-040 D3): each rule
names a relation type, optionally the class on either end, the source condition type and status
that triggers it, and the impact status it produces — the shipped set says a `critical`
`operational` condition crosses `runs-on`, `depends-on`, `member-of` and `connects` as `critical`
impact, and a `warning` crosses nothing; a site or a module can add that a `warning` on a
`machine` becomes a `warning` impact on its `vm`s, or that a `capacity` warning on a
`storage-pool` reaches the guests whose disks are on it. `health-manager rules list|check` shows
and validates them. Two words are added to the relation types that carry dependency:
**`required`** (the default for `runs-on`, `depends-on` and `allocated-to`; false for a relation
that only informs, such as `backs-up`) and an optional **`redundancyGroup`** — relations in one
group are satisfied while any one of them is healthy (a node with two uplinks, a service with two
providers), as Icinga's dependencies are. `assess` walks them in two passes:

**Impact (downstream).** For every object with a non-derived `operational` condition that is
`critical`, every object that depends on it gets an `impact` condition: `vm` → `runs-on` →
`machine` (a node down takes its guests), `service` → provided by a `vm` (a guest down takes its
services), `software` → `runs-on` → node, a module → `depends-on` → service (nextcloud without
`identity:identity`), `zone` → served by the `network` vm, `address` → `member-of` zone, port →
`connects` → port (a switch down takes what is cabled to it), `machine` → `allocated-to` an asset
marked faulty, `environment` → its zone and the vms in it, `user` → `member-of` group → the
environment's modules. The impact condition names its `rootCause` (the CI id) and carries the
reason ("node tappaas2 down"). An impacted object's own `operational` condition, when a check
would also mark it critical ("VM not running" — of course it is not), is marked `derived: true`
and does **not** count as its own failure: this is Icinga's *unreachable* and Nagios's *parent*
rule, applied over typed relations instead of one host tree.

**Root cause (upstream).** A root cause is an object with a non-derived `critical` or `warning`
condition that no object it depends on explains: walking its outgoing dependency relations
(`runs-on`, `depends-on`, `connects` toward the uplink, `member-of` toward the cluster,
`allocated-to` toward the asset) finds nothing failing. Everything else failing is a symptom of
one or more roots. Where two roots explain one symptom, both are listed; where several failing
objects share one ancestor that reaches all of them, that ancestor is the root even when it is
only `warning` itself (the lowest common ancestor of the failing set), and among candidates the
one whose transition came first wins — Dynatrace's ranking by impact, without the learning. The derivation is a
topological walk over the current relation graph, cheap at a site's size (a few hundred objects),
and is recomputed on every `assess`; no learning, no time windows: the site's dependency graph is
known, so correlation by cause beats correlation by time. Time enters only as a tie-breaker in the
event stream (D4): a symptom whose event precedes its root's by more than a check interval is
flagged, because that usually means a relation is missing in the CMDB.

**Roll-ups.** A `collection` (site, cluster, environment) and a `place` (location, room, rack)
carry the worst status of their members as a derived condition of each type, counted ("3 of 12
vms critical"), so the Overview's one line and the Health view's collapsed groups come from the
same rows. A roll-up is never a root cause.

### D4 — Health events: one per transition, typed causal or symptom

Every change of a condition's `status` is one event, written by `emit` as a structured journal
line (identifier `tappaas-health`) and sent on the console's change stream:

| Field | Value |
|---|---|
| `ci`, `class`, `name` | the object |
| `type` | the condition type |
| `from`, `to` | the statuses |
| `reason`, `message` | the condition's |
| `kind` | `causal` when the object is a root cause for this transition, `symptom` when it is impacted, `recovery` on a return to ok — IT4IT's Event *Type* |
| `rootCause` | the root's CI id on a symptom |
| `correlated` | the ids of the events this one is grouped with (the root's and its symptoms' in the same run) |
| `since`, `at` | when the status changed, when the event was emitted |
| `flapping` | Nagios's rule over the last 20 transitions, newest weighted higher: flapping starts above 30 % changes and ends below 25 %; while flapping, the status is held at its worse value and one `flapping` start and end event replace the storm |

Beside the transition there are four more event kinds, the set every tool has: `ack` and `unack`
(who, sticky or not, expiry), `maintenance` start, end and cancel, and `rootcause` (the root's id
and its symptoms' ids, written once per `assess` run that changes the set).

ADR-039's rules and the alert receiver work on these lines as on any log line, and the rule file
is where the operator says which events leave the site (ADR-039 D1): `HealthRootCause` mails a
**critical** root cause with the count of its symptoms, at once; `HealthRootRecovered` its
recovery; `HealthDailyDigest` collects warning roots and the sweep's unexplained differences
(ADR-040 D15: drift, new discoveries, unmanaged, missing) into one mail a day, none on a quiet
day. Nothing mails a symptom — which is how three mails about one node become one. An operator may **acknowledge** a condition (`health-manager ack <ci> --type … --until …
--note …`, a job from the console): the condition keeps its status but stops counting for
`validate`, mails and the Overview, and the acknowledgement is an attribute with history.
Acknowledging a **root cause** acknowledges its symptoms with it: every `impact` condition that
names the root is silenced for as long as the root's acknowledgement holds, and a symptom that
later gets a root of its own is heard again. A condition can also be acknowledged on its own.

### D5 — The Health view

The console gets a **Health** entry in its menu, under *Day 2 wizards* and above *Site*. v1.1
drew the graph of every CMDB object on one page; on the test site (349 objects, most of them
`unknown`) that is a wall of grey cards and crossing lines, and nothing can be found in it. v1.2
replaces it with the layout every CMDB browser has settled on (ServiceNow's dependency view,
UCMDB's topology map): **a tree to find the object, an ego graph around it, the details beside
it.** Three panes, one selected object.

- **The tree (left)** is a containment walk over the CMDB's relations, not a list written into
  the console. Three facets at the top level, each opened on demand and searchable:
  - **Physical** — the site, its locations, rooms and racks (`at`, `placed-in`), the assets in them
    (servers, network devices, appliances) with the `node` each is `allocated-to`, under a machine
    the guests that `runs-on` it and under a guest its `software`; under a network device its
    ports (`part-of`) and what each `connects`.
  - **Environments** — each environment, the nodes `member-of` it, their software and the
    services they `provides`; the zones that `serves` it.
  - **Identity** — organizations, the groups and environments `owned-by` them, users `member-of`
    groups.
  - Every tree node carries the **roll-up** of its subtree: the worst status as a dot, and a count
    of objects not ok, so a red dot on a machine says where to look before anything is opened.
    Which relation types are containment for the tree is data on the relation type
    (`metamodel/relations.json`, `tree: "children"` on the end that is contained), so a new
    class or relation joins the tree without a console change. The tree remembers what is open.
- **The ego graph (centre)** shows the selected object in the middle and its direct neighbours
  around it, laid out by dagre (the console's `graph.tsx`) and grouped by relation type (runs-on,
  depends-on, connects, member-of, contains…), so the picture has a shape at one hop. A neighbour
  with further neighbours shows a **plus**; a click expands one more hop from that node, a
  **minus** folds it. Two shortcuts expand along the derivation of D3: **to the root cause**
  opens the chain from the selected object to the root that explains it, **what this impacts**
  opens what fails because of it. Colours, badges and lines as before: red critical, amber
  warning, grey unknown, green ok, hatched acknowledged, dotted in maintenance, ↯ flapping; a root
  is ringed. The graph is small by construction, so it is readable on a phone.
- **The CI panel (right)**, unchanged from ADR-040 D10: conditions with their `since`, the root
  cause or what it impacts, drift against the record, the conditions' history, changes, relations
  both ways, and the verbs that apply as jobs (Ack, Unack, Maintenance; Reboot, Update, Reconcile,
  Reboot node where the class has them). "Show in tree" keeps the two sides in step.
- **Entry points.** The Overview's health line and its Attention list land on the root cause with
  its symptoms expanded; `/health?select=<id>` opens on one object; a healthy site opens on the
  site card with the one green line; a site that has not run `assess` gets grey dots and says so.
- **Filters** (condition type, class, environment) dim what they leave out in the tree and the
  graph; the time slider replays the colours from the attribute history (`health/graph?at=`).
- **Live:** the change stream patches colours in the tree and the graph without a reload; a new
  root cause is announced in the tree's roll-ups and the Overview, and never moves the selection.
- The Overview, the Backup page and the Modules list read the same conditions, so every page agrees
  with the view.

### D6 — What is not here

Incidents, problems, on-call, a SIEM's correlation, and a tool for the operator to work a ticket
remain the event-management ADR's (ADR-040 O6). This ADR gives that ADR its events (D4), typed and
correlated, and its root causes.

## Consequences

- Health becomes data with history, on every object, in one place; `validate` becomes a read.
- health-manager grows a timer and a second half; the alert receiver calls it; ADR-039 gets one
  rule for root causes and loses the per-symptom mails.
- The CMDB gains `conditions[]` and `acknowledged` on `object`, with `impact` as a derived type;
  `health` from ADR-040 D11 is replaced by migration.
- The console gets the Health view and the menu entry; the Overview, Backup and Modules pages read
  conditions.
- ADR-007e's "status on the thing it relates to" is finally literal: the status is on the thing.

## Alternatives considered

- **A1 — Keep the gates and add a page.** No history, no per-object health, no root cause.
  Rejected.
- **A2 — Adopt a monitoring system as the health engine** — Zabbix, Icinga 2 or Checkmk, fed
  the CMDB's objects as hosts and its relations as dependencies. Each is a VM with a database and
  a second model of the site to keep in step with the CMDB; Zabbix's root cause is manual, Icinga's
  dependency map is a paid add-on, Checkmk's BI rolls up but does not find causes; and every one
  of them probes the planes itself, a second poller beside the sweep. The CMDB already holds the
  observations and the graph; the derivation is a hundred lines. Rejected; their models are
  borrowed (conditions, unreachable, flapping, the event kinds).
- **A3 — Correlate by time** (Keep, Alertmanager's inhibition): group events in a window and
  call the earliest the cause. Needed where the topology is unknown; TAPPaaS knows it, and a window
  only adds latency and guesses. Rejected; time stays a tie-breaker.
- **A4 — One health per object, not conditions.** Simpler to show, but drift, capacity and
  security are different questions with different owners, and a single status hides which one is
  red. Rejected.

## Open questions

- **O1** *(closed 2026-10-30, operator)* No hardcoded propagation: correlation rules are data, per
  relation type and class (D3); shipped, a warning crosses nothing.
- **O2** *(closed 2026-10-30, operator)* A site setting, `health.assessInterval`, default 5 minutes (D2).
- **O3** *(closed 2026-10-30, operator: the recommendation)* Whether the gates move out of health-manager into the managers that own the objects
  (site-manager judging its nodes), with health-manager keeping only the derivation.
  **Explanation.** Today health-manager both *observes* (the gates ssh to nodes, ask Proxmox, read
  Grafana) and *judges* (a threshold, a rule, a severity), and is the one writer of `conditions`.
  Moving the gates to the owning managers would mean: site-manager judges its nodes and writes
  conditions on `machine` objects, module-manager on `vm`/`lxc`, network-manager on ports and
  zones, and health-manager only derives roots and roll-ups. *For:* the knowledge sits where the
  object is understood (site-manager knows what a healthy node is), a manager's verb can judge
  right after it changed something, and health-manager's 60 s assess shrinks to a derivation
  over what is already written. *Against:* several writers of `conditions` need one convention
  for severity, reason text, expiry and acknowledgement or the Health view becomes uneven;
  every manager grows a timer or a hook to re-judge, where today one schedule does it; a
  condition's source must still be named so the operator knows who said it; and the gates that
  cross managers (memory commitment over the cluster, a backup that covers a node's guests)
  have no single owner. A middle way exists and is the direction step 2 already takes: managers
  **report observations** (a port's link, a pool's used, a guest's balloon) into the CMDB as
  facts, and health-manager **judges them with thresholds** read from the CMDB, never from the
  planes. Then the only gates left in health-manager are the ones that need a live probe (ssh
  to a node for a pending reboot), and those can move one by one into the owning manager's
  `report --discover` as an observation. **Recommendation:** keep one assessor and one writer of
  `conditions` (health-manager), and move *observing* to the managers' reports, gate by gate,
  until assess is a pure judgement over the CMDB; revisit the split when that is done and
  assess takes seconds. **Decided:** one assessor and one writer of `conditions`; observing moves
  into the managers' reports gate by gate (plan step 2 is the first of it).
- **O4** *(closed 2026-10-30, operator)* Both: a condition on its own, and a root cause with its
  symptoms (D4).
- **O5** *(closed 2026-10-30, operator: (b))* How much of the graph the assistant (ADR-034 D7) may read to explain a root cause in
  words.
  **Explanation.** The assistant proposes and never applies (ADR-034 D7); here it only reads.
  To say in words why `identity` is critical it needs: the root's own conditions (type, severity,
  reason, since when), the symptoms the derivation hung on it, the objects one relation away
  (what it runs on, what depends on it, what it is in), the root's recent events and history,
  and the names of the desired records involved. It does not need the whole graph (400 objects
  and their attributes), configuration values, secrets, or the other roots. Three sizes: (a) the
  **root alone** — its conditions and symptoms list — enough for "identity is down since 09:12,
  authentik's health check fails, 7 services show it as their cause", cheap and safe but blind
  to *why*; (b) the **ego graph one hop**, as the Health view shows it, plus the root's last 24 h of
  events — enough for "identity runs on tappaas2, whose memory gate turned critical five
  minutes earlier; the other guests on tappaas2 warn too", which is what an operator wants;
  (c) **everything reachable**, which explains more cases but reads attributes an operator did
  not ask to share and costs tokens on every question. **Recommendation:** (b), through the
  same console reads the Health view uses (`health/ego` one hop, the root's `show` and
  `history`, `roots`), bounded to about 50 objects and 100 events, names and conditions only —
  no attribute values beyond kind, class and state, no `config/` contents — and the answer
  lists what it read, so the operator can check it. A second hop only on the operator's
  explicit follow-up question. **Decided: (b)** as described — the ego graph one hop and the
  root's history, bounded, names and conditions only, what was read listed in the answer.
- **O6** *(open, to discuss)* Which relations get `redundancyGroup` from the start: a node's bonded uplinks (ADR-019
  v1.1), MLAG peers, a service with two providers — or none until a site has one.

## Implementation plan

1. `conditions[]` and `acknowledged` in the metamodel; `assess` writing the existing gates as
   conditions on their objects; `validate` as a read with `--live`.
2. Sources beyond the gates: open alerts, the sweep's drift, thresholds over the controllers'
   observations, the CVE scan.
3. Derivation (D3): impact, root cause, roll-ups; `roots`, `show`, `list`, `history`.
4. Events (D4): `emit`, the journal lines, the ADR-039 rule, acknowledgements, flapping.
5. The Health view (D5): the graph, groups, root-cause centring, the panel, the menu entry;
   Overview, Backup and Modules on conditions.
6. The timer, the receiver hook, the migration from `health`.
