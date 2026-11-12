# ADR-049 — Declarative Health Rules

| | |
|---|---|
| **Status** | **Draft** — for the operator's review |
| **Version** | 0.1 |
| **Date** | 2026-11-12 |
| **Author** | Lars Rossen |
| **Deciders** | @LarsRossen |
| **Closes / addresses** | Amends ADR-041 D3 (derivation: the correlation rules become six kinds of record, and the logic at each node is data) and D2 (how a source's finding becomes a condition). Amends ADR-046 D6 (its shipped correlation rules become records). Builds on the review in [`docs/plans/health-cmdb-review.md`](../plans/health-cmdb-review.md). Related: ADR-040 (CMDB, metamodel), ADR-039 (module alert rules: the pattern for a module file), ADR-047 (central and site decisions: the layering this ADR does *not* copy), ADR-034 (console). |
| **Changelog** | v0.1 (2026-11-12): first draft, from the operator's direction of 2026-11-11 and his answers on cross-module rules, the update merge, escalation and raising severity. The proposal was tested against a prototype before it was written down; what changed because of that is in *What changed from the proposal*. |

Health propagation and root-cause selection are one algorithm in `derive.ts`. Part of what it
decides at each object is data already (`health-rules.json`: which failure crosses which
relation); the rest is code: redundancy groups, "explains only its own type", roll-ups, which
classes carry their own score, what follows its parent, and that every Grafana alert is a warning.
This ADR keeps one hard-coded engine and moves every decision made *at a node* into declarative
records with one match language. Core and modules ship them, a site edits them through verbs and
the console, and an update merges new releases without touching what the site changed.

## Context

### What is decided in code today

| Where | What is hard-coded |
|---|---|
| `derive.ts` `spread` | A redundancy group crosses at the rule's impact only when every member is down; partly down gives a `warning`. A crossing keeps the failure's type. |
| `derive.ts` `reachedBy`, `covered` | A failure explains only a condition of its own type, at no lesser status. A root is hidden only when a critical impact reached its object. |
| `derive.ts` `OWN_SECURITY` | A zone's and an environment's `security` is their own score, derived, never a root, and not replaced by the roll-up. |
| `derive.ts` `membersOf`, `rollUp` | Who a site, a collection and a place are the sum of; the worst member wins. |
| `health-rules.ts` `FOLLOWS` | A port and a disk follow their asset, an asset its node. |
| `relations.json` `dependant` | Which end of a relation is hurt. A rule cannot cross a relation the other way. |
| `assess-sources.ts` `fromAlerts` | Every alert is `operational` `warning`, except two named ones that are `security`. |

What a site or a module can change today is one thing: add or edit a propagation rule in a file
inside the Nix store. There is no local edit, no merge, and no way to say "this alert is critical
here".

### How the proposal was tested

The proposal (six kinds of record, one match language, "most specific wins", three layers) was
implemented as a throwaway prototype outside the repository: 480 lines of TypeScript with the
same inputs and outputs as `derive.ts`, driven only by records. It was then run against the code
on `fix/health-review`:

| Test | Result |
|---|---|
| `derive.test.ts`, unchanged, against the prototype with today's rules as records | 78 of 78 checks pass |
| Differential run: 13,000 random sites (two to three nodes, pools on mirrored disks, bonded uplinks, HA guests, `depends-on` loops, five condition types), `derive.ts` against the prototype | Identical root lists and conditions on every site, except the wording of 51 impact messages, where the prototype names the earliest failed member of a group and `derive.ts` the first in iteration order |
| New cases the proposal asks for: a 3-node quorum, a type-changing rule, a cross-type explanation, a raising rule, a raising cycle | All terminate and give the intended roots, after three engine rules were added (D6) |
| Static conflict detection over the ported core records plus deliberately conflicting ones | Every conflict found; the core set alone has none |
| 1,161 objects, 2,255 relations, 148 failing conditions, 300 records | 67 ms for a whole derivation, unoptimised (`derive.ts`: 34 ms); the pairwise conflict check 5 ms |

The prototype and its harness are in the sessions' shared notes folder
(`health-rules-prototype/`). They are evidence for this ADR, not the implementation.

The differential run also found two faults in today's `derive.ts`, listed in *Found on the way*.
They must be fixed before P1, or the golden comparison would preserve them.

## Decision

### D1 — One engine, six kinds of record, five stages

The engine is code and is the same on every site. At each point where it has to decide something
about a particular node, edge or condition, it asks the records.

| Stage | The engine does | The records decide (kind) |
|---|---|---|
| 1. Classify | Places each source's finding on a CI, settles it against what is stored, ages it, applies acknowledgements and maintenance | `classify`: the condition type, status and reason a finding becomes |
| 2. Spread | Builds the graph from the CMDB's relations and computes the least fixpoint of "what reaches what" | `propagate`: whether and as what a failure crosses an edge. `combine`: how edges that back each other up count together |
| 3. Roots | Finds which failing conditions are explained by another and which stand as root causes; counts impact | `explain`: which arriving failure explains, or covers, which own condition |
| 4. Follow | Colours what nothing judges | `follow`: whose colour it takes |
| 5. Roll up | Sums collections and places from a snapshot of stages 1 to 4 | `rollup`: who the members are and how they are summed |

After stage 5 the engine writes the conditions and `emit` tells the changes; the notice
lifecycle, flapping and the digest are unchanged and are not rules (D12).

### D2 — Invariants no record can break

These hold by construction in the engine. A record that would need one broken cannot be written
in the schema, or is clamped at run time, so `rules check` does not have to be trusted for them.

1. **A critical is never the symptom of a warning.** An arriving failure explains or covers an
   own condition only up to the status of the *root* it came from, whatever the rules on the way
   did to its severity (D6).
2. **Only the owner clears.** A record never turns a failing finding into `ok` or `unknown`, and
   never touches an `ok`. A condition goes away when its source takes it back.
3. **A record re-rates or routes; it never deletes.** `classify` has no "drop" outcome. Quieting
   one condition on one CI is what an acknowledgement is for: it has an author, a note and an end.
4. **Records read inputs only.** A match may read the CMDB (classes, attributes, relations) and
   the source's finding. It may not read what the engine derived (an impact, a root, a roll-up).
   This is what keeps the spread a monotone computation with one answer (D6).
5. **Rules do not invent edges.** A failure travels only along a relation that is in the CMDB.

### D3 — The record and the match language

Every record has the same envelope:

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

- `id` is stable for the life of the rule, never reused, and starts with its origin: `core.`,
  `<module>.` or `site.`. The origin is where the record was released from (D7); it is not a
  priority.
- `when` is the match. Everything else is the outcome, which differs per kind (D5).
- `enabled: false` ships a rule that does nothing until a site turns it on.
- `overrides` names records this one beats where both match (D4).

**Selectors.** `when` is built from selectors; which ones a kind has is in D5.

| Selector | Fields | Reads |
|---|---|---|
| an object (`object`, `provider`, `dependant`, `from`, `to`) | `class` (the class or any subclass), `name`, `id`, `attr: {name: predicate}`, `module`, `zone`, `environment` | the CI or resource |
| an edge | `relation` (a type or a list), `edge: {attr: {name: predicate}}` | the relation row |
| a condition (`condition`) | `type`, `status`, `reason` | the failure that is crossing or being explained |
| a finding (`finding`) | `source` (the owner: `alerts`, a gate's name, `sweep`, `thresholds`, `observations`, `cve`, `performance`), `type`, `status`, `reason`, `labels: {name: predicate}`, `age` | what a source reported, before it is a condition |

**Predicates.** A literal (`"dmz"`, `true`, `3`) is equality. A list is "one of". `{"exists":
true}` is "set to something" (today's `dependant: {haNode: true}`). `{"glob": "alert-*"}` is a
pattern with `*` at either end only. `age` is `{"over": "24h"}`. There is no negation: an
exception is written as a more specific record (D4), which keeps "is A more specific than B"
decidable. Numeric comparison is an open question (O6).

`module` is the module a CI belongs to (an instance of it, or what runs on that instance).
`zone` and `environment` read the CI's attributes of those names.

### D4 — The more specific record wins; overlap without an order is a conflict

*Changed from the proposal, which scored specificity on field count and kind as in CSS, with ties
going to the layer.*

For one decision (one edge and failure, one finding, one object) several records may match.

1. A record that another matching record names in `overrides` is out.
2. A record is out if another matching record is **strictly more specific**: everything it
   matches, the other matches too, and not the reverse. `{relation: runs-on, dependant.haNode
   set}` is strictly more specific than `{relation: runs-on}`; `class: vm` than `class: node`;
   `name: nextcloud` with a zone than the zone alone.
3. If the records left agree on the outcome, that is the outcome.
4. If they disagree, it is a **conflict**. `rules check` finds every conflict statically, from
   the records alone, and refuses the set (D11). Should one ever be evaluated, the engine takes
   the more severe outcome, so the result is still deterministic, and reports it as a `drift`
   warning on the site.

Why not a score. Counting fields does not say which of `dependant.haNode set` and
`dependant.zone = dmz` should win for an HA guest in the DMZ: both have one field. A score picks
one silently; a tie-break by layer or file order picks one for a reason the operator cannot see.
Under D4 the two are a conflict until one names the other in `overrides`, and then the answer is
written in the rule. The prototype's check found exactly these pairs in a test set and none in
the ported core records. Strict specificity is cheap to decide because there is no negation and
globs are prefix or suffix only.

Layer never enters. A site that wants a core rule to behave differently edits that rule (D7). A
site that wants an exception for one object writes a record that names the object, which is more
specific than anything shipped.

### D5 — The six kinds

#### `classify` — what a finding becomes

Replaces "every Grafana alert is an operational warning" and the two named security alerts, and
is the one place a site sets a severity. It applies to every source, not only alerts.

`when`: `finding`, `object`. Outcome: `set: {type?, status?, reason?}`, where `status` is
`warning` or `critical` and applies only to a failing finding (D2.2); and `aggregate: true`,
which marks the condition as a sum of others: derived, never a root.

```json
{ "id": "core.classify.alert", "kind": "classify",
  "description": "An open alert is a warning on what it is about: the mail went, a rule never fails the site.",
  "when": { "finding": { "source": "alerts" } },
  "set": { "type": "operational", "status": "warning" } }

{ "id": "core.classify.alert-security", "kind": "classify",
  "when": { "finding": { "source": "alerts", "labels": { "alertname": ["RootKeyChanged", "FirewallCertChanged"] } } },
  "set": { "type": "security", "status": "warning" } }

{ "id": "core.classify.zone-score", "kind": "classify",
  "description": "A zone's and an environment's CVE score is the sum of their modules': never a root.",
  "when": { "finding": { "source": "cve" }, "object": { "class": ["zone", "environment"] } },
  "aggregate": true }
```

A local severity override, raising and lowering:

```json
{ "id": "site.classify.backup-failed-nextcloud", "kind": "classify",
  "description": "A failed backup of nextcloud is critical here: it holds the family's photos.",
  "when": { "finding": { "source": "alerts", "labels": { "alertname": "BackupJobFailed" } },
            "object": { "name": "nextcloud" } },
  "set": { "status": "critical" } }

{ "id": "site.classify.lab-pool-full", "kind": "classify",
  "description": "The lab pool is scratch space; full is a warning.",
  "when": { "finding": { "reason": "pool-usage", "status": "critical" }, "object": { "name": "tanklab" } },
  "set": { "status": "warning" } }
```

A re-rated condition keeps what its source said beside what the rule made of it:
`raw: {status, since, rule}`. The owner still clears it, `since` of the effective status is when
the effective status changed, and `raw.since` is when the source's did. `age` reads `raw.since`
(D6, "time").

What does not become a `classify` record: thresholds. That a pool is a warning at 85 % or a
latency at 20 ms for 15 minutes is a parameter of the check that looks (ADR-046 D5's declared
thresholds, the usage thresholds in `assess-sources.ts`). A source reports a finding with a
status; `classify` may then re-rate it. The alerts that only echo health itself
(`HealthDailyDigest`, `CveLevelUp`, …) stay excluded in the source: that is loop prevention, not
policy.

#### `propagate` — whether and as what a failure crosses an edge

Replaces `health-rules.json`.

`when`: `relation`, `provider`, `dependant` (or `from`, `to` for a relation both ends depend on),
`edge`, `condition`. Outcome: `as: "none"` or `as: {status, type?}`; optionally `dependantEnd`.

- `status` is `warning` or `critical`. It may be lower than, equal to or **higher than** the
  failure's own status: a rule may raise.
- `type` changes the failure's type on the far side (a slow pool that is an `operational`
  degradation of one database). Without it the type is kept, as today.
- `as: "none"` is an exception: the failure does not cross here, where a general rule says it does.
- `dependantEnd: "from" | "to"` names the hurt end for this rule. Without it the rule uses the
  end `relations.json` declares, and applies only to `required` relations, as today. With it a
  rule can cross a relation the metamodel gives no dependant (`placed-in`: a room without power
  takes what is in it) or cross one against its declared direction (`member-of` from the nodes to
  their cluster, below).
- `condition.reason` matches only the provider's own source condition, so a rule can say
  "node-down crosses, a standing `lan-uplink` advisory does not".

Each status has its own rules, as today: a critical does not also fire the warning rules.
`rules check` reports a relation where a warning crosses and a critical does not (D11).

Today's eleven rules are nine records (the two performance statuses fold into a list):

```json
{ "id": "core.propagate.runs-on.down", "kind": "propagate",
  "when": { "relation": "runs-on", "condition": { "type": "operational", "status": "critical" } },
  "as": { "status": "critical" } }

{ "id": "core.propagate.runs-on.down-ha", "kind": "propagate",
  "description": "An HA-protected guest whose node fails is moving or has moved: degraded, not down.",
  "when": { "relation": "runs-on", "dependant": { "attr": { "haNode": { "exists": true } } },
            "condition": { "type": "operational", "status": "critical" } },
  "as": { "status": "warning" } }

{ "id": "core.propagate.depends-on.down", "kind": "propagate",
  "when": { "relation": "depends-on", "condition": { "type": "operational", "status": "critical" } },
  "as": { "status": "critical" } }

{ "id": "core.propagate.member-of.down", "kind": "propagate",
  "when": { "relation": "member-of", "condition": { "type": "operational", "status": "critical" } },
  "as": { "status": "critical" } }

{ "id": "core.propagate.connects.down", "kind": "propagate",
  "when": { "relation": "connects", "condition": { "type": "operational", "status": "critical" } },
  "as": { "status": "critical" } }

{ "id": "core.propagate.built-on.down", "kind": "propagate",
  "description": "A failed disk takes its pool down; in a mirror or raidz vdev the group rule degrades it first.",
  "when": { "relation": "built-on", "condition": { "type": "operational", "status": "critical" } },
  "as": { "status": "critical" } }

{ "id": "core.propagate.stored-on.down", "kind": "propagate",
  "when": { "relation": "stored-on", "condition": { "type": "operational", "status": "critical" } },
  "as": { "status": "critical" } }

{ "id": "core.propagate.stored-on.slow-pool", "kind": "propagate",
  "description": "A slow pool slows what is stored on it; it is not down, so the impact stays a warning.",
  "when": { "relation": "stored-on", "provider": { "class": "storage-pool" },
            "condition": { "type": "performance", "status": ["warning", "critical"] } },
  "as": { "status": "warning" } }

{ "id": "core.propagate.runs-on.slow-node", "kind": "propagate",
  "description": "A node under CPU or memory pressure slows the guests on it; they still run.",
  "when": { "relation": "runs-on", "provider": { "class": "machine" },
            "condition": { "type": "performance", "status": ["warning", "critical"] } },
  "as": { "status": "warning" } }
```

**HA** is `core.propagate.runs-on.down-ha`: strictly more specific than
`core.propagate.runs-on.down`, so it wins for a guest with `haNode` set, with no special case.
(The proposal filed HA under `combine`; it is a rule that reads the dependant.)

#### `combine` — relations that back each other up

Replaces the all-down redundancy rule and its "partly down is a warning".

*Changed from the proposal, which described `combine` as merging what arrives at a node.* A
bond's two legs end on two different ports, and a mirror's members are relations of one pool: the
unit that is redundant is a **group of relations**, which may or may not share a dependant. So a
`combine` record selects edges and says how they group.

`when`: `relation`, `provider`, `dependant`, `edge`. Outcome: `groupBy` and `steps`.

- `groupBy: {"edgeAttr": "redundancyGroup"}` groups the relations that carry the same value
  (what the reporters set today). `groupBy: "dependant"` groups every matched relation of one
  type into one dependant.
- `steps` is a list of thresholds on how many members are down, each with what then crosses:
  `down: 1 | 2 | … | "half" | "all"` or `upFewerThan: k`, and `as: "warning" | "critical" |
  "rule"` (`rule` is what the `propagate` record gives). `half` is at least half, rounded up: of
  three it is two, of four two, of five three. A step may carry the `reason` the impact then has.
- A member is down when a provider on that relation, other than the dependant itself, is in the
  failing state being counted.
- Every step whose threshold holds applies, and the dependant gets the worst. `rules check`
  refuses steps that get softer as more members fail.

Today's behaviour:

```json
{ "id": "core.combine.redundancy-group", "kind": "combine",
  "description": "Relations in one redundancy group: one down degrades the dependant, all down is the failure itself.",
  "when": { "edge": { "attr": { "redundancyGroup": { "exists": true } } } },
  "groupBy": { "edgeAttr": "redundancyGroup" },
  "steps": [ { "down": 1, "as": "warning", "reason": "redundancy-degraded" },
             { "down": "all", "as": "rule" } ] }
```

**A 3-node quorum.** A cluster loses quorum when half its nodes are gone, and then every node is
hurt. `member-of` is declared with the node as the dependant, so the first record crosses it the
other way, and the group rule decides when:

```json
{ "id": "cluster.propagate.node-to-cluster", "kind": "propagate",
  "description": "A node that is down counts against its cluster's quorum.",
  "dependantEnd": "to",
  "when": { "relation": "member-of", "provider": { "class": "machine" }, "dependant": { "class": "cluster" },
            "condition": { "type": "operational", "status": "critical" } },
  "as": { "status": "critical" } }

{ "id": "cluster.combine.quorum", "kind": "combine",
  "when": { "relation": "member-of", "dependant": { "class": "cluster" } },
  "groupBy": "dependant",
  "steps": [ { "down": 1, "as": "warning", "reason": "quorum-reduced" },
             { "down": "half", "as": "rule", "reason": "quorum-lost" } ] }
```

With the shipped `core.propagate.member-of.down` taking the cluster's failure back to its nodes,
the prototype gives:

| Down | Cluster | Roots | Others |
|---|---|---|---|
| one of three | `warning`, "one of three … down" | the node | its guests critical; the other nodes untouched |
| two of three | `critical`, quorum lost | both nodes, each a root | the third node and its guests critical, naming the first |
| three of three | `critical` | all three nodes | |

The last two rows needed two engine rules that today's code does not have (D6): without them two
dead nodes explain each other through the cluster and one of them is no longer a root.

**Escalation, shipped dormant.** The operator sees no case for it now; the kinds allow it in two
forms and neither needs new engine code:

```json
{ "id": "core.combine.many-providers-degraded", "kind": "combine", "enabled": false,
  "description": "Three or more of what a module depends on degraded at once is an outage for it.",
  "when": { "relation": "depends-on" },
  "groupBy": "dependant",
  "steps": [ { "down": 1, "as": "rule" }, { "down": 3, "as": "critical" } ] }

{ "id": "core.classify.long-warning", "kind": "classify", "enabled": false,
  "description": "An operational warning nobody dealt with for a day becomes critical.",
  "when": { "finding": { "type": "operational", "status": "warning", "age": { "over": "24h" } } },
  "set": { "status": "critical" } }
```

#### `explain` — which arriving failure accounts for which own condition

Replaces "a failure explains only its own type" and "a root is hidden only by a critical impact".

*Changed from the proposal: `explain` answers two separate questions, and both are bounded by the
engine.* Today's code already distinguishes them:

- **derived**: the object's own condition *is* the arriving failure, seen from below (the guest
  stopped because its node did). It does not count for `validate` and is never a root.
- **covered**: the object's own condition is a failure of its own (a full disk), but while the
  arriving failure stands it is not listed or mailed as a root.

`when`: `cause: {type | sameType, status}` (the failure that arrived), `condition` (the own
condition), `object`. Outcome: `effect: "derived" | "covered" | "none"`. Records for `derived`
and records for `covered` are selected separately, so they never conflict with each other; `none`
is the exception in either.

```json
{ "id": "core.explain.same-failure", "kind": "explain",
  "description": "A failure that reaches an object explains its own condition of the same type.",
  "when": { "cause": { "sameType": true } }, "effect": "derived" }

{ "id": "core.explain.down-covers", "kind": "explain",
  "description": "While something critical has reached an object, its own failures are not roots of their own.",
  "when": { "cause": { "status": "critical" } }, "effect": "covered" }
```

Site examples: a cross-type explanation, and a trim of the cover.

```json
{ "id": "site.explain.slow-pool-alerts", "kind": "explain",
  "description": "A database timing out on a slow pool is the pool's problem.",
  "when": { "cause": { "type": "performance" }, "condition": { "type": "operational", "reason": { "glob": "alert-*" } },
            "object": { "name": "postgres" } },
  "effect": "derived" }

{ "id": "site.explain.security-stays-root", "kind": "explain",
  "description": "An expiring certificate is still mine to fix while the node is down.",
  "when": { "cause": { "status": "critical" }, "condition": { "type": "security" } },
  "effect": "none" }
```

What the engine fixes, whatever the records say: the arriving failure explains or covers only up
to the status it left its provider with, and never above its root's own status (D2.1); of two
failures that explain each other, the earlier is the root; a group's verdict never explains the
group's own failed members (D6).

#### `follow` — whose colour an unjudged object takes

Replaces `FOLLOWS`. `when`: `object`. Outcome: `relation` (the parent is on its `to` end) and
`types`.

```json
{ "id": "core.follow.port",  "kind": "follow", "when": { "object": { "class": "port" } },  "relation": "part-of",      "types": ["operational"] }
{ "id": "core.follow.disk",  "kind": "follow", "when": { "object": { "class": "disk" } },  "relation": "part-of",      "types": ["operational"] }
{ "id": "core.follow.asset", "kind": "follow", "when": { "object": { "class": "asset" } }, "relation": "allocated-to", "types": ["operational"] }
```

A followed colour is derived, never a root and never spreads, as today. A site that wants "a
switch that is down takes its ports with it" as a real impact writes a `propagate` record with
`dependantEnd` instead.

#### `rollup` — who a collection is the sum of, and how

Replaces `membersOf`, worst-of and `OWN_SECURITY`. `when`: `object`, optionally
`condition.type`. Outcome: `members` (`"all"`, or steps over relations: `relations`, `walk:
"inbound" | "outbound"`, `transitive`) and `fn`: `"worst"`, `"own"` (the object's own condition
stands, no sum), or `{"kOfN": {"warning": n, "critical": n | "half" | "all"}}`.

```json
{ "id": "core.rollup.site", "kind": "rollup", "when": { "object": { "class": "site" } },
  "members": "all", "fn": "worst" }

{ "id": "core.rollup.collection", "kind": "rollup", "when": { "object": { "class": "collection" } },
  "members": [ { "relations": ["member-of", "serves"], "walk": "inbound" } ], "fn": "worst" }

{ "id": "core.rollup.place", "kind": "rollup", "when": { "object": { "class": "place" } },
  "members": [ { "relations": ["placed-in", "at"], "walk": "inbound", "transitive": true },
               { "relations": ["allocated-to"], "walk": "outbound" } ], "fn": "worst" }

{ "id": "core.rollup.environment-score", "kind": "rollup",
  "description": "An environment's security is its own risk score, not the worst of its members.",
  "when": { "object": { "class": "environment" }, "condition": { "type": "security" } }, "fn": "own" }
```

`core.rollup.site` is strictly more specific than `core.rollup.collection` (a site is a
collection), and the score record than both for `security`. A roll-up is computed from a snapshot
taken before any roll-up, so a room does not count its rack's sum as a member (today it does,
depending on order: *Found on the way*). A roll-up is never a root and never spreads. A sum that
should spread, like the quorum, is a `combine`.

### D6 — The engine rules that make it sound

**The spread is a least fixpoint.** The state is the set of `(object, type, status)` that some
failure reached. Records only ever add to it: `propagate` adds a state on the far side of an
edge, a `combine` step adds one when a count is reached, and no match reads the state (D2.4).
The set is finite (objects × types × two statuses) and only grows, so the computation ends; and
because every rule is "if these are present, add that", the result is the same in whatever order
objects, relations and records are visited. Today's code is not order-free in which
member a "two of three down" message names; the prototype is.

What this rules out, on purpose: "partly down, *but not if* all are down", "cross *unless* the
dependant is already impacted". Such a rule reads the state negatively and has no single answer
on a cycle. The first is expressed as two thresholds; the second is not expressible.

**Raising rules and cycles.** A rule that raises (`warning` → `critical`) is still an "add", so
the fixpoint still ends, and a raising cycle settles at critical all the way round: tested. What
a raise must not do is make a real critical a symptom. Each crossing therefore carries two
levels: the impact it gives, and the level up to which it *explains*, which is the status it left
its provider with, capped by the root's own status. In the prototype a node with a `warning`,
raised to `critical` on its guests, impacts them critical, and a guest that had stopped on its
own and an application with a full disk both stay roots.

**A group's verdict never explains its own failed members.** In the quorum example the cluster's
failure travels back to its nodes. Without a rule, node A's failure reaches node B *through the
quorum B's own failure helped to lose*, and B becomes A's symptom: two dead nodes, one root. The
engine marks every crossing a group gave with the members that counted as down for it, and such a
crossing, and what follows from it, is not an impact on, an explanation of, or a cover for those
members. A healthy member is not on that list and is impacted normally.

**A group fed by its own verdict counts only what failed without it.** Once the cluster's
critical has reached the healthy third node, that node is in a failing state and would count as a
third member down. Where a group's verdict can reach its own members, the engine counts the
group's members from a run with such groups switched off. On every other site (every site today)
this costs nothing: there is one run.

**Type changes.** A crossing with `type` puts the failure in the new type on the far side; from
there it is matched by the rules for that type and explains own conditions of that type by
`core.explain.same-failure`. The prototype gives the same roots for "a slow pool explains a
database's timeout alert" written either as a cross-type `explain` or as a type-changing
`propagate`. They differ in what happens next: the `explain` changes nothing further, the type
change makes the guest's `operational` rules fire onward. Use `explain` to say "this symptom is
that cause"; change the type only when the consequences downstream differ.

**Time.** A derivation is a function of the snapshot and the clock. The only record that reads
time is `classify` with `age`, and it reads `raw.since`, when the *source's* status last
changed. If it read the effective `since`, an age-based raise would reset its own clock and
flip back on the next run. Windows (`for`), rates and flapping are not record matters (D12).

**Rule changes are not health changes.** Each assess run records the hash of the active rule set
(D11). On a run whose hash differs from the previous one, the transitions it causes are marked as
caused by the rules: they do not count toward flapping, and a notice that opens or closes says
"rules changed", so an edit cannot look like an outage or a recovery.

### D7 — Where rules live, and the merge on update

*Changed from the proposal, which had three layers and a site layer that patched by id.*

**Layers collapse.** There is one installed set. Every record in it has an *origin* (core, a
module, the site), which says who released it and when it leaves (a module's rules go with the
module). Origin is not a precedence: which record wins is D4 and nothing else. What the site
changed is state kept per rule, not a layer on top.

| What | Where | Written by |
|---|---|---|
| Released, core | `controller/cmdb-controller/metamodel/health/*.json` in the repository | maintainers |
| Released, module | `<module>-health.json` beside the module's JSON, as `<module>-alerts.json` is (ADR-039) | the module's author |
| Installed, effective | `config/health/rules/<origin>.json` (`core.json`, `nextcloud.json`, `site.json`) | the merge, the verbs, the console |
| As released, last installed | `config/health/base/<origin>.json` | the merge only |
| Local state | `config/health/state.json` | the verbs, the console, the merge |

The engine reads `config/health/rules/`. That is the one truth of what runs, and it is what the
operator edits. `base/` is a verbatim copy of what was last installed, so that "what did I
change" and "what did the release change" are both a diff. `state.json` holds, per rule the site
touched: `local` (`edited`, `deleted`, `added`), who, when, a note, and `reviewed` (the hash of
the release the site last looked at for this rule). A rule edited by hand in the file is found
by comparing it with `base/` and is treated like any other edit, author unknown.

**The merge** runs on every system update and on every module install, update and removal, per
rule id, over three versions: `base` (last installed release), `theirs` (the new release) and
`ours` (what is installed).

| ours compared with base | theirs compared with base | Result |
|---|---|---|
| same | new rule | added |
| same | changed | updated |
| same | gone | removed |
| edited | same | kept |
| edited | changed | **kept as edited**, marked *upstream changed* |
| edited | gone | kept, marked *upstream removed*; it is the site's rule now |
| deleted | same, changed or new again | stays deleted (*upstream changed* noted where it did) |
| deleted | gone | the tombstone is dropped |
| edited to the same as theirs | changed | in step; the local state is cleared |

Then `base` becomes `theirs`. So an update adds, changes and removes released rules; never
modifies or removes a rule the site edited; never re-adds one the site deleted.

The merge is per rule, not per field. If the site changed a rule's status and the release changed
its description, the rule stays exactly as the site left it. Merging fields automatically would
mean an update had modified a locally edited rule, which the operator ruled out; the field-level
merge is offered, not applied.

**A local edit when upstream also changed** is shown as three columns, field by field: as
released when edited, as it is here, as released now; with each field marked *changed here*,
*changed upstream* or *changed in both*. The operator takes the upstream rule whole, takes single
fields, or keeps theirs; keeping sets `reviewed` and the mark goes. Until then the rule runs as
edited and is listed as pending in `rules list`, in the console and once in the daily digest.

**Renames.** A released rule that replaces another says `replaces: ["old.id"]`. If the old one
was edited here, the merge keeps the edit, installs the new rule disabled, and marks the pair for
the operator: two rules for one case must not both run.

**A merge is checked before it is active.** The merged set goes through `rules check` (D11). If
a newly released rule conflicts with a local one, that rule is installed *held* (disabled, marked)
and the rest is activated. If the released files themselves do not parse or validate, nothing
changes and the site gets a `drift` warning. The rules that ran yesterday keep running either way.

### D8 — Module rules that cross into other modules

Settled: a module may write `propagate` rules that reach other modules' objects (the network
module to everything in a zone). The guardrails:

1. **Anchored at one end.** A module-origin record must name the module on one side: the
   `provider` or the `dependant` (or the `object`, the `finding`'s object) is selected by
   `module: <itself>` or by a class its controller or manager reports. A module can say how its
   failures hurt others and how others' failures hurt it. It cannot say how a third module's
   failure hurts a fourth. Core and site records are not restricted.
2. **Only along relations.** D2.5. To reach everything in a zone there has to be a relation from
   those things to the zone. Today a node's zone is an attribute only, so this example needs
   `member-of` to accept `[node, zone]`, reported from the declared `zone` field (O2):

   ```json
   { "id": "network.propagate.zone-down", "kind": "propagate",
     "description": "A zone that is down cuts off everything in it.",
     "when": { "relation": "member-of", "provider": { "class": "zone" }, "dependant": { "class": "node" },
               "condition": { "type": "operational", "status": "critical" } },
     "as": { "status": "critical" } }
   ```

3. **It cannot hide more than its root deserves.** D2.1 is the engine's: a module's raising rule
   makes more things red but cannot turn another module's critical into a symptom of the module's
   warning. A softening rule makes *more* roots, not fewer: what is no longer explained stands on
   its own. So the failure mode of a bad cross-module rule is noise, not silence.
4. **A module's `classify` records touch only its own findings**: alerts carrying its `module`
   label, findings on its objects.
5. **Reach is shown before it is active.** At install the merge simulates each new or changed
   rule on the site's snapshot and records its reach: the most objects one failure it matches can
   impact, with and without the rule. A module rule whose reach leaves the module is listed as
   such; one that reaches more than a quarter of the site's CIs is installed *held* until the
   operator accepts it (the console and `rules accept` show the number). The threshold is a
   `site.json` setting.
6. **Conflicts are refused, not resolved.** A module rule that conflicts with a core rule or
   another module's must name it in `overrides` or be more specific. The check runs in the
   repository's CI for shipped modules and at install on the site.
7. **One switch.** `rules disable --origin <module>` turns a module's rules off as local state;
   they stay off across updates.

### D9 — Verbs

All in `health-manager rules`, each a preview first and an apply second, as the console's jobs
are; each write goes through the check.

| Verb | Does |
|---|---|
| `list [--kind K] [--origin O] [--state edited\|pending\|held\|disabled\|deleted]` | The installed set, one sentence per rule, with its state and how many objects it matches now |
| `show <id>` | The record, its origin and state, what it matches now, what it overrides and is overridden by |
| `add <file>` · `edit <id> --set path=value …` · `edit <id> --file F` | A site rule; a change to any rule |
| `enable <id>` · `disable <id> \| --origin O` | `enabled`, as a local edit |
| `delete <id>` · `restore <id>` | A tombstone; back to as released |
| `diff <id>` · `take <id> [--field F]` · `keep <id>` | The three-way view; take upstream; mark as reviewed |
| `accept <id>` | Release a held rule (reach, or a resolved conflict) |
| `merge [--origin O]` | What the update and module-manager call |
| `check [--file F]` · `explain <object>` · `simulate …` | D11 |

### D10 — Console

Under Health, a **Rules** page:

- The list, grouped by kind, each rule as a sentence ("a critical `operational` on a `machine`
  crosses `runs-on` to a guest with `haNode` as a warning"), with origin, state, matches-now and
  reach. Filters for edited, pending, held, disabled.
- A rule's page: the sentence, the record, what it matches now, and its history (the file is in
  `config/`, so the history is its commits).
- Edit is a form built from the kind's selectors, not a JSON box; **Preview** runs `simulate` on
  the current snapshot with and without the change and shows the difference: roots that appear or
  go, objects whose colour changes, notices that would open or close. **Apply** writes it.
- A pending rule opens on the three-column view of D7.

On a CI's panel, **Why** (P4): the chain from `rules explain`, each hop with the record that
decided it, linking to the rule. The console stops computing root sets itself
(`ui/src/health.ts`, deferred in the review): with rules as data a second implementation in the
browser would drift at the first local edit.

### D11 — Tooling

**`rules check`** runs on every write, every merge, and in CI for released files.

| Finds | Released files | On a site |
|---|---|---|
| Schema, unknown class, relation, attribute, condition type | error | error |
| A conflict (D4) | error | error: the write is refused, a merged rule is held |
| A module record not anchored (D8.1) | error | error |
| `combine` steps that soften as more fail | error | error |
| A cycle of crossings that contains a raise | error | warning, named |
| A dependency cycle over what the rules can cross (today's check, now over the rules' own directions) | — | warning, as today |
| A warning that crosses where the critical does not | warning | warning |
| A record that can never win (always overridden or always less specific) | warning | warning |
| A record that matches nothing on this site | — | note |
| A class the record names that no installed module has | — | note: the rule is dormant |
| A contract scenario that no longer holds | error | warning; the write needs `--force`, and says so in `state.json` |
| Reach over the threshold (D8.5) | — | held |

**Contract scenarios** are small fixtures shipped beside the rules: a handful of objects, a
failure, and what must come out ("a node down: the node is the one root, its guests are
impacted"). Core ships the cases of `derive.test.ts`; a module may ship its own. They are the
check for "valid but wrong": a rule set can pass every static test and still stop naming a dead
node as a root.

**`rules explain <object>`** recomputes the current derivation with tracing on and prints, for
that object, each condition and how it came about: the finding and the `classify` record that
rated it; for an impact, the path from the root, hop by hop, with the `propagate` record, the
`combine` step and the count; for a derived or covered condition, the `explain` record; the
records that matched and lost, and why (less specific than, overridden by).

**`rules simulate --fail <object>[:type[:status]] … [--with F] [--without <id>]`** runs the
derivation on the current snapshot with extra failures, an extra rule file or a rule removed, and
prints the roots and impact, or with `--diff` the difference from now. It writes nothing. The
preview in the verbs and the console, and the reach in D8, are this.

**The rule-set hash**: SHA-256 over the active records in canonical form. Each assess run stores
it on the site CI's `assessment`; a notice carries its first eight characters; a derived
condition carries the id of the record that decided it. "Why did this mail go" then has an
answer after the rules have changed.

### D12 — What is not a rule

| Stays where it is | Why |
|---|---|
| Thresholds and `for` windows (ADR-046 D5, D6), rates ("five in ten minutes") | They need history. The source that has the history decides, and reports a finding. |
| Ageing of judgements, staleness of observations | A property of the evidence, the same for every rule. |
| Flapping | A property of the transition history, kept by emit. |
| Maintenance windows and acknowledgements, and that a root's acknowledgement covers its symptoms | Operator state with an author and an end. What a window covers is open (O4). |
| The notice lifecycle, which roots mail at once and which go to the digest | Open (O3); today critical non-performance roots mail at once. |
| Reachability over arbitrary paths ("is there any route to the internet") | Not a per-edge decision. It stays a check (`vlanreach`) that reports a finding. |
| Inferring a common cause from several symptoms | Removed in the review (L1) for naming wrong roots. Root cause stays deduction along declared dependencies. |

## Generality and soundness

**Can everything hard-coded today be expressed?** Yes; each was ported and run.

| Today | As records | Proof |
|---|---|---|
| The eleven rules of `health-rules.json`; a rule with `dependant` beats one without | Nine `propagate` records; strict specificity | `derive.test.ts` 78/78, the differential run |
| All-down redundancy, partly-down warning | `core.combine.redundancy-group` | same |
| HA guest degraded | `core.propagate.runs-on.down-ha` | same |
| Explains only its own type, at no lesser status | `core.explain.same-failure` plus the engine's explain level | same |
| A root hidden by a critical impact | `core.explain.down-covers` | same |
| `OWN_SECURITY` | `core.classify.zone-score` (aggregate) and the `own` roll-up | same |
| `FOLLOWS`, `membersOf`, worst-of | `follow` and `rollup` records | same |
| Alerts are operational warnings | `core.classify.alert*` | by construction; not in the prototype (P4) |
| Cable seen from both ends: the earlier is the root; cycles | Engine | same |

**The ADR-046 cases.**

| ADR-046 D6 | How |
|---|---|
| A slow pool slows what is stored on it; a slow node its guests; critical stays a warning impact | The two performance `propagate` records |
| "Six guests are slow" derives to their pool | `core.explain.same-failure`: a performance impact explains a performance condition |
| A slow node does not explain a guest that stopped | Same record: the types differ, so nothing explains it |
| A performance root on an object a warning reached stays a root | `core.explain.down-covers` asks for a critical cause |
| A threshold must hold for a window; "full in N days" | The source's (D12) |
| A missing metric is `unknown`, never critical | The source's; and `classify` cannot rate an `unknown` (D2.2) |
| Performance roots go to the digest | emit's (O3) |

**Is "most specific wins" predictable?** Not as a score. Cases that broke it: an HA guest in a
zone the site rates critical (two one-field rules); `class: vm` against `class: node` plus an
attribute; a broad site rule meant to replace a specific core one, which loses on specificity
although the site meant it. D4's answer is that containment is the only implicit order, anything
else is a conflict the check refuses, and `overrides` writes the order down. One finding from
the port: a record that lists two classes is not "more specific" than a record naming an
ancestor of only one of them, so a record that must
win over a class's general rule names one class.

**Does the fixpoint terminate and stay deterministic with k-of-n, escalation and raising?** Yes
(D6): states are only added, thresholds are "at least", matches read inputs only. Raising cycles
settle at the top. Oscillation between runs has one possible source, an age-based raise resetting
its own clock, and `raw.since` removes it. Determinism under reordered input: for shuffled objects,
relations and sources on 1,500 sites the prototype's roots and conditions are the same on all of
them, leaving aside the roll-up counts (*Found on the way*, 2, not fixed in the prototype
either); `derive.ts` differs on 7, in which member a group's message names.

**How do `explain` and root selection work with type changes?** D6: the arriving failure has the
new type on the far side and is explained from there. The level it explains to is its provider's,
capped by its root's, so neither a type change nor a raise can make a critical a symptom of a
warning.

**Performance at about 1,000 objects.** 67 ms for a whole derivation with 300 records in the
unoptimised prototype, against 34 ms for today's code, inside a run that takes seconds for its
sources. The winning record per (edge, type, status) depends on inputs only and is cached; with
an index by kind and relation the candidates per decision are a handful. Conflict checking is
pairwise per kind: 5 ms for 300 records. A reach simulation is one spread per matched provider:
at most a thousand spreads of a few milliseconds, at install only.

**What can a bad rule break, and is it caught before it is applied?**

| A rule that | Outcome | Caught |
|---|---|---|
| is malformed or names what does not exist | refused | check, before write |
| conflicts | refused or held | check, before write |
| floods (a common warning made a site-wide critical) | red everywhere, but real criticals stay roots (D2.1) | reach: held over the threshold; the preview shows it |
| softens too much (`as: "none"` on a real dependency) | more roots and more mail, not fewer | contract scenarios; the preview |
| rates a real critical down (`classify`) | no at-once mail for it | **not caught by the check**: it is valid. Bounded by D8.4 for modules; for the site it is the operator's decision, visible as `raw` on the condition, in `rules list --state edited`, and in the preview |
| raises round a cycle | everything on the cycle critical | check |
| never matches | nothing | check, as a note |

**What cannot be expressed.** The rows of D12, and three more: a rule that depends on what was
derived ("cross unless already impacted"), by design; a join that is not a relation (D2.5); and
numeric comparison on attributes, until O6 is decided.

## What changed from the proposal

1. **"Most specific wins" is containment, not a score, and a tie is a conflict** (D4). No layer
   tie-break. `overrides` is the explicit order.
2. **Layers collapse** into one installed set with an origin and local state per rule (D7).
   Origin decides lifecycle and the guardrails, never precedence.
3. **`combine` groups relations, not what arrives at a node**, and its steps are "at least"
   thresholds (D5). HA is a `propagate` record. The quorum needs a rule to cross `member-of`
   against its declared direction, so `propagate` gains `dependantEnd`.
4. **`explain` is two questions**, derived and covered, with the engine bounding both (D5, D6).
5. **Three engine rules were added** because the quorum case failed without them: the explain
   level capped by the root; a group's verdict never explains its own failed members; a group
   fed by its own verdict counts from a run without it (D6).
6. **`classify` is narrower and wider than proposed**: it covers every source, not only alerts;
   it cannot produce `ok`, cannot drop, and keeps the source's own status and time beside its own
   (D5). Thresholds are not `classify`.
7. **Matches read inputs only, and there is no negation** (D2.4, D3). This is the price of one
   answer on a cycle.
8. **Rules do not invent edges** (D2.5), so "everything in a zone" needs a relation (O2).
9. **Added to the tooling**: contract scenarios, reach, held rules, preview on every write,
   rule-caused transitions told as such (D6, D8, D11).
10. **A phase before P1** for the two faults below.

## Found on the way

Two faults in `derive.ts` on `fix/health-review`, found by the differential run. Neither is
fixed here (design only).

1. **A critical can be covered by a warning root.** `impacted` keeps the first root that reached
   an object and raises the status when a later root reaches it harder, so the pair can be "root
   A, status of B". `covered` then hides the object's own critical behind A. Three objects show
   it: a machine with a `performance` warning (earliest), a pool with an `operational` critical,
   and a guest on both with a full disk. The guest's `capacity` critical gets `rootCause` the
   machine, and its impact reads "critical: machine tappaas1: cpu-pressure". On 5,000 random
   sites, 24 had at least one critical covered by an object with no critical of its own. This is
   the invariant of D2.1 broken in today's code; the prototype names the root that gave the worst
   status and refuses the cover.
2. **Roll-up counts depend on the order objects are visited.** A room's members include its rack;
   if the rack was rolled up first, its sum is counted as a member ("2 of 2 members ok" against
   "1 of 1"). Statuses do not differ with worst-of; they would with k-of-n.

## Consequences

- One place decides each thing, and `rules explain` can say which record it was.
- A site can change health behaviour without a fork, and an update cannot undo it.
- `health-rules.json`, `FOLLOWS`, `OWN_SECURITY`, `membersOf` and the alert constants go.
  cmdb-controller keeps serving the metamodel (classes, relations) but no longer the rules;
  health-manager reads `config/health/rules/`.
- A condition gains `raw` (when re-rated) and `rule`; the site's `assessment` gains the rule-set
  hash. ADR-041 D1's shape is otherwise unchanged.
- More to learn: six kinds. The sentence form in the list and the form editor are how most
  operators will meet them; the JSON is for authors.
- The console's own root computation is removed rather than kept in step.
- A site that edits rules has rules nobody else has. `rules list --state edited` and the hash on
  every notice are what support needs to see first.

## Alternatives considered

| Alternative | Why not |
|---|---|
| A specificity score, as in CSS | Silent on equal scores; a tie-break by layer or order is a rule nobody wrote (D4). |
| First match in file order, as in a firewall | Predictable in one file. With core, several modules and local edits there is no natural order of files, and an update would reorder. |
| Explicit numeric priority on every record | Works, but every author must know every other number. `overrides` names the one rule it is about. |
| All matching records apply, worst wins | Cannot express an exception that softens (HA), which is the first rule shipped. |
| Keep three layers, the site layer patching by id (the ADR-047 pattern) | ADR-047's site layer holds a different kind of record (an acceptance) from the central one. Here the site changes the *same* rule, so a patch layer is a second copy of it that an update can make meaningless. |
| Field-level automatic three-way merge | An update would modify a rule the site edited (D7). |
| A general rule language (Datalog, CEL, Rego) | Far more than six kinds need, no "is this more specific" test, and negation brings back the cycle problem. |
| Rules that may read derived state | No single answer on a cycle; order-dependent results (D6). |
| Counterfactual root selection (recompute without each failing object) | Prototyped first. Right for two dead nodes of three, wrong for three (each is "explained" by the other two), and one extra spread per object on a cycle. The group-member rule is simpler and right in both. |

## Migration

| Phase | Content | Proof |
|---|---|---|
| **P0** | Fix the two faults of *Found on the way* in `derive.ts`, with tests | New cases in `derive.test.ts`; the 3-object case above |
| **P1** | The engine reads records; core records are today's behaviour (`propagate`, the one `combine`, the two `explain`, `follow`, `rollup`), still shipped in the metamodel. `rules list` and `check` over records, with the conflict check | `derive.test.ts`, `assess.test.ts`, `health-flow.test.ts` (the 2026-11-05 identity stop) unchanged and green. A differential suite keeps the old `derive` as an oracle: identical output on a few thousand random sites, in CI, for one release; then the old code goes |
| **P2** | `combine` steps and k-of-n, `dependantEnd`, type change, `explain` records, the three engine rules of D6; `rules explain`, `simulate`, the hash, contract scenarios | The quorum, raise and type-change cases as unit tests; core scenarios pass; shuffled-input determinism test |
| **P3** | `config/health/`, the merge, the verbs, module files and D8's guardrails; module-manager calls the merge | Merge table of D7 as a test per row; an update over an edited, a deleted and a conflicting rule on a scratch config; live on the test system: install a module with a rule, edit it, update |
| **P4** | `classify` and `raw`; the console's Rules page and the Why view; the console's own root computation removed | Alert findings identical with the core `classify` records; a local override raises and clears with its source; console review by the console-gui checklist |

Each phase is shippable alone. P1 changes no behaviour; P2 adds expressiveness nobody uses until
a rule does; P3 is the first that touches a site's `config/`.

## Open questions

- **O1. May a site rule quiet a condition completely?** D2.3 says no: the lowest a `classify`
  can set is `warning`, and silence is an acknowledgement, which has an end. A standing "this is
  only information here" would need a status below warning, or an acknowledgement without an end
  written by a rule. Recommendation: keep D2.3 and see whether sticky acknowledgements are enough.
- **O2. A relation from a node to its zone.** The cross-module example needs `member-of [node,
  zone]` (and `[app, zone]`), reported from the declared `zone` field. Recommendation: add it;
  the alternative, letting a rule join on an attribute, breaks D2.5 and hides the dependency from
  the graph and the cycle check.
- **O3. Is "which roots mail at once" a seventh kind?** Today: critical, not performance, not a
  CVE level. A site that wants a performance critical mailed at once can re-rate nothing to get
  it. A `notify` kind (root selector → at once, digest, none) would fit the same language.
  Recommendation: not in this ADR; decide after P4.
- **O4. What a maintenance window covers** is a hard-coded walk down `runs-on` (`windows.ts`). It
  could be "everything the window's object would impact if it failed", which is `simulate`, and
  would then follow the rules. That changes who is silenced (dependants over `depends-on` too).
- **O5. The `module` of a CI** is worked out from `config/` today (`moduleOfCi`). D8's anchoring
  and the `module` selector want it as an attribute in the CMDB.
- **O6. Numeric comparison in predicates** (`tier >= 4`, `cores < 2`). It is sound (inputs only)
  but "more specific than" needs interval containment. Recommendation: add `{"gte": n}` and
  `{"lte": n}` in P2 if a real rule needs one.
- **O7. Do rules ride the security stream (ADR-048)** so a correction reaches sites faster than
  a release? The merge does not care where `theirs` comes from.
- **O8. The reach threshold** of D8.5: a quarter of the site's CIs is a guess. The network
  module's zone rule will exceed it on most sites and be held at first install; is that the
  intended experience for a foundation module, or do foundation modules pass?
- **O9. Contract scenarios on a site that changed behaviour on purpose.** D11 makes a failing
  scenario a warning that needs `--force`. Should a site be able to retire a scenario, as it can
  delete a rule?
- **O10. A collection that takes part in the spread** (the cluster in the quorum example) also
  gets a roll-up, and today the roll-up of `impact` replaces its own impact condition, losing
  "quorum lost". Recommendation: a roll-up never replaces an impact the spread gave.
