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
| `cmdb query [<class>] [--physical] [--recorded] [--where k=v]… [--at TIME] [--all]` | the objects of a class and all its subclasses (`cmdb query asset` lists servers and switches; `cmdb query --physical` is the Physical view); `--where` matches an attribute (a JSON value, or a bare word as a string; an array attribute matches when it contains the value; `health.status=critical` is a path into an object value); `--recorded` only what an operator recorded; `--at` as of a time; `--all` includes retired and disposed objects |
| `cmdb relations [--type T] [--from O] [--to O] [--from-class C] [--to-class C] [--recorded] [--at TIME]` | relations by type and either end (`O` as `<object>`), each with both ends, attributes, source and recorded; the classes include subclasses. What a topology is read from |
| `cmdb history <object> [--at TIME]` | every period of every attribute and relation, with its source; with `--at`, the object as it was then |
| `cmdb impact <object> [--hops N] [--direction in\|out\|both]` | everything within N current relations (default 2, both ways), each at its shortest distance with the relation it was reached by |
| `cmdb report [--file F]` | a report (below) from stdin or a file; spooled when the service does not answer |
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
  name reported again is a new object (D7).
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
| `GET /v1/classes`, `GET /v1/classes/<name>` | | the metamodel |
| `GET /v1/stream` | | server-sent events: `event: change` with the change's id, kind, source, job, verb, time, objects, relations, drift |

```bash
curl -s --unix-socket /run/cmdb/cmdb.sock -X POST http://cmdb/v1/query \
  -d '{"class": "asset", "where": {"vendor": "hp"}}'
```

## The metamodel files

[`metamodel/ci.json`](./metamodel/ci.json) (the root `object` and the `ci`
branch), [`resource.json`](./metamodel/resource.json),
[`place.json`](./metamodel/place.json) and
[`relations.json`](./metamodel/relations.json) are loaded into the metamodel
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
- `volatile`: the value changes by itself (`health`, `used`, `leaseUntil`,
  `lastSeen`, `stage`, `state`, `quorum`): it has history like any other, and
  never counts as drift.

On a class: `expiry` (`7d` on `ci`, inherited) — how long a CI may go
unreported before it is unseen; `keyVia` — a key that is a field of a related
object (an asset's ports' MACs, rank 2).

A subclass that declares an inherited field again with only some properties
refines it (`vm` makes `name` a key of rank 2). A new class goes through
ADR-022h's gate, under an existing abstract class; nothing adds a root.

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
