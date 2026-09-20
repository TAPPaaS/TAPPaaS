# ADR-027 — Module Blueprint

| | |
|---|---|
| **Status** | **Draft** (2026-09-20) — for @LarsRossen and @ErikDaniel007 to agree before sign-off |
| **Version** | 0.2 |
| **Date** | 2026-09-20 |
| **Author** | Lars Rossen |
| **Related** | **#363** (origin: the artifact set) · **#248** (what `version` and `status` claim — built 2026-09-20) · [ADR-013](<ADR-013 - Documentation Structure and Standards.md>) (**the module's documents** — README, INSTALL, DESIGN, TEST: their audiences and obligation, not restated here) · [ADR-015](<ADR-015 - Community Governance and Contribution Files.md>) (**the contribution files** — AUTHORS and the community-health set: the companion to this ADR, which owns everything a module is made of that is *not* a document) · [ADR-011](<ADR-011 - SBOM Governance.md>) (the SBOM this blueprint will name once it is accepted) · [ADR-007](<ADR-007 - TAPPaaS Taxonomy.md>) (the module/manager/controller taxonomy and the verb dispatch) · [ADR-020](<ADR-020 - Declared-Field Change Model (validate, drift, modify).md>) (the service scripts and `fields.json` — what `update`, `modify` and `reconcile` do with them) · [ADR-026](<ADR-026 - Managed Machines as Modules.md>) D6 (a module is named by its directory; an instance is not a module) · [ADR-022](<ADR-022 - Workload Ontology.md>) / [ADR-022e](<ADR-022e - Module Scope.md>) (`kind`, `scope`, `management` — and `module.tier` retired in favour of `scope`) · `src/foundation/schemas/README.md` + `module-fields.json` (the field definitions themselves) |
| **Changelog** | v0.2 (2026-09-20) — documents and contribution files handed to ADR-013/ADR-015 and no longer listed here; the service directory gets its own decision (D3); D4 points at the schemas instead of describing fields; `stack: foundation` replaces the retired `tier`; `provisionedBy` dropped for a no-op `install.sh`; `test.sh` is a SHOULD; one severity for every module, with a sweep to clear the estate; the five open questions answered. · v0.1 (2026-09-20) — first draft |

Every TAPPaaS module is the same shape, so tooling and people can rely on it.

---

## Context

A module is the unit TAPPaaS installs, updates, tests and deletes (ADR-007; ADR-009
calls it the atomic deployable unit). What a module *is made of* has never been written
down in one place.

Two thirds of it already are, elsewhere: **ADR-013** settles the module's documents —
which document serves which audience, README and INSTALL mandatory for catalog
inclusion, DESIGN where internals are non-trivial — and **ADR-015** settles the
contribution files, AUTHORS among them. This ADR is their companion and covers the rest:
**the executable structure** — the module's own JSON, its scripts, and its service
directories. It does not restate a rule either of those two already makes.

The estate shows the drift that the missing half allows. Of 22 modules today, `network`
and `templates` carry no `install.sh` (the bootstrap and `cluster` create them),
`netbird-client` and `vaultwarden` carry no `test.sh`, and only `backup` and `satellite`
carry a `delete.sh`. Of 27 service directories, 15 are missing at least one of the six
files a service is made of — `identity/services/accessControl` is missing three.

Some of that variation is meaningful and some is drift, and nothing tells them apart.
The consequences are concrete:

- **A community author cannot know when a module is finished.** `00-Template` shows one
  possible shape, not the required one.
- **Tooling cannot check what it is not told.** `install-module.sh` skips a missing
  `install.sh` and `test-module.sh` skips a missing `test.sh` — silently, because both
  are legitimate for *some* module. So a module that simply forgot its tests installs
  and updates as if it had them.
- **Reviews argue from taste.** The documents were settled by ADR-013, the community
  files by ADR-015, `version` and `status` by #248. The executable artifacts never were.

## Decision

### D1 — the module directory is the module

Every artifact lives in the module's own directory, beside the others. No module keeps
part of itself elsewhere — not its documentation, not its service scripts, not its
fields. The directory's name is the module's name (ADR-026 D6.2), and `<module>.json`
inside it is the module's own file; an instance of it is named separately (D6.1) and
lives in `config/`, never here.

This is what makes the rest checkable: "does this module carry X?" is `test -f`.

### D2 — the executable artifact set

| Artifact | Level | Whose question it answers |
|---|---|---|
| `<module>.json` | **MUST** | the tooling's: what this module is, and the fields it declares (D4) |
| `install.sh` | **MUST** | `module add`: bring this module into being on this site |
| `update.sh` | **MUST** | the nightly sweep: take the release forward, idempotently (ADR-020) |
| `test.sh` | **SHOULD** | the update gate and `module test`: is it healthy, before and after a change |
| `fields.json` | **MUST** when the module declares fields of its own | the schema's: what those fields mean, composed into `module-fields.json` (#567) |
| `services/<service>/` | **MUST** for each service the module `provides` | a consumer's — D3 |
| `delete.sh` | **MAY** | only when deleting needs more than removing the guest and the config (the satellite's tunnel, the backup module's PBS) |
| `<module>-sbom.json` | **MAY** | a CVE report's: what is actually inside the guest (#143). Revisited when ADR-011 is accepted — D7 |

**MUST** means the module is incomplete without it and the check says so. **SHOULD**
means its absence is a finding a reviewer may accept with a reason. **MAY** means it
exists for a reason the module knows and nothing checks.

`test.sh` is a SHOULD rather than a MUST because an app whose only honest test is "the
port answers" should not be made to write a ceremonial one — but a foundation module
without tests is a real finding, and the sweep in D5 is where those are settled rather
than by an obligation level that would refuse to install them.

**A module another module provisions still ships an `install.sh`.** `network` and
`templates` are created by the bootstrap and by `cluster`, so theirs does nothing but
say so and exit 0. That is three lines in the one place a reader looks, and it keeps the
rule and the check simple: no declared exception, no field to carry it, no branch in the
tooling. An empty artifact that documents itself beats a special case.

**The module's documents and contribution files are not listed here.** README, INSTALL,
DESIGN and TEST are ADR-013's, with the audiences and obligations it sets; `AUTHORS.md`
and the community-health files are ADR-015's. The blueprint check (D5) reports on them
by those rules, and this ADR does not restate them.

### D3 — a service directory

A module that `provides` a service ships it in `services/<service>/`, and a service is
made of six files. They are the provider side of ADR-020's change model: the consumer
declares a field, the manager works out what changed, and one of these scripts is what
actually runs.

| File | Level | What it is |
|---|---|---|
| `install-service.sh` | **MUST** | give this service to a consumer for the first time |
| `update-service.sh` | **MUST** | re-apply it for a consumer whose declaration changed (#495 — the contract the fleet reconciles through) |
| `delete-service.sh` | **MUST** | take it away again, leaving nothing behind |
| `test-service.sh` | **SHOULD** | is this consumer's instance of the service actually working |
| `fields.json` | **MUST** when the service declares fields | the per-provider manifest (ADR-020), validated by `schemas/service-fields.json` and composed into the module field set |
| `README.md` | **MUST** | what a consumer gets and what it must declare. Its field section is generated — `scripts/gen-service-fields-doc.py`, checked in CI, so the prose cannot drift from `fields.json` |

A service may carry more: a `<service>.json` where it needs its own object
(`network/services/dns`), or a shared helper the scripts source (`nat-common.sh`,
`access-list.sh`). Those are the service's business and nothing checks them.

`test-service.sh` is a SHOULD for the same reason `test.sh` is — and, as there, the
foundation's are expected to have one.

### D4 — the module's own file carries its claim

`<module>.json` is the module's contract with the tooling. **What may appear in it, and
what each field means, is defined once in the schemas** — `src/foundation/schemas/`,
where `module-fields.json` is composed from the modules' own `fields.json` (#567) and
`README.md` names the owning manager for every configuration object. This ADR requires
the file; it does not describe its contents, and a field's meaning is not restated here
where it would drift from the schema that enforces it.

Three things about it are the blueprint's business:

1. **It is the only place the module states what it is.** Its classification —
   `kind` and `scope` (ADR-022, ADR-022e; `module.tier` is retired), `stack` (#463),
   `source` (ADR-007b) — lives here and, except for `stack`, is never copied into the
   catalogue.
2. **`version` and `status` are claims, and they are checked.** They mean what #248
   settled and `validate-module-tier-source.sh` already enforces. This ADR adopts that
   rather than restating it.
3. **Keys beginning `_` are documentation for the next reader**, not data. No tool reads
   them, and the schema check passes over them.

### D5 — obligation is checked, and the estate is swept

A `module-manager validate` blueprint check reports the set: a missing **MUST** is an
**error**, a missing **SHOULD** a **warning** — the same for every module, whatever its
stack and whoever wrote it. There is no split by source: the standard is what makes a
module a module, and a community author is better served by being told the same thing as
everyone else than by a lower bar that quietly accepts less.

What protects the user is *where* the check runs, not a weaker rule: **an install is
never blocked by a missing artifact**, because the person installing a module is not the
person who can fix it. The check runs in `module-manager validate` and in CI on the
official repositories, which is where a module is held to the blueprint.

Because the standard is uniform, **the estate is swept to meet it** as part of
implementing this ADR, rather than grandfathered: the `install.sh` for `network` and
`templates` (D2), a `test.sh` for the foundation modules that lack one, and the 15
service directories missing part of their set (D3). What cannot be fixed in the sweep
becomes an issue, not an exception in the rule.

### D6 — `00-Template` is the blueprint, in files

A new module starts as a copy of `00-Template`, which carries every MUST and SHOULD as a
working stub: a `<module>.json` with `version: 0.1.0` and `status: Development` (what a
new module has earned, #248), the scripts of D2, a `services/` with one stubbed service
per D3, and the documents ADR-013 requires. The blueprint check runs on the template in
CI, so the template cannot drift from the rule that describes it.

### D7 — what this ADR does not decide

- **The NixOS baseline** every VM imports (#324, #390, #448, #472, FW #87) — that is
  G1.4's, and the blueprint will point at it once it exists.
- **The SBOM's content and generation** — ADR-011, still Draft. The blueprint names the
  file as a MAY and revisits the obligation when ADR-011 is accepted; naming it MUST
  before there is a way to generate one would only create a finding nobody can clear.
- **The module's documents and contribution files** — ADR-013 and ADR-015 (D2).
- **Where modules live** in the repository — the `src/apps` restructure is #421.
- **How a module's payload is configured inside the guest** (Ansible or otherwise) —
  #430.

## Consequences

- A module author has one list and a template that matches it; a reviewer has the same
  list. "Is it finished?" stops being a matter of taste.
- The estate gets measurable, and then gets fixed: the 15 incomplete service directories
  and the two modules without `install.sh` are findings the day the check lands, and the
  D5 sweep is what clears them.
- One severity for everyone means a community module can fail CI on the same rule as a
  foundation one. That is the intent; it costs a contributor a stub, and it stops the
  official tree from being the only place the blueprint is true.
- The check is one more thing to keep true: it runs in CI and in `module-manager
  validate`, never at install time, so it cannot fail a user's install.

## Alternatives considered

- **Leave it to review.** What we have: consistent modules from people who read other
  modules, gaps from people who did not.
- **Declare the exception (`provisionedBy`).** A new field on `<module>.json` saying
  another module creates this one, which the check would accept in place of an
  `install.sh`. Rejected: a field, a schema entry, a branch in the check and a rule to
  explain — all so two modules can omit a three-line file. The no-op `install.sh` says
  the same thing where a reader already looks.
- **Split severity by source or stack.** Rejected (D5): it makes the blueprint mean two
  different things, and the estate sweep is the better answer to "but our own modules
  don't comply yet".
- **Make every artifact MUST.** `delete.sh` on a module that needs no teardown is a stub
  that must be kept working; obligation without a reason is noise.
- **Refuse to install an incomplete module.** Punishes the user for the author's
  omission, and TAPPaaS's whole point is that a module installs.

## Decided 2026-09-20 (Lars — pending @ErikDaniel007)

The five questions v0.1 left open:

1. **`test.sh`** — a **SHOULD** for every module, foundation included; the sweep is what
   settles the foundation modules that lack one (D2, D5).
2. **`provisionedBy`** — **dropped**. `network` and `templates` get a no-op `install.sh`
   instead (D2).
3. **Severity split** — **no split**: one standard for every module, and a sweep to make
   the estate meet it (D5).
4. **SBOM** — **wait** for ADR-011; `MAY` until then (D2, D7).
5. **`AUTHORS.md`** — **removed** from this ADR; it is ADR-015's, like the rest of the
   contribution files (D2).

## Acceptance

- [ ] The executable artifact set (D2) and the service set (D3) are agreed, with the
      obligation level on each.
- [ ] ADR-015 and this ADR reference each other, and neither restates the other's files.
- [ ] `00-Template` carries every MUST and SHOULD as a stub, including one service (D6).
- [ ] `module-manager validate` reports the blueprint per D5, and CI fails an official
      module missing a MUST.
- [ ] The sweep has landed: `install.sh` for `network` and `templates`, `test.sh` for the
      foundation modules lacking one, and the 15 service directories completed.
- [ ] What the sweep could not fix is an issue, not an exception.
