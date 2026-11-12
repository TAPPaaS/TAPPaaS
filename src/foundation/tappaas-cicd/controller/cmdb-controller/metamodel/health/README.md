# Health Rules

TAPPaaS works out the health of a site in one engine, the same everywhere. Every
decision the engine makes about a particular object, relation or condition is a
**health record**: how a failure travels along a relation, which relations back each
other up, which failure explains which condition, whose colour an object takes, how
a collection sums up. This page is the language those records are written in, and
the standard records TAPPaaS ships.

The files here are the core records, one file per kind. `health-manager rules list`
prints the records in use as sentences; `health-manager rules check` checks them.
How the engine uses them is in [health-manager's design](../../../../manager/health-manager/DESIGN.md).

## A record

```json
{ "id": "core.propagate.runs-on.down-ha",
  "kind": "propagate",
  "description": "An HA-protected guest whose node fails is moving or has moved: degraded, not down.",
  "when": { "relation": "runs-on",
            "dependant": { "attr": { "haNode": { "exists": true } } },
            "condition": { "type": "operational", "status": "critical" } },
  "as": { "status": "warning" },
  "enabled": true,
  "overrides": [] }
```

- `id` is stable for the life of the record and never reused. It starts with its
  origin, who released it: `core.`, the module's name, or `site.`.
- `kind` is one of the kinds below.
- `when` is the match. Everything else is the outcome, which depends on the kind.
- `enabled: false` ships a record that does nothing until a site turns it on.
- `overrides` names records this one beats where both match.

## The match

`when` is built from selectors. Which ones a kind has is listed with the kind.

| Selector | Fields | Reads |
|---|---|---|
| an object: `object`, `provider`, `dependant`, `from`, `to` | `class` (the class or any subclass; a list is any of them), `name`, `id`, `attr: {name: predicate}`, `module`, `zone`, `environment` | the CI or resource |
| an edge | `relation` (a type or a list), `edge: {attr: {name: predicate}}` | the relation |
| a condition: `condition` | `type`, `status`, `reason` | the failure crossing, or the condition being explained |
| a cause: `cause` | `type` or `sameType: true`, `status` | the failure that arrived at an object |

A predicate is:

- a value (`"dmz"`, `true`, `3`): equal to it;
- a list: one of them;
- `{"exists": true}`: set to something (not empty, false or 0);
- `{"glob": "alert-*"}`: a pattern with `*` at either end only.

There is no negation. An exception is written as a more specific record.

A record matches only what is in the CMDB: it reads classes, attributes and
relations, and the condition at hand, never what the engine worked out. A failure
travels only along a relation that exists.

## Which record wins

For one decision several records may match.

1. A record another matching record names in `overrides` is out.
2. A record is out if another matching record is **strictly more specific**:
   everything it matches, the other matches too, and not the reverse. A record for
   `class: vm` is more specific than one for `class: node`; one that adds
   `haNode` set is more specific than one without it.
3. If the records left agree, that is the outcome.
4. If they disagree, it is a **conflict**. `rules check` finds every conflict from
   the records alone and refuses the set. Should one ever run, the more severe
   outcome is taken and the site is told.

Which file a record came from, or who released it, never decides. A record that
must win over a class's general record names one class: a record listing two
classes is not more specific than one naming an ancestor of only one of them.

## The kinds

### propagate — whether and as what a failure crosses a relation

`when`: `relation`, `provider`, `dependant` (`from`, `to` for a relation both ends
depend on), `edge`, `condition`. Outcome: `as: {"status": "warning" | "critical",
"type"?: …}` or `as: "none"`; optionally `dependantEnd`.

- The failure crosses from the provider to the end the metamodel declares as hurt
  (`relations.json`), only over a relation that is required.
- `status` may be lower than, equal to or higher than the failure's own: a record may
  raise. A raise still cannot make a real critical the symptom of a warning.
- `type` changes the failure's type on the far side (a slow pool that is an
  `operational` degradation of one database); from there the records for that type
  apply. Without it the type is kept.
- `as: "none"` is an exception: the failure does not cross here, where a general
  record says it does.
- `dependantEnd: "from" | "to"` names the hurt end for this record: it can cross a
  relation the metamodel gives no dependant, or cross one against its declared
  direction (a node counting against its cluster's quorum).
- `condition.reason` matches only the provider's own condition, so a record can say
  "node-down crosses, a standing advisory does not".

Each status has its own records: a critical does not also fire the warning ones.

```json
{ "id": "core.propagate.stored-on.slow-pool", "kind": "propagate",
  "when": { "relation": "stored-on", "provider": { "class": "storage-pool" },
            "condition": { "type": "performance", "status": ["warning", "critical"] } },
  "as": { "status": "warning" } }
```

### combine — relations that back each other up

`when`: `relation`, `provider`, `dependant`, `edge`. Outcome: `groupBy` and `steps`.

- `groupBy: {"edgeAttr": "redundancyGroup"}` groups the relations that carry the same
  value; `groupBy: "dependant"` groups every matched relation of one type into one
  dependant.
- `steps`: how many members are down, and what then crosses: `down: 1 | 2 | … |
  "half" | "all"` (half is at least half, rounded up: two of three, two of four) or
  `upFewerThan: k`, and `as: "warning" | "critical" | "rule"` (`rule` is what the
  `propagate` record gives). A step may name the `reason` the impact then has. Every
  step that holds applies, and the worst wins. Steps may not get softer as more
  members fail.

A member is down when a provider on that relation, other than the dependant, is
failing. The impact names the member that failed first. A group's verdict never
explains its own failed members, so two dead nodes of a cluster that lost quorum are
both roots.

```json
{ "id": "core.combine.redundancy-group", "kind": "combine",
  "when": { "edge": { "attr": { "redundancyGroup": { "exists": true } } } },
  "groupBy": { "edgeAttr": "redundancyGroup" },
  "steps": [ { "down": 1, "as": "warning", "reason": "redundancy-degraded" },
             { "down": "all", "as": "rule" } ] }
```

A cluster's quorum, written by the module that reports clusters:

```json
{ "id": "cluster.propagate.node-to-cluster", "kind": "propagate", "dependantEnd": "to",
  "when": { "relation": "member-of", "provider": { "class": "machine" }, "dependant": { "class": "cluster" },
            "condition": { "type": "operational", "status": "critical" } },
  "as": { "status": "critical" } }

{ "id": "cluster.combine.quorum", "kind": "combine",
  "when": { "relation": "member-of", "dependant": { "class": "cluster" } },
  "groupBy": "dependant",
  "steps": [ { "down": 1, "as": "warning", "reason": "quorum-reduced" },
             { "down": "half", "as": "rule", "reason": "quorum-lost" } ] }
```

### explain — which arriving failure accounts for which own condition

`when`: `cause`, `condition` (the object's own condition), `object`. Outcome:
`effect: "derived" | "covered" | "none"`.

- **derived**: the object's own condition is the arriving failure seen from below (a
  guest stopped because its node did). It does not count and is never a root.
- **covered**: the object's own condition is a failure of its own (a full disk), but
  while the arriving failure stands it is not listed or mailed as a root.
- **none**: an exception to a record of either effect that it is more specific than.

Whatever the records say, a failure explains or covers only up to the status it
left its provider with, and never above its root's own status: a critical is never
the symptom of a warning.

```json
{ "id": "core.explain.same-failure", "kind": "explain",
  "when": { "cause": { "sameType": true } }, "effect": "derived" }

{ "id": "site.explain.slow-pool-alerts", "kind": "explain",
  "description": "A database timing out on a slow pool is the pool's problem.",
  "when": { "cause": { "type": "performance" }, "condition": { "type": "operational", "reason": { "glob": "alert-*" } },
            "object": { "name": "postgres" } },
  "effect": "derived" }
```

Use `explain` to say "this symptom is that cause"; use a type change on `propagate`
only when the consequences further on differ.

### follow — whose colour an object nothing judges takes

`when`: `object`. Outcome: `relation` (the parent is on its `to` end) and `types`.
A followed colour is derived: never a failure or a root of its own, and it never
travels on.

```json
{ "id": "core.follow.port", "kind": "follow", "when": { "object": { "class": "port" } },
  "relation": "part-of", "types": ["operational"] }
```

### rollup — who a collection or a place is the sum of

`when`: `object`, optionally `condition.type`. Outcome: `members` (`"all"`, or steps
over relations: `relations`, `walk: "inbound" | "outbound"`, `transitive`) and `fn`:
`"worst"`, `{"kOfN": {"warning": n, "critical": n | "half" | "all"}}` (counted over
all the members, a member with no condition of the type counting as up), or `"own"`
(the object's own condition stands, no sum; such a condition is itself a sum of
others, never a root).

A roll-up reads its members as they are before any roll-up, is never a root, never
travels on, and never replaces an impact the spread gave: a cluster that lost quorum
keeps "quorum lost".

```json
{ "id": "core.rollup.place", "kind": "rollup", "when": { "object": { "class": "place" } },
  "members": [ { "relations": ["placed-in", "at"], "walk": "inbound", "transitive": true },
               { "relations": ["allocated-to"], "walk": "outbound" } ], "fn": "worst" }
```

## Contract scenarios

Beside the records, [`scenarios/`](./scenarios/core.json) holds small fixtures: a few
objects, a failure, and what must come out (`roots`, the `impact` on an object,
which conditions are `derived` or `covered`). A set of records can pass every static
check and still stop naming a dead node as a root; `rules check` runs every scenario
and refuses a set under which one no longer holds. A site that changed behaviour on
purpose can retire a scenario.

```json
{ "id": "core.scenario.covered-by-down",
  "objects": [ { "class": "machine", "name": "n1" }, { "class": "vm", "name": "g" } ],
  "relations": [ { "type": "runs-on", "from": "vm/g", "to": "machine/n1" } ],
  "conditions": [ { "object": "machine/n1", "type": "operational", "status": "critical", "reason": "node-down" },
                  { "object": "vm/g", "type": "capacity", "status": "critical", "reason": "disk-full" } ],
  "expect": { "roots": ["machine/n1"], "covered": ["vm/g:capacity"] } }
```

## Trying a record

`health-manager rules simulate --fail <object>[:type[:status]] … [--with F]
[--without <id>] [--diff]` runs the derivation on the site as it is now with extra
failures, a file of extra records, or a record taken out, and prints the roots, or
with `--diff` what changes. `health-manager rules explain <object>` prints, for each
condition of an object, how it came about and which record decided it, hop by hop,
with the records that matched and lost. Neither writes anything.

## The standard rules

<!-- standard-rules:begin (generated by `health-manager rules list --origin core --markdown`; do not edit) -->

**propagate**

- `core.propagate.runs-on.down`: a critical operational failure crosses runs-on to its dependant as a critical impact.
- `core.propagate.runs-on.down-ha`: a critical operational failure crosses runs-on to its dependant with haNode as a warning impact.
- `core.propagate.depends-on.down`: a critical operational failure crosses depends-on to its dependant as a critical impact.
- `core.propagate.member-of.down`: a critical operational failure on a cluster or environment crosses member-of to a node as a critical impact.
- `core.propagate.member-of.group-down`: a critical operational failure on a group crosses member-of to an user as a critical impact.
- `core.propagate.member-of.zone-address`: a critical operational failure on a zone crosses member-of to an address as a critical impact.
- `core.propagate.connects.down`: a critical operational failure crosses connects to its dependant as a critical impact.
- `core.propagate.built-on.down`: a critical operational failure crosses built-on to its dependant as a critical impact.
- `core.propagate.stored-on.down`: a critical operational failure crosses stored-on to its dependant as a critical impact.
- `core.propagate.stored-on.slow-pool`: a warning or critical performance failure on a storage-pool crosses stored-on to its dependant as a warning impact.
- `core.propagate.runs-on.slow-node`: a warning or critical performance failure on a machine crosses runs-on to its dependant as a warning impact.

**combine**

- `core.combine.redundancy-group`: relations with redundancyGroup count together by redundancyGroup: 1 down: a warning (redundancy-degraded); all down: the rule's impact.

**explain**

- `core.explain.same-failure`: a failure of the same type reaching an object with a condition of its own explains it: derived.
- `core.explain.down-covers`: a critical failure reaching an object with a condition of its own covers it: not a root while that stands.

**follow**

- `core.follow.port`: a port nothing judges takes the operational colour of what it is part-of.
- `core.follow.disk`: a disk nothing judges takes the operational colour of what it is part-of.
- `core.follow.asset`: an asset nothing judges takes the operational colour of what it is allocated-to.

**rollup**

- `core.rollup.site`: a site is the worst of everything that is not a sum.
- `core.rollup.collection`: a collection is the worst of what is member-of or serves it.
- `core.rollup.place`: a place is the worst of what is placed-in or at it, all the way, then allocated-to from it.
- `core.rollup.environment-score`: an environment's security is its own, not a sum of its members.
- `core.rollup.zone-score`: a zone's security is its own, not a sum of its members.
<!-- standard-rules:end -->
