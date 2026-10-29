# ADR-040 — Asset Lifecycle and CMDB

| | |
|---|---|
| **Status** | **Draft** |
| **Version** | 0.2 |
| **Date** | 2026-10-29 |
| **Author** | Lars Rossen |
| **Deciders** | @LarsRossen, @ErikDaniel007 |
| **Closes / addresses** | #906. Amends ADR-036 D3 (who owns a placement, and what it hangs on) and D4 (the topology becomes a view of the CMDB); ADR-007f (a new controller, cmdb-controller, that every manager reports to); ADR-034 (the console's views read the CMDB). Related: ADR-020 (desired, actual and drift), ADR-022 family (the vocabulary of CI classes), ADR-022c (ArchiMate Node and Device), ADR-026 (machines as modules), ADR-028 and ADR-033 (releases), ADR-035 (manager rename and aliases), ADR-037 D4 (adding a node). |
| **Changelog** | v0.2 (2026-10-29) — **scope widened (operator):** from asset lifecycle to TAPPaaS's whole lifecycle along the IT4IT product backbone; the actual state of everything — assets, nodes, guests, module instances, services, zones, environments, people, the site — is a CMDB owned by a new cmdb-controller that every manager feeds; the Physical view and the assets are one view of it, filtered on `physical`; event management and the operations console relate to it. v0.1's asset decisions are kept as D7–D9. Title was *Asset Lifecycle*. · v0.1 (2026-10-29) — first draft, from #906. |

TAPPaaS knows well what a site *should* be: the modules and their dependencies, the releases, and
the desired configuration in `config/*.json`. It knows poorly what a site *is*: that is asked live
from Proxmox, the switches or the firewall at the moment a verb needs it, and forgotten again. A box
that plays no role is not known at all.

This ADR lines TAPPaaS's lifecycle up with the **IT4IT Digital Product Backbone**, from the idea of a module
to the thing that is running, and gives the last stage, the **actual** state, a home: a
configuration management database (**CMDB**), kept by a **cmdb-controller** that every manager
reports what it sees and what it changes to. A physical **asset** is one kind of object in it;
modules, guests, zones, environments, users and the site are others. The console's Physical view
becomes one view of the CMDB, filtered on `physical`.

## Context

### The product backbone, and where TAPPaaS keeps each stage today

The Open Group's IT4IT standard (3.0.1, October 2024) follows a **digital product** through its
**Digital Product Backbone**: a chain of key data objects, each with one owning functional component
and linked to the one before, so that anything running can be traced back to why it exists. IT4IT
2.1 called the same chain the Service Model Backbone (conceptual → logical → desired → actual
service); 3.0 names the states planning, development, consumable and running:

| Backbone object (3.0; 2.1 name) | Owning functional component | TAPPaaS today | Owner today |
|---|---|---|---|
| **Digital Product** (conceptual service) | Product Portfolio | the module catalog (`module-catalog.json`), each module's `dependsOn`/`provides`, the ADRs as its requirements, `ROADMAP.md` | the repository, by hand |
| **Product Backlog Item** (logical service) | Product Backlog | the module's design (`DESIGN.md`, `<module>.json`, `services/*/fields.json`) and Codeberg issues as its backlog items | the repository, Codeberg |
| **Product Release** and its blueprint (service release) | Release Composition | a module's `version`/`releaseDate` in its JSON, grouped into releases **per repository**: TAPPaaS's `release/releases.json` (the train, ADR-028), signed tags (ADR-033); the Community repository's own | tappaas-train, the repositories |
| **Desired Product Instance** (desired service) | Fulfillment Orchestration | `config/*.json`: the module instances, `site.json`, `zones.json`, environments, identities, `positions.json`, the switch configuration's desired file | the managers (ADR-020: validate, modify) |
| **Actual Product Instance**, with its CIs (actual service) | **Configuration** (system of record) | **nowhere as a whole.** Asked live (Proxmox API, OPNsense, Authentik, the switch controllers), joined on demand by `network-manager topology`, kept in two places only (`switch-configuration-actual.json`, the switch controller's last read); history only in logs | each manager, for the moment of one verb |

In 3.0 a Product Release has one or more Desired Product Instances; each Desired is paired one to
one with an Actual, which includes the CIs of what was built, each traceable to the Desired. The
Configuration component calculates an Event's business impact from those relations, and Events and
Incidents relate many-to-many to Actual Product Instances. The seven 3.0 value streams (Evaluate,
Explore, Integrate, Deploy, Release, Consume, Operate) replace 2.x's Strategy to Portfolio,
Requirement to Deploy, Request to Fulfill and Detect to Correct; this ADR is about the backbone, not
the streams.

The first four stages exist and are linked by name: a module instance names its module, the module
its version, the release its commit. The fifth is where operations happen, and it has no record:

- **No history.** "What was on `tappaas2` last Tuesday", "when did this switch port change VLAN",
  "which version of nextcloud ran before the update" are answered from logs, if at all.
- **No whole.** Each manager knows its own plane. Joining them (a node is down: which guests, which
  services, which environments, which users) is done again by every reader that needs it: the
  topology, the console, the alert receiver's node-down mail, the backup pulse.
- **No physical life.** The asset problem of #906: a box is known only while it plays a role as a
  node, switch or recorded device (see D7).
- **Drift is computed, not kept.** ADR-020's differ compares desired with a live read, reports and
  forgets.

### Events today

The logging module's Grafana rules turn log lines into alerts, mailed by the mothership's
`tappaas-alert-receiver`; health-manager checks the site; the backup pulse (ADR-031) watches the
buddies; switch controllers report ports. Each names what it is about in its own words: a host
name, a VMID, a node, a port. None can say what else is affected, because nothing holds the
relations.

## Decision

### D1 — TAPPaaS follows the IT4IT Digital Product Backbone

The five stages are TAPPaaS's lifecycle model, with one owner each and a link from each to the one
before:

| Stage (IT4IT 3.0) | TAPPaaS object | Kept in | Link to the stage before |
|---|---|---|---|
| Digital Product (the *conceptual product*) | a **module** in the catalog, with its dependencies; an **ADR** as a portfolio requirement | the repository | – |
| Product Backlog Item (the *product design*) | the module's design and its **backlog** (Codeberg issues labelled with the module) | the repository, Codeberg | the module |
| Product Release | a **module release** (the module JSON at a version), grouped in a **repository release** | the repository's tags and `releases.json` | module + version |
| Desired Product Instance | a **desired record** (`config/<instance>.json`, `zones.json`, …) | `config/`, by the managers | its module and the release the site runs |
| Actual Product Instance | its **configuration items (CIs)** | **the CMDB** (D2) | its desired record, where it has one |

Nothing in the first four changes owner or format. What is new is the fifth, and that every CI
carries the trace upward: a running guest → `config/nextcloud.json` → nextcloud 3.4.1 in TAPPaaS
2.4.0 → `src/apps/nextcloud` and its open issues → the ADRs it implements. The console shows the
trace (D10).

The conceptual and design objects (modules, ADRs, issues) are **not** CIs: they are linked, by
module name and issue number, and read from the repository and from Codeberg when shown, never
polled.

### D2 — The actual state is a CMDB, kept by cmdb-controller

The CMDB is not a JSON file. It has many writers at once, typed relations that are queried both
ways, a history of every change, and questions like "everything within two hops of this node"; a
file per manager cannot answer those, and one shared file cannot take concurrent writers. It is a
store behind a service:

- **cmdb-controller** is a controller in ADR-007f's sense, on `tappaas-cicd`, present from the
  bootstrap (the first node's asset is written at install, D8). It owns the store, the schema of
  CI classes and relation types, identity matching (D5) and history (D6), and offers one API: a
  TypeScript client in `lib/ts`, a CLI `cmdb` for the bash layer, and HTTP for the console.
- **Only cmdb-controller writes the store.** Managers and controllers send it observations and
  changes (D4); nothing else opens the database.
- **The CMDB is a record, never a gate.** A manager whose report cannot be delivered spools it and
  carries on; no verb fails because the CMDB is down. Desired state stays in `config/`; the CMDB
  never becomes the source of intent.
- **It can be rebuilt.** `cmdb rescan` asks every source again and recreates the actual state;
  what no source can see (the recorded facts of D7, and the history) is in the store's backup with
  `tappaas-cicd`'s.

### D3 — The CI model

Every CI has a stable `id`, a `class`, a `name`, the attribute **`physical`** (true for a thing you
can touch), a lifecycle `stage` (D6, D7), its `desired` reference (config file and key, absent for
what nobody declared), its `release` reference (module and version, for a module's CIs), its
`sources[]` (which manager or controller reported it, when last), `firstSeen` and `lastSeen`.

| Group | Classes | physical |
|---|---|---|
| Site and place | `site`, `location`, `room`, `rack` | location, room, rack: yes |
| Physical | `asset` (server, switch, access point, modem, ONT, UPS, patch panel, PDU, other), `port`, `cable`, `disk` (O4) | yes |
| Compute | `cluster`, `node` (a cluster member, ADR-022c), `guest` (VM, LXC) | no (the node's box is its asset) |
| Product | `module-instance`, `service` (`<module>:<service>`), `controller`, `manager` | no |
| Network | `zone`, `vlan`, `ssid`, `address`, `dns-name`, `proxy-route`, `vpn-peer` | no |
| Storage and backup | `storage-pool`, `share`, `datastore`, `backup-peer` | no |
| People and tenancy | `organization`, `group`, `user`, `role`, `environment` | no |

The classes reuse the names the ADR-022 family and `GLOSSARY.md` already fix; a new class goes
through the same gate as a facet (ADR-022h). Relations are typed, and each is reported by the
manager that knows it:

| Relation | Example |
|---|---|
| `runs-on` | guest → node; module-instance → guest; node → asset |
| `placed-in`, `at` | asset → rack / room; room → location |
| `connects` | port ↔ port (a cable, seen or recorded); port → ssid (Wi-Fi) |
| `member-of` | node → cluster; user → group; address → zone |
| `depends-on`, `provides` | module-instance → service (from `dependsOn`/`provides`) |
| `serves` | zone → environment; proxy-route → service |
| `owned-by` | environment → organization; asset → site |
| `backs-up` | datastore → guest; backup-peer → site |

### D4 — Every manager that looks or changes, reports

A manager that **interrogates** reports an **observation**: the CIs and relations it saw, their
attributes, its name as source, the time. A manager that **changes** something reports a
**change**: the verb, the job (the console's Activity id), the CIs it touched, before and after.
The table is the starting set; a module's own manager (ADR-035) reports the same way.

| Reporter | CIs it maintains |
|---|---|
| site-manager, proxmox-controller | site, cluster, nodes, guests, storage pools |
| asset-manager (was position-manager, D7) | locations' rooms and racks, assets, ports, recorded cables |
| module-manager | module instances, services, their release |
| network-manager, opnsense-controller | zones, VLANs, addresses, DNS names, proxy routes, firewall state |
| switch-manager, ap-manager (and the UniFi, MikroTik controllers) | switches' and APs' assets and ports, seen cables, seen devices, SSIDs, Wi-Fi clients |
| identity-manager, authentik-controller | organizations, groups, users, roles |
| environment-manager | environments |
| storage-manager, backup-manager, pbs-controller | shares, datastores, backup peers, restore points' existence |
| health-manager | the health status of each CI it checks (D11) |
| the installer's hook (ADR-037 D4) | a new node's asset: DMI serial, model, NIC MACs |

`validate` and `reconcile` already interrogate; they report as a side effect. The first step is that
every existing interrogation reports what it already reads; no new polling is added.

### D5 — Identity: one thing, one CI

The controller matches each report to an existing CI by the class's keys, strongest first:

| Class | Keys |
|---|---|
| asset | vendor + serial, then any port's MAC (D9) |
| node | Proxmox node name within the cluster, then its asset |
| guest | VMID + cluster, then the module instance name |
| module-instance | instance name (the `config/` file) |
| user, group | Authentik UUID |
| others | their name within their parent (a zone in the site, a port on its asset) |

Two reports that match one CI by different keys merge; a key that matches two CIs is reported as a
conflict, not guessed. A CI no source has reported for longer than its class's expiry is
`unseen`, never deleted silently; its removal is a change some verb made.

### D6 — History and drift are kept

Every attribute and relation is stored with the time it became true and the time it stopped
(valid-from, valid-to). "What did the site look like on 2026-10-20", "what changed on `tappaas2`
this week" and "what has this box been" are queries, not log searches. A change links to its job;
an observation that differs from the last one with no change behind it is **drift**, recorded on
the CI with its desired reference (ADR-020's differ supplies the comparison) and shown until the
next reconcile or modify clears it.

### D7 — An asset is a physical CI with a life of its own

What v0.1 decided for assets stands, now inside the CMDB:

- **Asset and role.** An asset is the physical thing (`physical: true`); a node, a machine module, a
  switch or AP in the switch configuration, a recorded device is a **role** it plays for a while,
  linked by `runs-on` (node → asset). A box keeps its placement, ports, cables and history when its
  role ends, and can take another (`tappaas3` deleted, the box becomes `tappaas5`).
- **Stages.** `ordered`, `stock`, `placed`, `operational`, `faulty`, `disposed`. `placed` and
  `operational` are derived (a placement and no role; a role); the others are recorded.
  Decommissioning is an event, not a stage: when a role ends, the asset falls back to `placed` or
  `stock`.

  | TAPPaaS | NetBox `DeviceStatusChoices` | netbox-inventory Asset | Snipe-IT status type | Ralph DC asset |
  |---|---|---|---|---|
  | `ordered` | `planned` | (purchase `open`) | `pending` | `new` |
  | `stock` | `inventory` | `stored` | `deployable` | `free` |
  | `placed` | `staged` | `stored` | `deployable` | `to deploy` |
  | `operational` | `active` | `used` | (checked out) | `in use` |
  | `faulty` | `failed`, `offline` | – | `undeployable` | `damaged` |
  | *role ends* | `decommissioning` | – | – | `cleaned` |
  | `disposed` | – (device deleted) | `retired` | `archived` | `liquidated` |

- **Recorded facts are observations too.** What no machine can see — an asset bought, on the
  shelf, its rack and unit, a cable to a modem, its purchase and warranty — the operator records
  through **asset-manager**, and asset-manager reports it with `source: recorded`. So
  `positions.json` goes: its rooms, racks, placements, recorded devices and cables move into the
  CMDB by migration. **position-manager becomes asset-manager** (and `position-manager`,
  `rack-manager` answer as aliases for one release, ADR-035 P2); ADR-036 D3's rule stays: no
  other manager records a room, rack or unit.
- **Procurement** (optional): supplier, order reference, purchase date, warranty until, ownership
  (`owned`, `rented`), notes. No prices.
- **Disposal** records how (`sold`, `recycled`, `returned`, `lost`) and, for an asset with disks,
  whether they were wiped.
- **Not an asset:** a rented VPS (a machine with a location, no asset), a buddy's box, parts inside
  a machine (O4). A rented dedicated server may be an asset with `ownership: rented`.

### D8 — Two ways in, one asset

**Asset first:** `asset add srv-07 --kind server --model hp/z840 --serial …`, placed and cabled;
then `site-manager node add tappaas5 --asset srv-07`, the switch port and MAC of ADR-037 D4 taken
from the asset's cabled port; `module adopt`, `switch-manager add-switch`, `ap-manager add` take
`--asset` the same way. **Role first:** a role added without `--asset` is matched by what the
installer's hook or the controller reports (D5); with no match an asset is created at the role's
location and the operator is told, so it can be placed. **Reuse:** a role on an asset that had one
before keeps everything but the role. Ending a role, unplacing and disposing are three acts;
`dispose` refuses an asset with a role.

### D9 — Ports belong to the asset

An asset's ports carry `name`, `kind` (`ethernet`, `sfp`, `wifi`, `bmc`, `usb`, `power`), `mac`,
`speed`; a patch panel's port has a front and a rear. A cable connects two ports (seen by the
switches or LLDP, or recorded). A node's `uplinks`, second lan leg and WAN port name ports of its
asset. The BMC is a port with its own MAC. A **Wi-Fi** port connects to an SSID, and through it to
the zone that SSID bridges to; the AP controller's client list reports it by MAC. A MAC is unique
across all ports, so a DHCP reservation or a pending node registration that names a MAC names an
asset.

### D10 — The console's views are views of the CMDB

The console (ADR-034) reads the CMDB for what *is*, and the managers' verbs for what to change:

- **Physical** (the Assets view): CIs with `physical: true`, by location, room and rack, with stock
  and ordered assets in a tray; a device panel is the asset's CI.
- **Modules, Environments, People, Site:** the same CIs in other cuts.
- **Topology:** `network-manager topology` keeps its verb and output, answered from the CMDB.
- **A CI's panel** shows its attributes and their sources, its relations, its history and drift,
  its open events (D11) and its backbone trace upward (D1): desired record, release, module and its
  open issues, ADRs.

### D11 — Events are about CIs; operations start from the CMDB

Events stay where they are made and stored (Loki and its Grafana rules, health-manager, the backup
pulse, the switch controllers; a SIEM later). What changes is that **each event names the CI it is
about** by its CMDB id, carried as a label (OpenTelemetry's `service.instance.id` where the source
speaks OpenTelemetry), and that the alert receiver and the console resolve it. This is IT4IT's
split: the Event component owns events, the Configuration component the CIs and the impact.

- **Enrichment:** an alert on host `nextcloud` is the guest CI, which runs on node `tappaas2`, in
  environment `home`, used by group `family`.
- **Impact:** a node down is one event on the node's CI; the CMDB's relations list the guests,
  services, environments and users behind it, instead of each reader working it out again (today
  the node-down mail does).
- **Health on the CI:** health-manager writes each CI's last health status; the CMDB keeps state,
  not the event stream.
- **Operations console:** the console gets an **Operations** view — open events by CI, with impact,
  and the CI's recent changes beside them, since the first question about an incident is "what
  changed".

Incident and problem records, on-call and a SIEM's correlation are **not decided here**; they are an
event-management ADR of their own (O6) that builds on CI ids.

### D12 — Build, adopt or borrow: build the controller, borrow the models

The candidates, checked 2026-10-29 (releases from the projects, NixOS support from nixpkgs master):

**CMDBs**

| Tool | Licence | Release | Stack | NixOS | Custom classes, typed relations | History | Fed by discovery over API | ITSM |
|---|---|---|---|---|---|---|---|---|
| **iTop** (Combodo) | AGPL-3.0 | 3.3.0, 2026-09 | PHP, MySQL | none | yes (XML data model, link classes) | per object | yes (Data Synchro) | incident, problem, change |
| **GLPI** | GPL-3.0 | 12.0.1, 2026-10 | PHP, MariaDB | agent only | asset definitions (since 11), impact analysis | log | yes, native inventory agent | helpdesk, problem, change |
| **CMDBuild** / openMAINT | AGPL-3.0 | 4.2, 2026-03; maintainer change announced | Java/Tomcat, PostgreSQL | none | the most flexible (classes, domains with cardinality) | yes | yes | workflow |
| **NetBox** | Apache-2.0 | 4.7.4, 2026-10 | Django, PostgreSQL, Redis | `services.netbox` | custom fields; Custom Objects plugin (GA 2025-10) | changelog | yes | none |
| **Nautobot** | Apache-2.0 | 3.2.8, 2026-10 | Django, PostgreSQL, Redis, Celery | none | custom fields, user-defined relationships | changelog | yes (Jobs, SSoT) | none |
| **Infrahub** | Apache-2.0 | 1.11.9, 2026-10 | Python, Neo4j, message queue | none | schema-defined graph | **branches and time travel** | yes | none |
| i-doit open | AGPL (unverified) | open edition behind the paid one | PHP, MySQL | none | yes | logbook | yes | none |
| Backstage | Apache-2.0 | 1.56 | Node, PostgreSQL | none | software catalog kinds | none | yes | none |

**Event management and operations consoles** (for O6; the CMDB must serve whichever is chosen)

| Tool | Licence | Status | NixOS | Relating events to CIs |
|---|---|---|---|---|
| Grafana alerting (in use) | AGPL-3.0 | active | `services.grafana` | labels only |
| Prometheus Alertmanager + Karma | Apache-2.0 | active, tiny | `services.prometheus.alertmanager`, `services.karma` | grouping and inhibition by label |
| **Keep** | MIT core, `ee/` proprietary | active; acquired by Elastic 2025-05 | none | correlation rules, enrichment from external sources and topology: the closest to "events enriched from a CMDB" |
| Zabbix | AGPL-3.0 | 7.4; 8.0 LTS in rc | server, proxy, agent, web | correlation rules, service tree |
| Checkmk Community | GPL-2.0 | 2.5 | none | parent/child topology, BI |
| Icinga 2 + Icinga DB Web | GPL | active | package, web module only | dependencies; Director imports hosts from a CMDB |
| Zammad | AGPL-3.0 | 7.2 | `services.zammad` | tickets only |
| Wazuh | GPL-2.0 / AGPL-3.0 | 4.14 | none | per agent; no CMDB link |
| Grafana OnCall OSS | – | **archived 2026-03** | – | do not use |

**Stores for a CMDB of our own:** SQLite (public domain, recursive queries for graph walks,
history by valid-from/valid-to rows; the smallest), PostgreSQL (`tstzrange` and exclusion
constraints for history; `services.postgresql`), Apache AGE on PostgreSQL (Apache-2.0, graph
queries, slow release cadence), Neo4j Community (GPLv3, JVM, `services.neo4j`). Memgraph and
SurrealDB are BSL, not open source; Kuzu was archived in 2025-10.

**What the survey shows.** The CMDBs that model TAPPaaS's breadth with typed relations and
history (iTop, CMDBuild, Infrahub) are a PHP, Java or Neo4j application with its own database,
and none knows a module instance, a zone or an environment without a custom data model written
for it. NetBox is the strongest physical model and has a NixOS module, but no services, people or
incidents. iTop is the closest to IT4IT end to end (CMDB with incident, problem and change).

**Decision: build cmdb-controller, borrow the models.**

- **Build** a small cmdb-controller in TypeScript, like the managers, on **SQLite** on
  `tappaas-cicd`: one writer (the controller), tables for CIs, relations and their history
  (valid-from, valid-to), recursive queries for impact. It exists at install, needs no further VM,
  and is backed up with `tappaas-cicd`. The schema is kept portable to PostgreSQL if a site
  outgrows SQLite (O2).
- **Borrow:** IT4IT 3.0's backbone objects (D1); CIM's typed associations as the vocabulary of
  relations (dependency, component, membership); NetBox's physical model (D7–D9); the
  netbox-inventory split between asset and role; OpenTelemetry's identifying resource attributes
  (`service.name`, `service.namespace`, `service.instance.id`) as the labels that carry a CI's
  identity in logs and events (D11).
- **Not adopt** a CMDB as the store, for the reasons v0.1 gave for assets, now stronger: the
  first node's asset is written before any module exists; a 1–5 node site would carry a second
  application and database to know itself; and every manager would depend on its API.
- **Keep open** for O6 and O7: iTop as the incident/problem/change side and NetBox as an export
  target, each fed from the CMDB; Keep, or Alertmanager with Karma, for event management.

## Consequences

- One record of what is: the CMDB, with history, relations and drift; one trace from every running
  thing back to its desired record, release, design and requirement.
- Every manager gains a reporting step; every interrogation it already makes feeds the CMDB.
- `positions.json` and the `*-actual.json` files go into the CMDB by migration (ADR-025);
  position-manager is renamed asset-manager.
- ADR-036 D3 is amended (asset-manager, placement on the asset) and D4 (the topology is a view of
  the CMDB). ADR-007f gains cmdb-controller and the reporting rule. ADR-034's views read the CMDB.
- `src/DATAMODEL.md` gains the actual layer; `GLOSSARY.md` gains CI, CMDB, asset, role, observation,
  drift and the backbone's five stages.
- `tappaas-cicd` carries a database and a service it did not before, backed up with it.

## Alternatives considered

- **A1 — Keep actual state in JSON files, one per manager** (`*-actual.json`). Simple, and what the
  switch configuration does. No relations across managers, no history, one writer per file.
  Rejected for the whole; such a file may stay as a controller's cache.
- **A2 — Adopt an existing CMDB as the store** (iTop, GLPI, NetBox/Nautobot, i-doit). See D12.
- **A3 — Backstage's software catalog.** Decided against in ADR-034 for the console; it models
  software components and ownership, not the running estate or physical things.
- **A4 — Assets only (v0.1).** Solves #906's physical case and leaves the rest of the actual state
  without a home; the same store, relations and history would be needed again for guests, zones and
  users.
- **A5 — Make the CMDB the source of desired state too.** One store for everything, but intent would
  move out of reviewable, migratable files (ADR-020, ADR-025) and the control plane would depend on a
  database to change anything. Rejected: desired stays in `config/`, actual in the CMDB.

## Open questions

- **O1** Split this ADR: an umbrella (the backbone, D1) with sub-ADRs for the CMDB (D2–D6, D10–D11)
  and the asset lifecycle (D7–D9), as the ADR-022 family does?
- **O2** The store: SQLite (D12), or PostgreSQL from the start for its temporal ranges and a later graph extension (Apache AGE).
- **O3** `faulty`: a stage, or a flag next to the stage?
- **O4** Disks: CIs of their own (they move between machines, fail and must be wiped), or attributes
  of the asset?
- **O5** Naming of assets the migration makes: the role's name, or a tag.
- **O6** The event-management ADR: incidents, problems, on-call, the SIEM; which tool (D12's event
  survey).
- **O7** Export to NetBox or iTop for an operator who runs one.
- **O8** How far the backbone trace reaches into Codeberg (issue state shown live in the console, or
  only a link), within the rule of no idle load on Codeberg.

## Implementation plan

1. cmdb-controller, its store and schema, the `cmdb` CLI and `lib/ts` client; `cmdb rescan`.
2. Reports from the existing interrogations: site-manager, module-manager, network-manager,
   switch-manager, ap-manager, identity-manager; identity matching; history.
3. asset-manager (rename, alias), the migration of `positions.json`, assets for every existing node,
   switch, AP and recorded device; `--asset` on the role verbs; the installer's hook reports.
4. The topology and the console's Physical view from the CMDB; a CI's panel with history and trace.
5. Events carry CI ids; health status on the CI; the Operations view.
6. Drift recorded (ADR-020's differ into the CMDB).
7. Exports (O7); the event-management ADR (O6).
