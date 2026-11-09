# cmdb-controller

Primary audience: TAPPaaS admin, and whoever writes a manager that reports.

The **CMDB**: the actual state of the site — every CI (node, software, zone,
user, environment, …), every asset and port, every room and rack, the relations
between them and the history of each — kept by one service on `tappaas-cicd`
(ADR-040). Desired state stays in `config/`; the CMDB records what *is*, and is
a record, never a gate: no verb fails because it is down.

This is step 1 of the ADR's plan: the store, the metamodel, the service, the
`cmdb` CLI and the clients. No manager reports yet (step 2).

## The parts

| Part | Where |
|---|---|
| The store | PostgreSQL's database `cmdb` on `tappaas-cicd`, owned by `tappaas`, reached over PostgreSQL's socket with peer authentication by the service only |
| The service | `cmdb.service` → `~/bin/cmdb-controller serve`, as `tappaas` |
| The API | HTTP/JSON on `/run/cmdb/cmdb.sock` (the managers, the bash layer) and `127.0.0.1:9098` with the bearer token in `/etc/secrets/cmdb-token` (the console) |
| The CLI | `~/bin/cmdb` |
| The metamodel | [`metamodel/`](./metamodel/): the class tree, fields and relation types of ADR-040 D3 as JSON |
| The schema | [`schema/`](./schema/): the eight tables of D13 (`cmdb-v1.sql`) and what later versions change; applied at the service's start |
| The clients | [`lib/ts/src/cmdb.ts`](../../lib/ts/src/cmdb.ts) (TypeScript managers), [`lib/cmdb.sh`](../../lib/cmdb.sh) (bash) |
| The backup | `cmdb-dump.service` writes `/var/lib/cmdb/dump/cmdb.dump` just before each file backup; the path is in `tappaas-cicd.json`'s `backup.filesystemPaths` |

## The verbs

`<object>` is an id, a name, or `<class>/<name>` where a name is not unique.
Every verb takes `--json` (the API's data as is); otherwise a table.

| Verb | What |
|---|---|
| `cmdb show <object> [--class C] [--at TIME]` | an object: its class and ancestors, its attributes with source and since, its relations, its drift |
| `cmdb query [<class>] [--physical] [--recorded] [--where k=v]… [--at TIME] [--all]` | the objects of a class and all its subclasses (`cmdb query asset` lists servers and switches; `cmdb query --physical` is the Physical view); `--where` matches an attribute (a JSON value, or a bare word as a string; an array attribute matches when it contains the value; `conditions.status=critical` is a path into an object value, or into any member of an array value); `--recorded` only what an operator recorded; `--at` as of a time; `--all` includes retired and disposed objects |
| `cmdb relations [--type T] [--from O] [--to O] [--from-class C] [--to-class C] [--recorded] [--at TIME]` | relations by type and either end (`O` as `<object>`), each with both ends, attributes, source and recorded; the classes include subclasses. What a topology is read from |
| `cmdb history <object> [--at TIME]` | every period of every attribute and relation, with its source; with `--at`, the object as it was then |
| `cmdb impact <object> [--hops N] [--direction in\|out\|both]` | everything within N current relations (default 2, both ways), each at its shortest distance with the relation it was reached by |
| `cmdb report [--file F]` | a report (below) from stdin or a file; spooled when the service does not answer |
| `cmdb sweep [--last]` | the discovery sweep (below); `--last` prints the last record and runs nothing |
| `cmdb rescan` | after replaying the spool, run `<component> report` for every component `components.json` marks `"cmdbSource": true`, one at a time; prints what each answered (and the last lines of one that failed) |
| `cmdb class list` / `cmdb class show <class>` | the class tree; a class's fields (own and inherited), keys and relations |
| `cmdb resolve <otel-attr>=<value>…` | OpenTelemetry resource attributes → the object (D14): `service.instance.id`, `host.id` or `tappaas.ci.id` are the id; `host.name`, `service.name`, `service.version` match the fields declared `identifying`; `service.namespace` the node or environment; `tappaas.ci.class` the class |

Exit codes: 0 done, 2 usage, 3 not found, 4 refused (a conflict or a report
that does not fit the metamodel), 5 the service does not answer.

## How a manager reports

A report is a batch: the objects and relations one interrogation saw (an
**observation**) or one verb changed (a **change**, with its verb, job and
actor). Each object is matched by its class's keys (D5) to the one already
stored, or created; every attribute is checked against the fields of its class
and its ancestors; one problem refuses the whole batch, and nothing of it is
written.

```json
{
  "source": "site-manager",
  "kind": "observation",
  "time": "2026-10-29T10:00:00Z",
  "objects": [
    { "ref": "srv", "class": "server", "name": "srv-01",
      "attributes": { "vendor": "hp", "serial": "CZC1234", "model": "hp/z840", "displayName": "tappaas1" } },
    { "class": "port", "name": "eno1",
      "attributes": { "asset": { "ref": "srv" }, "kind": "rj45", "speed": "1g", "mac": "aa:bb:cc:00:00:01", "role": "lan" } },
    { "ref": "m", "class": "machine", "name": "tappaas1",
      "attributes": { "clusterMember": true, "asset": { "ref": "srv" } } },
    { "class": "vm", "name": "nextcloud", "attributes": { "vmid": 200, "cores": 4, "onNode": { "ref": "m" } } },
    { "ref": "c", "class": "cluster", "name": "tappaas", "attributes": { "quorum": true } }
  ],
  "relations": [
    { "type": "member-of", "from": { "ref": "m" }, "to": { "ref": "c" } }
  ]
}
```

- `kind`: `observation` (default) or `change`. A change carries `verb`, `job`
  (the console's Activity id) and `actor`.
- `time`: when it was seen or done; default now. A spooled report keeps it.
- An attribute of type `relation` (a port's `asset`, a vm's `onNode`, a
  machine's `asset`) takes a reference — `{ "ref": … }` to an object earlier in
  the report, `{ "id": … }`, `{ "class": …, "name": … }`, or a plain string (a
  ref, else an id, else a name) — and is stored as a relation row.
- `null` unsets an attribute; `"end": true` retires a CI or disposes of a
  resource: it stays, with its history, and leaves key matching, so the same
  name reported again is a new object (D7). The software running on an ended
  node ends with it. The end of something the store does not have is nothing,
  not a refusal.
- Reporting what is already stored writes nothing. A value that differs closes
  its period and opens a new one. An observation that differs from the last
  with no change behind it marks **drift** on the object (`cmdb show` prints
  it); the next change report that touches the object clears it.
- A CI no source has reported for longer than its class's expiry (7 days by
  default) is marked `stage: unseen` — never deleted — and is `operational`
  again when reported (D5, D7).
- **A reference to what is not reported yet** does not refuse the batch: a
  relation or relation field naming `{ "class": …, "name": … }` that the store
  does not have makes a **placeholder** of that class — the name, `placeholder:
  true` from the reporting source, no stage — listed in the answer's
  `placeholders`. Its owner's report merges into it (`adopted`, same id), also
  when it was named by an abstract class (`node`). A class that does not exist
  is still refused; so is a bare name or id that resolves to nothing.
- **Recorded facts:** `"recorded": true` on an object or a relation (or
  `"source": "recorded"` on the report) says an operator recorded it, not a
  machine (D7). It stays: `cmdb show` prints it, and a source seeing the same
  thing later does not clear it.
- An asset is found by vendor + serial, then by any of its ports' MACs (the
  ports in the same report that name it as their `asset`), then by its tag. A
  box found that way under another name keeps its tag; the result's
  `reportedAs` shows the name it was reported under.

From TypeScript:

```ts
import { cmdbReport, cmdbQuery, cmdbRelations } from "../../../lib/ts/src/cmdb";
cmdbReport({ source: "site-manager", objects: [...] }); // never throws for an outage: spools
const assets = cmdbQuery({ class: "asset" });
const placed = cmdbRelations({ type: "placed-in", fromClass: "asset" });
```

From bash:

```bash
. /home/tappaas/TAPPaaS/src/foundation/tappaas-cicd/lib/cmdb.sh
jq -n '{source: "switch-manager", objects: [...]}' | cmdb_report   # never fails the caller
```

A report the service cannot take goes to `config/.cmdb-spool/` and is replayed,
oldest first, by the next call that reaches it (or `cmdb rescan`). One the
service refuses on replay is moved to `.cmdb-spool/refused/` with a `.why`.

## The API

Every answer is `{ "ok": true, "data": … }` or `{ "ok": false, "error": …,
"problems"|"candidates": … }` with 400, 401, 404, 409 (a conflict) or 422 (does
not fit the metamodel).

| Route | Body / query | Data |
|---|---|---|
| `GET /v1/health` | | schema version, counts |
| `POST /v1/report` | a report | per object: id, created, adopted, changed attributes, drift; the placeholders made; the change id (null when nothing changed) |
| `POST /v1/query` | `{ class?, physical?, recorded?, where?, at?, includeEnded?, limit? }` | objects with their current (or as-of) attributes |
| `POST /v1/relations` | `{ type?, from?, to?, fromClass?, toClass?, recorded?, at?, limit? }` | relations, both ends named |
| `GET /v1/objects/<id\|name>` | `?class=&at=` | the object (as `cmdb show`) |
| `GET /v1/objects/<id\|name>/history` | `?class=&at=` | every period; with `at`, the object then |
| `GET /v1/objects/<id\|name>/impact` | `?hops=&direction=` | the objects within reach |
| `POST /v1/resolve` | `{ attributes: { "host.name": … } }` | the object |
| `POST /v1/rescan` | | what each source answered |
| `POST /v1/sweep`, `GET /v1/sweep` | | a sweep and its record (409 while one runs); the last record (404 when none has) |
| `GET /v1/classes`, `GET /v1/classes/<name>` | | the metamodel |
| `GET /v1/rules` | | the correlation rules (a rule's `dependant` clause too), each relation type's `dependant`, `required` and `tree`, each class's ancestors, and `fields`: every attribute some class declares, what a `dependant` clause may name |
| `GET /v1/stream` | | server-sent events: `event: change` with the change's id, kind, source, job, verb, time, objects, relations, drift |

```bash
curl -s --unix-socket /run/cmdb/cmdb.sock -X POST http://cmdb/v1/query \
  -d '{"class": "asset", "where": {"vendor": "hp"}}'
```

## The discovery sweep

A report is what a manager sees while it does something else. `cmdb sweep`
(ADR-040 D15) asks every source for everything, and says whether the site is
still what `config/` says it is. It is read-only for every plane; it writes
only the CMDB.

1. Runs `<component> report --discover` for every `cmdbSource` component. A
   source whose verb refuses the flag is asked plainly, and the report says so.
2. Lists every attribute and relation that changed, appeared or went since the
   last sweep, by object, with its source: **expected** when a change report
   explains it, **drift** when nothing does. Volatile fields are left out. The
   first sweep has nothing to compare: it is the baseline.
   **New** is expected too (`expected: true`, `reason: "new"`, the owner's
   `verb`): an object that appeared as a part of an object a verb made —
   `part-of`, `runs-on`, `member-of` or `allocated-to` it, transitively (the
   ports of the asset `node add` made) — when that verb ran since the last
   sweep or at most an hour before the part appeared (`owner` names the object
   it is part of); and the first observation of a verb-made object (or of such
   a part): fields and relations appearing that never had a value. A later
   change of a filled field is drift.
   **Words** are expected too (`reason: "words"`): a relation whose ends and
   type stay and whose only change is `required` or `redundancyGroup`. Those
   are words a report classifies the relation with, not an observation.
3. Lists what differs from `config/`: `module-manager drift` for each module
   record (ADR-020's resolver and differ), **actual without desired** (an object
   of a class a record can declare, with none: `unmanaged`) and **desired
   without actual** (a record no CI answers for, a CI with a record no source
   saw in this sweep, or an `unseen` one: `missing`).
4. Writes one `change` row, verb `sweep`, with the counts and differences as its
   body; one JSON line per difference to the journal, identifier `cmdb-sweep`
   (`kind`, `class`, `name`, `source`, `attribute`, `before`, `after`,
   `expected`, and `reason`, `verb`, `owner` for a new or words one); the counts have
   `new` and `words` beside `expected` (of which they are a part); and the report to stdout (`--json` too). Objects with
   unexplained differences are marked drifted until a change clears them.

| Exit | Status | When |
|---|---|---|
| 0 | healthy | nothing but expected changes |
| 1 | warning | drift, unmanaged things, a difference from desired, a module the differ could not read |
| 2 | critical | desired without actual, or a source that failed |

```bash
journalctl -t cmdb-sweep --since today -o cat | jq -r 'select(.expected | not) | "\(.kind) \(.class)/\(.name) \(.attribute)"'
```

`cmdb-sweep.timer` runs it every night, an hour before the site's update hour
(`updateSchedule`; 01:00 with none), rendered with the update's timer by
`update-tappaas-schedule.sh`. health-manager's gate `cmdb` reads the last record
by the same thresholds, and is critical when there has been no sweep for 48 hours;
`health-manager assess` turns its lists into `drift` conditions.

## The metamodel files

[`metamodel/ci.json`](./metamodel/ci.json) (the root `object` and the `ci`
branch), [`resource.json`](./metamodel/resource.json),
[`place.json`](./metamodel/place.json),
[`relations.json`](./metamodel/relations.json) and
[`health-rules.json`](./metamodel/health-rules.json) are loaded into the metamodel
tables at every start. A field is declared as ADR-020's `fields.json` declares
one — `type`, `required`, `immutable`, `description`, `enum` — plus:

- `key`: the rank of the identity key the field is part of (D5). Fields of one
  rank form one key; the lowest rank is tried first. A class without keys is
  known by its name within its class. Keys are unique in the class's nearest
  abstract ancestor (a VMID among every node, a serial among every asset).
- `identifying` and `otel`: the field names the CI in telemetry, as these
  OpenTelemetry resource attributes (D14).
- `type: "relation"` with `relation` (and `direction: "in"` when the object is
  the relation's target): the field is a relation row.
- `allowedBy`: the values a field may take, by another field's value (a port's
  `speed` by its `kind`, D9).
- `derived`: kept by the controller (`drift`), never reported.
- `volatile`: the value changes by itself (`conditions`, `used`, `leaseUntil`,
  `lastSeen`, `stage`, `state`, `quorum`), or moves on every refresh of the
  control plane (the site's `version`): it has history like any other, and
  never counts as drift. On a member of an object or of an array's items (a
  condition's `lastChecked`) it means no history at all: a value that differs
  only there is rewritten in place.

On a class: `desiredRecord` — a `config/` record can declare it, so a sweep calls
one without a record unmanaged; `expiry` (`7d` on `ci`, inherited) — how long a CI may go
unreported before it is unseen; `keyVia` — a key that is a field of a related
object (an asset's ports' MACs, rank 2).

`conditions[]` on `object` is health (ADR-041 D1): `type`, `status`, `reason`,
`message`, `since`, `lastChecked`, `source`, `derived`, `rootCause`,
`acknowledged`, `maintenance`, one per type. `health-manager assess` is its only
writer, by an **assessment**: a report with `"assessment": true`, naming objects
by `id`, which creates nothing and is no sighting (no `lastSeen`, no way back
from unseen). The `site` carries `rootCauses[]` and the last run's `assessment`.

On a relation type (`relations.json`): `dependant`, the end hurt when the other
fails (`from`, `to`, `both`; none: it carries no health), and `required`. A
relation row may set `required` and a `redundancyGroup` in its attributes. Both are
kept across reports from other sources that see the same relation and do not name
them; `null` unsets one, and a report giving nothing but these adds them to the
relation's other attributes, so the source that knows the redundancy sets it.
`tree` is the end the console's Health tree nests under the other (`from`, `to`,
`both` when each end lists the other as a leaf, as a cable; none: no containment).
[`health-rules.json`](./metamodel/health-rules.json) holds the correlation rules
(ADR-041 D3); a rule the controller cannot place stops the load like any
metamodel error, and `GET /v1/rules` serves them with what a reader needs. A
rule's optional `dependant` (`{attribute: value}`, `true` for any value set) must
name an attribute some class declares.

Disks: a **`disk`** (a resource beside `port`, physical) is a disk in an asset, `part-of`
it — its `asset` and its `name` (the disk asset's tag, `dsk-NN`) are its key, and the asset
is immutable: a disk moved to another server is a new CI there, the old one ends. Its
record (`bay`, `vendor`, `model`, `serial` — unique across the disks, asset-manager refuses a
second —, `wwn`, `size`, `kind` nvme|ssd|hdd|usb, `bus`, `firmware`) is asset-manager's;
what the node says of it (`health`, `holds`, `partitions`; `smart`, `wearout`, `temperature`
from the sweep) site-manager's, all volatile. A **`built-on`** relation joins a
`storage-pool` to each of its member disks (`dependant: from`, required): site-manager sets
`redundancyGroup` `<node>:<pool>:<vdev>` on the members of a mirror or raidz vdev and
`required: false` on a log, cache or spare member, so one failed disk of a mirror degrades
its pool and a vdev with every member failed takes it down (the `built-on` rule in
`health-rules.json`). A **`stored-on`** relation joins a `vm`, an `lxc` or a backup
`datastore` to each pool its data is on (`dependant: from`, required, n:m): a pool's
`critical` takes them down with it; its warning (`DEGRADED`) reaches none.

A subclass that declares an inherited field again with only some properties
refines it (`vm` makes `name` a key of rank 2). A new class goes through
ADR-022h's gate, under an existing abstract class; nothing adds a root.

### How a class is drawn

Every class also has a `symbol`, a `family` and a `label`: the console draws
an object as its symbol on its family's colour, with the label (the class in
the operator's words) as its name. No two classes share a symbol, so a TAPPaaS
node (▣) and the server it runs on (▤) are told apart at a glance.
[`metamodel/gen-symbols.mjs`](./metamodel/gen-symbols.mjs) checks that and
writes the console's copy and the table below; a new class gets its symbol in
the same change, and the console's tests fail until the script has run.

<!-- class-symbols:begin (metamodel/gen-symbols.mjs writes this table) -->

| Symbol | Class | What it is | Family |
|:---:|---|---|---|
| ▢ | `node` | node | compute: what runs software |
| ◫ | `vm` | virtual machine | compute: what runs software |
| ◧ | `lxc` | container | compute: what runs software |
| ▣ | `machine` | TAPPaaS node | compute: what runs software |
| ▭ | `device` | managed device | compute: what runs software |
| ▪ | `resource` | resource | assets: physical things and their parts |
| ▮ | `asset` | asset | assets: physical things and their parts |
| ▤ | `server` | server | assets: physical things and their parts |
| ⇄ | `network-device` | switch or access point | assets: physical things and their parts |
| ϟ | `appliance` | modem, ONT or UPS | assets: physical things and their parts |
| ▦ | `passive-device` | patch panel or PDU | assets: physical things and their parts |
| ▱ | `other-device` | other device | assets: physical things and their parts |
| • | `port` | port | assets: physical things and their parts |
| ◍ | `disk` | disk | assets: physical things and their parts |
| ◔ | `pool` | consumable pool | assets: physical things and their parts |
| ⋈ | `network-element` | network element | network: what the network is made of |
| ⬡ | `zone` | zone | network: what the network is made of |
| ≋ | `ssid` | wireless network | network: what the network is made of |
| ⌖ | `address` | IP address | network: what the network is made of |
| @ | `dns-name` | DNS name | network: what the network is made of |
| ↪ | `proxy-route` | proxy route | network: what the network is made of |
| ✦ | `certificate-authority` | certificate authority | network: what the network is made of |
| ⇌ | `vpn-peer` | VPN peer | network: what the network is made of |
| ⊟ | `storage-element` | storage element | storage: what storage is made of |
| ◒ | `storage-pool` | storage pool | storage: what storage is made of |
| ⋔ | `share` | share | storage: what storage is made of |
| ↺ | `datastore` | backup datastore | storage: what storage is made of |
| ⇆ | `backup-peer` | backup buddy | storage: what storage is made of |
| ◇ | `software` | software | software: what runs in a node |
| ◈ | `app` | application | software: what runs in a node |
| ⊙ | `service` | service | software: what runs in a node |
| ⟳ | `controller` | controller | software: what runs in a node |
| ☰ | `manager` | manager | software: what runs in a node |
| I | `identity` | identity | identity: users, groups, roles |
| O | `organization` | organization | identity: users, groups, roles |
| G | `group` | group | identity: users, groups, roles |
| U | `user` | user | identity: users, groups, roles |
| R | `role` | role | identity: users, groups, roles |
| ⊕ | `place` | place | places: where things stand |
| ⌂ | `location` | location | places: where things stand |
| □ | `room` | room | places: where things stand |
| ▯ | `rack` | rack | places: where things stand |
| ◌ | `collection` | collection | collections: what groups other objects |
| ◆ | `site` | site | collections: what groups other objects |
| ⁂ | `cluster` | cluster | collections: what groups other objects |
| E | `environment` | environment | collections: what groups other objects |
| ○ | `object` | CMDB object | other: the roots of the class tree |
| ● | `ci` | configuration item | other: the roots of the class tree |

<!-- class-symbols:end -->

## Tests

```bash
./test.sh
```

The fast tier builds the controller, starts a throwaway PostgreSQL in a temp
directory (`initdb` + `pg_ctl`, no TCP) and the service on a temp socket, and
runs the CLI against it — see the header of [`test.sh`](./test.sh) for what it
covers. It needs `pg_ctl`, `node`, `tsc`, `curl` and `jq`, and re-enters itself
under `nix-shell` when they are missing. PostgreSQL does not run as root: run
it as `tappaas`.

On the mothership, after the OS rebuild, check the live parts by hand:

```bash
systemctl status cmdb.service cmdb-db.service postgresql.service
ls -l /run/cmdb/cmdb.sock          # srw-rw---- tappaas, in a 0750 directory
cmdb class list && cmdb query
sudo systemctl start cmdb-dump && ls -l /var/lib/cmdb/dump/
```
