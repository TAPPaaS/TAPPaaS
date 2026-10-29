# cmdb-controller — design

ADR-040 decides the what; this is how step 1 builds it.

## Shape

```
 managers, bash ──cmdb CLI / lib/ts/src/cmdb.ts (curl)──┐
 console ── 127.0.0.1:9098 + token ─────────────────────┤
                                                        ▼
                        cmdb-controller serve (node, as tappaas)
                          server.ts   routes, auth, SSE
                          store.ts    report / query / show / history / impact / resolve
                          metamodel.ts  metamodel/*.json → checks, keys; → the metamodel tables
                          pg.ts       one connection, wire protocol v3
                                                        │ /run/postgresql, peer
                                                        ▼
                                    PostgreSQL: database cmdb (cmdb-v1.sql)
```

- **No npm dependencies.** TAPPaaS's TypeScript builds with `tsc` alone
  (`lib/nix/ts-manager.nix`), so the PostgreSQL client is the protocol itself
  (`pg.ts`): startup, the extended query for parameterised statements, the
  simple query for the schema file, text formats, no password authentication.
  About 300 lines, for exactly what the controller uses.
- **One connection, one statement at a time.** The controller is the only
  writer and its batches are small. A report holds the connection from BEGIN to
  COMMIT; queries queue behind it. A pool would add concurrency the store has no
  use for. If PostgreSQL drops the connection the service exits 75 and systemd
  starts it again; reporters spool meanwhile.
- **The client is synchronous** (curl per call), because the managers are: they
  run `spawnSync` from top to bottom. The CLI uses the same client, so a script,
  a manager and the CLI go through one code path.

## The store

The eight tables of D13 (`schema/cmdb-v1.sql`). Beyond the columns D13 lists:

| Column | Why |
|---|---|
| `attribute_def.spec` (jsonb) | the rest of a field's declaration (enum, items, relation, direction, otel, allowedBy, derived) as the metamodel file has it, so a reader of the table sees what the controller checks |
| `relation_type`: one row per (name, from, to) | a relation joins several pairs of classes (`runs-on`: vm → machine, software → node); the key is the triple |
| `object.last_seen`, `object.seen` | `lastSeen` and `sources[]` of D3's `object`: when each reporter last reported it. Kept on the row, not as attribute history: every observation would otherwise write a row |
| `attribute.change`, `relation.change` | the report that wrote the row, so a value's history links to its job (D6) |
| `change.kind`, `source`, `objects`, `relations`, `drift` | an observation is recorded as well as a change, so the change stream and an object's history show both |

The schema version is the comment on table `object` (`cmdb schema 1`), not a
ninth table. Each `cmdb-v<N>.sql` above the recorded version is applied at
start; a store newer than the build is refused. v1 is idempotent; a change to
the eight tables is an ADR-025 migration and a `cmdb-v2.sql`.

**Validity.** A value's row holds `tstzrange(from, to)`; the current one is
open at the upper end. The exclusion constraint (`btree_gist`) makes overlap
impossible. A report time earlier than the current row's start (a spooled
report replayed after a newer one) is recorded at that start instead, so
history stays a sequence; a row closed at its own start is empty and history
leaves it out.

**Nothing is deleted.** `end` sets `object.ended`, closes the object's open
relations and sets `stage` to `retired` (a CI) or `disposed` (a resource). The
attributes keep their last periods open: "what was it when it ended" is the
current row of an ended object.

## Identity (D5)

A class's keys are its fields with a `key` rank; fields of one rank form one
key, tried lowest rank first. A key is looked up among live objects of the
classes, in the reporting class's **scope** (its nearest abstract ancestor),
that have the same key: a vm's VMID is matched among vms and lxcs; `name`,
which every node class keys on, across vm, lxc, machine and device — and a hit
of another class is a conflict, not a merge. A relation field can be part of a
key (a port is its name on its asset; software its name and version on its
node). Outcomes:

- no complete key in the report: refused (it cannot be identified);
- a key matching two objects: conflict;
- two keys matching two different objects: conflict;
- a match of another class, or under another name: conflict (a name is
  immutable; a renamed CI is a new one, D7);
- otherwise the match, or a new object.

Not built yet: D5's "then any port's MAC" for an asset, and the class expiry
that makes a CI `unseen`. Both come with the reporters that need them.

## Checks

Before a row is written: the class exists and is concrete; every attribute is
a field of the class or an ancestor, not derived, of its type (enum and array
items included); a relation field's target is an allowed end of its relation
type; required fields are present on create; immutable fields keep their value;
`allowedBy` holds over the merged state (stored values with the report's on
top). Problems are collected for the whole batch and returned together; the
transaction is rolled back.

## Drift (D6)

An observation that changes a stored value (an attribute or a relation field)
writes the `drift` attribute: since when, which source, each attribute's old
and new value, and the object's `desired` reference. More drift merges into it
(a new period). A change report that touches the object closes it. ADR-020's
differ (step 6) will supply the comparison with desired state; until then
"no change behind it" means: not reported as a change.

## Impact

A recursive CTE over current relations, both directions by default, each object
once at its shortest distance, with the relation type it was reached by. No
per-type direction yet: `runs-on`, `part-of` and `allocated-to` point different
ways, and "what does a down node take with it" crosses all three.

## What step 1 leaves to later steps

| Later | Here |
|---|---|
| Reports from the managers (step 2) | `rescan.ts`'s `RESCAN_SOURCES` is empty; the service's sandbox (`ProtectHome=read-only`) will need `config/` writable for the sources it runs |
| asset-manager, `positions.json` migration (step 3) | the classes and relations are in the metamodel |
| The console's views (step 4) | the loopback listener and the token; the change stream |
| Unseen CIs, MAC keys, per-relation impact direction | see above |
