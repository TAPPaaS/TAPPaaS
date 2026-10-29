# ADR-040 — Asset Lifecycle and CMDB

| | |
|---|---|
| **Status** | **Draft** |
| **Version** | 0.5 |
| **Date** | 2026-10-29 |
| **Author** | Lars Rossen |
| **Deciders** | @LarsRossen, @ErikDaniel007 |
| **Closes / addresses** | #906. Amends ADR-036 D3 (who owns a placement, and what it hangs on) and D4 (the topology becomes a view of the CMDB); ADR-007f (a new controller, cmdb-controller, that every manager reports to); ADR-034 (the console's views read the CMDB). Related: ADR-020 (desired, actual and drift), ADR-022 family (the vocabulary of CI classes), ADR-022c (ArchiMate Node and Device), ADR-026 (machines as modules), ADR-028 and ADR-033 (releases), ADR-035 (manager rename and aliases), ADR-037 D4 (adding a node). |
| **Changelog** | v0.5 (2026-10-29) — **operator's review of D2 and D3:** a module instance is not a class of its own — a module is a **`node`** of its kind (`vm`, `lxc`, `machine`, `device`, ADR-022d) or, of kind application, a **`software/app`**; `software` is what runs *in* a node (`app`, `service`, `controller`, `manager`), so `tappaas1` is one CI, a `machine`, with `pve` as an app on it, and `identity` a `vm` with `authentik` on it; `guest` goes (`vm` and `lxc` stand for themselves); `party` is **`identity`**, TAPPaaS's word; UCMDB named as OpenText's model, not a standard; the essential attributes of every class in a table. cmdb-controller is a **24/7 API service** and `cmdb` a CLI with verbs in front of it. · v0.4 (2026-10-29) — **operator's direction:** IT4IT keeps assets (its Resource) apart from the Actual Product Instance, but the industry tracks assets in the CMDB, and so does TAPPaaS: **resources stand beside CIs** in one store, with relations between them (D3's root has `ci`, `resource` and `place`), and **two lifecycles** are kept apart (D7): the asset's (ordered → disposed, reusable) and the CI's (created from its desired record, retired with it, never reused — the same box as `tappaas5` is a new CI). A pool consumed by allocations (storage, addresses) is a resource the model allows and this ADR does not build (O10). **The store is PostgreSQL**, TAPPaaS's database standard (D12, D13; O2 closed). Figure 3-6's nine objects read from the standard's source: the five backbone objects and the four of the Service Offering Backbone. · v0.3 (2026-10-29) — checked against the IT4IT 3.0.1 standard itself (page numbers are the standard's): **Product Design** is a backbone object of its own (§7.1.3.1), between the Digital Product and the Product Backlog Items; the backbone's five objects named as §11.7.8 does; the Resource data object (§8.2.3.1) is where IT4IT holds physical assets. **D3** is a class hierarchy with inheritance, modelled on UCMDB's but small; **D13** the metamodel as data and how inheritance is stored in SQL; **D14** OpenTelemetry is supported: every CI has an OTel resource identity, Alloy carries it. · v0.2 (2026-10-29) — **scope widened (operator):** from asset lifecycle to TAPPaaS's whole lifecycle along the IT4IT product backbone; the actual state of everything — assets, nodes, guests, module instances, services, zones, environments, people, the site — is a CMDB owned by a new cmdb-controller that every manager feeds; the Physical view and the assets are one view of it, filtered on `physical`; event management and the operations console relate to it. v0.1's asset decisions are kept as D7–D9. Title was *Asset Lifecycle*. · v0.1 (2026-10-29) — first draft, from #906. |

TAPPaaS knows well what a site *should* be: the modules and their dependencies, the releases, and
the desired configuration in `config/*.json`. It knows poorly what a site *is*: that is asked live
from Proxmox, the switches or the firewall at the moment a verb needs it, and forgotten again. A box
that plays no role is not known at all.

This ADR lines TAPPaaS's lifecycle up with the **IT4IT Digital Product Backbone**, from the idea of a module
to the thing that is running, and gives the last stage, the **actual** state, a home: a
configuration management database (**CMDB**), kept by a **cmdb-controller** that every manager
reports what it sees and what it changes to. A physical **asset** stands in it beside the
configuration items — modules, guests, nodes, zones, environments, users, the site — with its own
lifecycle and a relation to the CI it is allocated to. The console's Physical view becomes one view
of the CMDB, filtered on `physical`; the Assets view another.

## Context

### The product backbone, and where TAPPaaS keeps each stage today

The Open Group IT4IT™ Standard, Version 3.0.1 (2024) follows a **Digital Product** through its
**Digital Product Backbone**: the key data objects that "annotate an aspect of the Digital Product
model in its planning, development, consumable, or running state" — the Digital Product, the
Product Design, the Product Release, the Desired Product Instance and the Actual Product Instance
(§11.7.8, p. 234; the "nine data objects" of Figure 3-6 are these five and the four of the Service
Offering Backbone — Service Offering, Subscription, Chargeback Contract, Service Contract — as the
figure in the standard's source shows). Each is controlled by one functional
component and linked to the one before, so that anything running can be traced back to why it
exists. IT4IT 2.1 called the chain the Service Model Backbone (conceptual, logical, desired and
actual service):

| Backbone object | Functional component (system of record) | Key relations the standard requires | TAPPaaS today | Owner today |
|---|---|---|---|---|
| **Digital Product** (§6.2.3.1, p. 119) | Portfolio | to Product Design 1:n; to Digital Product n:m (depends on) | the module catalog (`module-catalog.json`), each module's `dependsOn`/`provides`, `ROADMAP.md` | the repository, by hand |
| **Product Design** (§7.1.3.1, p. 133): "the collection of design artifacts … under version control", versioned | Product Design | to Requirement n:m; to Product Backlog Item 1:n; to Product Release 1:n | the module's directory (`DESIGN.md`, `<module>.json`, `services/*/fields.json`) and the ADRs it implements | the repository |
| **Product Backlog Item** (§7.1.1.1) | Product Backlog | to Product Design n:1; to Product Release n:1 | Codeberg issues | Codeberg |
| **Product Release** (§7.1.7.1, p. 144) with its **Product Release Blueprint** (§7.1.7.2) | Release Composition | to Product Design n:1; to Desired Product Instance 1:n; to Product Release n:m (depends on a version of another) | a module's `version`/`releaseDate` in its JSON, grouped into releases **per repository**: TAPPaaS's `release/releases.json` (the train, ADR-028), signed tags (ADR-033); the Community repository's own | tappaas-train, the repositories |
| **Desired Product Instance** (§8.2.2.1, p. 178): "the relevant fulfillment parameters that determine how to instantiate the product", with its CIs | Fulfillment Orchestration | to Product Release n:1; to Actual Product Instance 1:1; to Resource 1:n; to Desired Product Instance n:m | `config/*.json`: the module instances, `site.json`, `zones.json`, environments, identities, `positions.json`, the switch configuration's desired file | the managers (ADR-020: validate, modify) |
| **Actual Product Instance** (§9.2.1.1, p. 201): "the realized deployment of a specific Desired Product Instance. It includes CIs", with Id, Name, Type, Configuration Items, Create Time, Last Modified Time, Location | **Configuration** (§9.2.1, p. 200) | to Desired 1:1 ("each CI should be traceable to the planned configuration"); to Event n:m; to Incident n:m; to Problem n:m; to Actual Product Instance n:m | **nowhere as a whole.** Asked live (Proxmox API, OPNsense, Authentik, the switch controllers), joined on demand by `network-manager topology`, kept in two places only (`switch-configuration-actual.json`, the switch controller's last read); history only in logs | each manager, for the moment of one verb |

Two more of the standard's objects matter here. The **Resource** (§8.2.3.1, p. 180) "represents an
asset or other entity that is limited in nature. It can be allocated to a Digital Product or it can
be unallocated" — a pool of resources "virtual or physical (e.g., server, storage, networking,
software licenses, IP address)" kept by the Resource functional component: that is where IT4IT
holds a physical box, allocated to a Desired Product Instance or free. The **Event** (§9.2.3.1,
p. 207) is "an alert/notification signifying a change of state of a monitored CI or Actual Product
Instance", with Category, Type (causal or symptom), Severity, Status and Is Correlated, related
n:m to Actual Product Instances, to Logs and to other Events.

The Configuration functional component "shall be the system of record for all Actual Product
Instances and their associated relationships", "shall create Actual Product Instance(s) … based on
the Desired Product Instance", "shall calculate and provide impact analysis on proposed changes",
the business impact of an Incident and of an Event, and "may be populated by service discovery"
(p. 200–201). The seven 3.0 value streams (Evaluate, Explore, Integrate, Deploy, Release, Consume,
Operate) replace 2.x's four; this ADR is about the backbone, not the streams.

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

| Stage (IT4IT 3.0.1) | TAPPaaS object | Kept in | Link to the stage before |
|---|---|---|---|
| Digital Product (the *conceptual product*) | a **module** in the catalog, with its dependencies (`dependsOn`/`provides` are the standard's Digital Product to Digital Product n:m) and its portfolio requirements, the **ADRs** | the repository | – |
| Product Design, with its Requirements and Product Backlog Items | the module's **design** (`DESIGN.md`, `<module>.json`, its services' `fields.json`), the ADRs as its requirements, and its **backlog**: Codeberg issues labelled with the module | the repository, Codeberg | the module |
| Product Release, with its Blueprint | a **module release** (the module JSON at a version; its services and fields the blueprint), grouped in a **repository release** | the repository's tags and `releases.json` | the design at that version |
| Desired Product Instance | a **desired record** (`config/<instance>.json`, `zones.json`, …) | `config/`, by the managers | its module and the release the site runs |
| Actual Product Instance | its **configuration items (CIs)** | **the CMDB** (D2) | its desired record, where it has one |
| Resource (beside the backbone: "allocated to a Digital Product, or … unallocated") | a physical **asset** (D7), allocated to a CI — the node or device it is for the time being — or free | the CMDB, beside the CIs | the CI it is allocated to, and through it the desired record |

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
  CI classes and relation types, identity matching (D5) and history (D6).
- **It is a service, and the CLI is a client of it.** cmdb-controller runs as `tappaas` around the
  clock (`cmdb.service` on `tappaas-cicd`) and offers **one API**: HTTP/JSON on a Unix socket for
  the managers and the bash layer on the same host, and on `localhost` with a token for the
  console (ADR-034) and the agents behind it; reports come in batches, and a change stream
  (server-sent events) lets the console follow without polling. **`cmdb` is the verb surface in
  front of that API** — `show`, `query`, `history`, `impact`, `report`, `rescan`, `class` — as
  every manager has one (ADR-007f), and nothing more than a thin client, so a manager, a script,
  the console and an agent get the same answer at the same speed. `lib/ts` wraps the API for the
  TypeScript managers. The service is not a database server any caller may open: the store is
  reachable only through it.
- **Only cmdb-controller writes the store.** Managers and controllers send it observations and
  changes (D4); nothing else opens the database.
- **The CMDB is a record, never a gate.** A manager whose report cannot be delivered spools it and
  carries on; no verb fails because the CMDB is down. Desired state stays in `config/`; the CMDB
  never becomes the source of intent.
- **It can be rebuilt.** `cmdb rescan` asks every source again and recreates the actual state;
  what no source can see (the recorded facts of D7, and the history) is in the store's backup with
  `tappaas-cicd`'s.

### D3 — The CI model

The CI model is a **class hierarchy with inheritance**: a class declares attributes, keys and the
relations it may have, and a subclass inherits them and adds its own. The shape is that of the
large CMDBs — OpenText's UCMDB, not a standard but the model most of the industry's CMDBs
resemble, has one root, `Managed Object`, under which `ConfigurationItem` branches into
`BusinessElement`, `InfrastructureElement` (`Node`, `NodeElement`, `RunningSoftware`,
`NetworkEntity`, `CommunicationEndpoint`, …), `Location`, `Monitor` and `Party`, several hundred
classes deep — but TAPPaaS's is small: one level of abstract classes, and leaves that are the
words the ADR-022 family, ADR-007a and `GLOSSARY.md` already fix.

The root has three branches. A **`ci`** is what IT4IT's Actual Product Instance is made of: it
exists because a desired record exists, and ends with it. A **`resource`** is IT4IT's Resource —
"an asset or other entity that is limited in nature … allocated to a Digital Product, or
unallocated" — which the standard keeps in its own functional component and the industry's CMDBs
keep in the same store as the CIs; TAPPaaS does the latter, and keeps the two apart by class, not by
store. A **`place`** is where either stands.

```
object
├─ ci
│  ├─ node                  what runs software (ArchiMate Node, ADR-022c) — a module of that kind (ADR-022d)
│  │  ├─ vm                 kind vm
│  │  ├─ lxc                kind lxc
│  │  ├─ machine            kind machine: a cluster member, a satellite, a managed host (ADR-026)
│  │  └─ device             kind device: reachable, not managed; also a switch or AP from the switch configuration
│  ├─ software              what runs in a node
│  │  ├─ app                an application with a version: pve on tappaas1, authentik in identity, opnsense and caddy in network; a module of kind application
│  │  ├─ service            <module>:<service>
│  │  ├─ controller
│  │  └─ manager
│  ├─ network-element
│  │  ├─ zone
│  │  ├─ ssid
│  │  ├─ address
│  │  ├─ dns-name
│  │  ├─ proxy-route
│  │  └─ vpn-peer
│  ├─ storage-element
│  │  ├─ storage-pool
│  │  ├─ share
│  │  ├─ datastore
│  │  └─ backup-peer
│  ├─ identity              ADR-007a's objects, identity-manager's
│  │  ├─ organization
│  │  ├─ group
│  │  ├─ user
│  │  └─ role
│  └─ collection
│     ├─ site
│     ├─ cluster
│     └─ environment
├─ resource
│  ├─ asset                 physical
│  │  ├─ server
│  │  ├─ network-device     switch, access-point
│  │  ├─ appliance          modem, ont, ups
│  │  ├─ passive-device     patch-panel, pdu
│  │  └─ other-device
│  ├─ port                  physical; part of an asset
│  └─ pool                  a consumable (O10; no leaves yet)
└─ place                    physical
   ├─ location
   ├─ room
   └─ rack
```

**A module is a node, or an app.** There is no `module-instance` class: a module instance *is*
the node of its kind — `nextcloud` is a `vm`, `tappaas1` a `machine`, `alfen` a `device` — and a
module of kind `application` (`backup` on a cluster member) is a `software/app` on the node it
names. The CI carries the module facts (`desired` names `config/<name>.json`, `release` the module
and version) because every `ci` does. So `tappaas1` is **one object**, a `machine`: its desired
record is `tappaas1.json`, its release `pvehost 0.3.0`, its OS Debian, its asset the box; on it run
the apps `pve 9.1` and `zfs`, the service `pvehost:nfs` and the controller `proxmox-controller`,
each a `software` CI with a `runs-on` to it. Likewise `identity` is a `vm` with the app `authentik
2026.8` on it, and `network` a `vm` with `opnsense` and `caddy`. What is on a node is reported by
the node's own interrogation (the OS update, `health-manager`, the module's test) and gives the
estate the SBOM's view (ADR-011) of what version runs where. A switch or access point is a
`device` whose desired record is the switch configuration, not a module file.

The essential attributes of each class — those every instance has, beyond what it inherits:

| Class | Essential attributes |
|---|---|
| `object` | `id`, `class`, `name`, `displayName`, `description`, `physical`, `sources[]` (reporter, last seen), `firstSeen`, `lastSeen` |
| `ci` | `stage` (D7: created, operational, drifted, unseen, retired), `desired` (file, key), `release` (module, version), `health` |
| `node` | `os`, `osVersion`, `management` (managed/unmanaged, ADR-022g), `addresses[]`, `environment` (a relation), `stack` |
| `vm` | `vmid`, `cores`, `memory`, `disks[]` (storage, size), `template`, `haPolicy`, `onNode` (relation `runs-on` → machine) |
| `lxc` | `vmid`, `cores`, `memory`, `rootfs`, `unprivileged`, `onNode` |
| `machine` | `hostname`, `clusterMember`, `storagePools[]`, `uplinks[]` (ports, by relation), `asset` (relation `allocated-to`) |
| `device` | `model`, `firmware`, `managementAddress`, `controller` (which controller manages it, if one) |
| `software` | `version`, `state` (running, stopped), `listens[]` (port, protocol), `onNode` |
| `app` | `upstream` (project, package), `cpe` or `purl` for the SBOM (ADR-011) |
| `service` | `provider` (the module), `consumers[]` (by relation) |
| `controller`, `manager` | `registry` (the `control-plane.json` entry, ADR-035), `aliases[]` |
| `zone` | `vlan`, `subnet`, `ipv6Subnet`, `tier`, `dhcp` (range) |
| `ssid` | `security`, `zone`, `broadcastOn[]` |
| `address` | `ip`, `family`, `reservation` (mac), `leaseUntil` |
| `dns-name` | `fqdn`, `target`, `public` |
| `proxy-route` | `host`, `path`, `target`, `gate` (identity gate on/off), `allowedZones[]` |
| `vpn-peer` | `publicKey`, `endpoint`, `allowedIps[]` |
| `storage-pool` | `type` (zfs, …), `size`, `used`, `health`, `onNode` |
| `share` | `path`, `grants[]` |
| `datastore` | `size`, `used`, `retention`, `onNode` |
| `backup-peer` | `direction` (pull, receive), `location` (relation), `lastSeen` |
| `organization` | `domain`, `displayName` |
| `group` | `uuid`, `roles[]` |
| `user` | `uuid`, `username`, `email`, `enabled` |
| `role` | `scope` |
| `site` | `code`, `primaryLocation` (relation), `version` (the TAPPaaS release) |
| `cluster` | `quorum`, `members[]` (relation) |
| `environment` | `domain`, `organization` (relation), `zone` (relation), `updateWindow` |
| `resource` | `stage` (D7: ordered … disposed), `allocatedTo` (relation → a ci, or none) |
| `asset` | `vendor`, `model` (a faceplate key where one exists), `serial`, `assetTag`, `procurement` (supplier, orderRef, purchaseDate, warrantyUntil, ownership), `disposal` (how, when, wiped) |
| `server` | `bmc` (mac, address), `bootDisks[]` (serial), `cpu`, `memory` |
| `network-device` | `controller` (the one that manages it), `ports` (count) |
| `appliance`, `passive-device`, `other-device` | `ports` (count or names) |
| `port` | `kind` (ethernet, sfp, wifi, bmc, usb, power), `mac`, `speed`, `side` (front, rear), `asset` (relation `part-of`) |
| `pool` | `capacity`, `unit`, `allocated` |
| `location` | `kind` (site, remote), `country`, `city`, `address`, `timezone`, `latitude`, `longitude` |
| `room` | `location` (relation) |
| `rack` | `units`, `width`, `numbering`, `room` (relation) |

A query for a class answers for its subclasses too: "every `asset`" lists servers and switches;
"every `node`" lists the modules by kind; "every `object` that is `physical`" is the Physical
view, "every `resource`" the Assets view (D10). A class's attributes are declared the
way a service declares its fields (ADR-020, `fields.json`): name, type, required, immutable,
which of them are **keys** (D5) and which **identify** the CI in telemetry (D14). A relation type
is declared with the classes it may join and its cardinality, and inherits the same way
(`placed-in` is declared for `asset` → `rack|room`, so it holds for a `server`).

A new class goes through the gate of ADR-022h, under an existing abstract class; a module's own
manager (ADR-035) may add leaf classes under `software`, `asset`, `network-element` or
`storage-element` and the
relation types between them, declared in its JSON and registered by module-manager. Nothing may
add a root. Relations are typed, and each is reported by the manager that knows it:

| Relation | Example |
|---|---|
| `allocated-to` | resource → ci: asset → machine (the box this node runs on, for now); later a pool's allocation → vm (O10) |
| `runs-on` | vm / lxc → machine; software → node (app, service, controller, manager on the node they run in) |
| `part-of` | port → asset |
| `placed-in`, `at` | asset → rack / room; room → location; ci → location (a machine's, through its asset; a satellite's, recorded) |
| `connects` | port ↔ port (a cable, seen or recorded); port → ssid (Wi-Fi) |
| `member-of` | node → cluster; user → group; address → zone |
| `depends-on`, `provides` | node → service (from the module's `dependsOn`/`provides`) |
| `serves` | zone → environment; proxy-route → service |
| `owned-by` | environment → organization; asset → site |
| `backs-up` | datastore → vm / lxc / machine; backup-peer → site |

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

The controller matches each report to an existing object by the class's keys, strongest first,
among the objects that are not retired or disposed — a retired CI's name may be taken again by a
new one (D7):

| Class | Keys |
|---|---|
| asset | vendor + serial, then any port's MAC (D9) |
| machine | Proxmox node name within the cluster, then its asset |
| vm, lxc | VMID + cluster, then the module name (the `config/` file) |
| device | the switch configuration's name, then its asset |
| software | name + version within its node |
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

### D7 — Two lifecycles: the asset's and the CI's

An asset and the CI it serves have lives of their own, and the CMDB keeps both:

| | Asset (a `resource`) | CI |
|---|---|---|
| Begins | when bought or found: `asset add`, or the installer's or a controller's report (D8) | when its desired record is written: `node add`, `module add`, `add-switch` … — IT4IT: the Configuration component "shall create Actual Product Instance(s) … based on the Desired Product Instance" |
| Lives | through `ordered`, `stock`, `placed`, `operational`, `faulty` — allocated to a CI or free | `created` → `operational` (seen by its sources), with `drifted` (D6) and `unseen` (D5) as states it passes through |
| Ends | `disposed`: the record stays, read-only, with its history | `retired`: when the desired record is deleted or archived; the record stays, with its history |
| Reused | yes: the same asset is allocated to the next CI | **never**: the box that was `tappaas3` and becomes `tappaas5` is a new CI, as is a `tappaas3` added again later |

The example from #906, in these terms: a machine is bought (an asset, `ordered`, no CI); racked
(`placed`); `node add tappaas3` writes `tappaas3.json`, the CI `tappaas3` is created and the asset
**allocated to** it (`operational`, on both); `node delete tappaas3` retires the CI, and the asset
is unallocated and back to `placed`, still in its rack; `node add tappaas5 --asset …` creates a new
CI and allocates the same asset to it. "What has this box been" is the asset's history of
allocations; "what happened to tappaas3" is the retired CI's history. Neither record is deleted.

What v0.1 decided for assets stands, inside the CMDB:

- **Asset and role.** An asset is the physical thing (`physical: true`); the CI it is allocated to —
  a `machine` for a node or a managed host, a `network-device`'s controller-managed switch or AP, a
  recorded device — is the **role** it plays for a while. A box keeps its placement, ports, cables
  and history when its role ends, and can take another.
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
switches or LLDP, or recorded): it is a `connects` relation with `kind`, `label`, `origin` and
`side` as its attributes, not a CI of its own. A node's `uplinks`, second lan leg and WAN port name ports of its
asset. The BMC is a port with its own MAC. A **Wi-Fi** port connects to an SSID, and through it to
the zone that SSID bridges to; the AP controller's client list reports it by MAC. A MAC is unique
across all ports, so a DHCP reservation or a pending node registration that names a MAC names an
asset.

### D10 — The console's views are views of the CMDB

The console (ADR-034) reads the CMDB for what *is*, and the managers' verbs for what to change:

- **Physical:** every object with `physical: true` — assets, their ports, rooms and racks — by
  location, room and rack, each asset labelled with the CI it is allocated to; a device panel is
  the asset with its CI beside it.
- **Assets:** every `resource`, by stage: ordered and in stock first, then placed and unallocated,
  then allocated, faulty, disposed; an asset's panel shows its history of allocations.
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

- **Enrichment:** an alert on host `nextcloud` is the `vm` CI, which runs on the machine `tappaas2`, in
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

- **Build** a small cmdb-controller in TypeScript, like the managers, on **PostgreSQL** on
  `tappaas-cicd` (`services.postgresql`, a database of its own): one writer (the controller),
  tables for objects, relations and their history (valid-from, valid-to), recursive queries for
  impact. PostgreSQL is TAPPaaS's database standard — identity, nextcloud, immich, euro-office,
  openwebui and litellm each run one — so it adds a known service, not a new kind. It exists from
  the bootstrap, needs no further VM, and its dump is in `tappaas-cicd`'s `backup:filesystem`
  paths. SQLite was considered for its size and rejected for consistency with the estate (O2).
- **Borrow:** IT4IT 3.0.1's backbone objects and the Configuration component's duties (D1, D2);
  UCMDB's shape — one root, abstract classes, inheritance, keys per class, relations as typed links
  — without its size (D3, D13); CIM's typed associations as the vocabulary of relations
  (dependency, component, membership); NetBox's physical model (D7–D9); the netbox-inventory split
  between asset and role; OpenTelemetry's resource identity as the CI's identity in telemetry
  (D14).
- **Not adopt** a CMDB as the store, for the reasons v0.1 gave for assets, now stronger: the
  first node's asset is written before any module exists; a 1–5 node site would carry a second
  application and database to know itself; and every manager would depend on its API.
- **Keep open** for O6 and O7: iTop as the incident/problem/change side and NetBox as an export
  target, each fed from the CMDB; Keep, or Alertmanager with Karma, for event management.

### D13 — The metamodel is data; inheritance is not the table layout

A class hierarchy does not translate into SQL tables one to one. The three textbook mappings each
fail a requirement here: **one table per class, joined** (a `server` row in `object`, `ci`, `asset`
and `server`) needs a DDL migration for every new class, and a module cannot add one (D3);
**one table per concrete class** cannot answer "every asset" without a union that changes with
the classes; **one wide table** with a column for every attribute of every class is sparse, and
again a migration per attribute. In each, the history of one attribute (D6) is a second copy of the
whole layout.

So the **metamodel is stored as data**, and the controller enforces it:

| Table | Holds |
|---|---|
| `class` | name, parent, abstract, physical, description — the tree of D3 |
| `class_ancestor` | the transitive closure (class, ancestor, depth), rebuilt when the metamodel loads: the inheritance, as a join |
| `attribute_def` | class, name, type, required, immutable, key, identifying, description |
| `relation_type` | name, parent, from class, to class, cardinality, description |
| `object` | id, class, name, display name, created, ended — the core columns every object has (CI, resource and place alike) |
| `attribute` | object, name, value (JSONB), source, **validity** (a `tstzrange`) — one row per value per period; an exclusion constraint keeps one object's periods for one attribute from overlapping |
| `relation` | id, type, from object, to object, attributes (JSONB), source, validity |
| `change` | job, verb, actor, time, the objects and relations it touched (D6) |

An asset "is a `server`" is one row in `object`; "every asset" is `object` joined with
`class_ancestor` on `ancestor = 'asset'`; "the current value" is the `attribute` row whose range is
open at the upper end, and the value on a date is the row whose range contains it (`@>`). An
attribute's type, whether it is required and
whether it may change are checked by cmdb-controller against `attribute_def` for the CI's class and
its ancestors before the row is written — **the schema check moves from the database's DDL into
the controller**, where it can read the declaration. Adding a class, an attribute or a relation
type is rows in the metamodel tables (a module declares them, module-manager registers them,
ADR-035); only the eight tables above are DDL, and only their change is an ADR-025 migration.
Indexes on (`name`, `value`) in `attribute` (a GIN index on the JSONB) and on both ends of
`relation` carry the queries; impact and "within two hops" are recursive queries over `relation`.
The layout is plain SQL: PostgreSQL's ranges, exclusion constraints and JSONB are the only things
used beyond it, and a graph extension (Apache AGE) can be added over the same tables if the
queries ever need one.

### D14 — OpenTelemetry carries the CI's identity

TAPPaaS supports OpenTelemetry. Every CI has an **OTel resource identity**: the identifying
attributes of its class (D3), mapped to the OpenTelemetry resource semantic conventions where one
exists and carried as such in every signal about it:

| CI | OTel resource attributes |
|---|---|
| `node` (a module: `vm`, `lxc`, `machine`, `device`) | `service.name` (the module), `service.namespace` (the environment), `service.instance.id` (the CI id), `service.version` (the release); and `host.name`, `host.id` (the CI id), `host.type`, `os.type` |
| `software` (`app`, `service`, `controller`, `manager`) | `service.name` (its name), `service.namespace` (the node), `service.instance.id` (the CI id), `service.version` |
| `asset`, `port` | no convention yet; `tappaas.ci.id` and `tappaas.ci.class` |
| every CI | `tappaas.ci.id`, `tappaas.ci.class`, `deployment.environment.name` |

Grafana Alloy, already on every NixOS guest and on the logging VM (`logging:logs`), is an
OpenTelemetry collector: the logging module's pipelines add these attributes to the journal they
ship, taken from the CI id cmdb-controller gives the guest at deploy (written beside the push
secret). A log line, a metric or a trace then names its CI, and an event raised from them (D11)
inherits the identity without matching on host names. cmdb-controller resolves resource attributes
to a CI (`cmdb resolve service.instance.id=…`) for anything that only has the labels. OTel's
Entities data model, still in development, is the direction: a CI is an entity, its keys the
identifying attributes; the mapping is revisited when it stabilises (`service.*` is stable,
`host.*` and `deployment.*` are not). Metrics and traces are not collected today; when they are
(the logging module's v2 backlog), they come with the same identity.

## Consequences

- One record of what is: the CMDB, with history, relations and drift; one trace from every running
  thing back to its desired record, release, design and requirement.
- Every manager gains a reporting step; every interrogation it already makes feeds the CMDB.
- `positions.json` and the `*-actual.json` files go into the CMDB by migration (ADR-025);
  position-manager is renamed asset-manager.
- ADR-036 D3 is amended (asset-manager, placement on the asset) and D4 (the topology is a view of
  the CMDB). ADR-007f gains cmdb-controller and the reporting rule. ADR-034's views read the CMDB.
- `src/DATAMODEL.md` gains the actual layer; `GLOSSARY.md` gains CI, CMDB, resource, asset, allocation, role, observation,
  drift and the backbone's five stages.
- `tappaas-cicd` carries a PostgreSQL database and a service it did not before, backed up with it.

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
- **O2** *(closed 2026-10-29, operator)* The store is PostgreSQL, TAPPaaS's database standard
  (D12, D13).
- **O9** Where a module's CI class declarations live: in `<module>.json` beside `provides`, or a
  `cmdb.json` of its own.
- **O10** Pools as consumable resources: IT4IT's Resource is consumed — a storage pool is the
  resource, a guest's disk an allocation from it; the same for an address range or a VLAN range.
  The model has the class (`pool`) and the relation (`allocated-to`); nothing is built on it in
  this ADR. When it is, storage-manager reports the pools and proxmox-controller the allocations.
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

1. cmdb-controller on PostgreSQL in `tappaas-cicd`, its eight tables and the metamodel of D3 loaded
   as data (D13), the `cmdb` CLI and `lib/ts` client; `cmdb rescan`.
2. Reports from the existing interrogations: site-manager, module-manager, network-manager,
   switch-manager, ap-manager, identity-manager; identity matching; history.
3. asset-manager (rename, alias), the migration of `positions.json`, assets for every existing node,
   switch, AP and recorded device; `--asset` on the role verbs; the installer's hook reports.
4. The topology and the console's Physical view from the CMDB; a CI's panel with history and trace.
5. Events carry CI ids; health status on the CI; the Operations view.
6. Drift recorded (ADR-020's differ into the CMDB).
7. Exports (O7); the event-management ADR (O6).
