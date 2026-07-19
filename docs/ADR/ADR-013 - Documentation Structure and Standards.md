# ADR-013 — Documentation Structure and Standards

| | |
|---|---|
| **Status** | Draft — for review (Lars / Erik) |
| **Version** | 0.1 |
| **Date** | 2026-07-10 |
| **Author** | drafted by Claude for Lars Rossen (from #362, Erik's proposed fix) |
| **Related** | **#362** (origin); **#317** (docs/ISSUES cleanup — executes §5); **#247** (Diataxis module templates — realizes §4); [ADR-007](<ADR-007 - TAPPaaS Taxonomy.md>) (taxonomy the docs describe); [Documentation repo ADR-001](https://codeberg.org/TAPPaaS/Documentation/src/branch/main/ADR/ADR001-rearchitect.md) (the site build that consumes §6) |
| **Changelog** | v0.1 — initial draft covering artifact taxonomy, locations, lifecycle, site governance |

Where TAPPaaS documentation lives, which artifact type serves which audience and
lifecycle stage, and how content is retired — one governing rule instead of the current
scatter across `ISSUES/`, `docs/`, `src/` and the tappaas.org site.

## Context

There is no ADR that specifies where documentation lives, how it is structured, and
when a GitHub issue vs an ADR vs inline module docs is the right artifact (#362). The
symptoms are documented in #317 (stale `ISSUES/` directories, a now-removed `Attic/`)
and #247 (module README/INSTALL templates with no structure or audience guidance).
Meanwhile the tappaas.org site has been rebuilt (Documentation repo, ADR-001) around a
**sync-from-source** model: selected source-repo docs are published to the site at
build time, which makes the source repo the single source of truth — but only if the
source repo knows which docs are which.

## Decision

### 1. One principle: every document has exactly one home, chosen by audience and lifecycle

A document is written **once**, in the location that matches its audience; every other
place (including the website) links to it or syncs from it. Git history is the archive
— there is no `Attic/`.

### 2. Artifact taxonomy

| Artifact | Audience | Lifecycle | Lives in |
|----------|----------|-----------|----------|
| **GitHub issue** | contributors | transient: opened → resolved/closed | github.com/TAPPaaS/TAPPaaS/issues |
| **ADR** | contributors, architecture reviewers | durable decision record: Draft → Accepted → Superseded (never deleted) | `docs/ADR/` |
| **Design doc** | implementers of one ADR/feature | lives while the implementation is current; superseded note when not | `docs/design/` |
| **Architecture SSOT** | contributors | continuously maintained (glossary, taxonomy evidence) | `docs/Architecture/` |
| **Module `README.md`** | **end user** deciding to use the module — *Diataxis: explanation + reference* (service-catalog entry: what you get, what's not included, requirements) | maintained with the module | `src/**/<module>/` |
| **Module `INSTALL.md`** | **TAPPaaS admin** — *Diataxis: how-to* (only what scripts cannot automate) | maintained with the module | `src/**/<module>/` |
| **Module `DESIGN.md`** | module developers — *Diataxis: explanation* | maintained with the module | `src/**/<module>/` |
| **Reference docs** (`CLI-REFERENCE.md`, `ZONES.md`, schema READMEs, …) | operators/developers — *Diataxis: reference* | maintained with the code they describe | next to that code |
| **Site page** (tappaas.org) | prospective adopters, installers, operators | curated narrative, owned by the Documentation repo | codeberg.org/TAPPaaS/Documentation |

The templates in `src/apps/00-Template/` (README/INSTALL) are the normative shape for
module docs — #247 updates them to match this table.

### 3. Choosing the artifact (decision tree)

```
Reporting a defect or proposing a change? ......... GitHub issue
Recording a significant decision? ................. ADR (docs/ADR/)
Describing HOW an accepted decision is built? ..... Design doc (docs/design/)
Defining a term / classification? ................. GLOSSARY.md (glossary SSOT, repo root)
Explaining a module to its end user? .............. that module's README.md
Telling an admin how to install/operate it? ....... that module's INSTALL.md
Telling the world / marketing / guided journeys? .. Documentation repo (site)
Working notes that fit none of the above? ......... they don't get committed
```

### 4. Module documentation standard

Per #247 (Diataxis): `README.md` answers *why/what/what-not* for the end user;
`INSTALL.md` answers *how* for the admin and documents **only** the steps automation
cannot do. Implementation details stay in `DESIGN.md`. The `00-Template` module carries
the canonical templates; a module is documentation-complete when all three exist and
match their audiences.

### 5. Lifecycle and archival rule

- **No `Attic/`, ever.** Deleting is safe: git history preserves everything.
  (`src/foundation/Attic/` is already removed on the ADR007 branch.)
- **`ISSUES/` directories are deprecated.** Each existing file must, within the current
  release cycle, become one of: a GitHub issue (if actionable), content folded into the
  proper home per §2 (if reference-worthy), or a deletion (if stale). New working notes
  start as GitHub issues, not committed files. (#317 executes this.)
- **ADRs are never deleted**; a replaced ADR gets `Status: Superseded by ADR-xxx`.
- **Design docs** get a one-line superseded/obsolete banner when their implementation
  changes, or are deleted when the feature is gone.

### 6. Site governance (what tappaas.org publishes)

The website (Documentation repo on Codeberg, ADR-001) publishes two kinds of content:

1. **Curated narrative** — landing, Why TAPPaaS, install journey, examples — authored
   in the Documentation repo.
2. **Synced source docs** — INSTALL docs, manager/controller READMEs, zones, schemas,
   the ADR-007 taxonomy — pulled at build time from a pinned ref of this repo by an
   explicit allow-list + glob rules (`scripts/sync-source.py` in the Documentation
   repo). Synced pages carry a "generated from source — edit upstream" banner.

Consequences for authors in **this** repo:

- A module/manager/controller README **is** a public web page. Write it for its §2
  audience; put internal notes in `DESIGN.md` (not synced) or issues.
- New managers/controllers appear on the site automatically (glob sync); other docs
  reach the site only via a deliberate allow-list addition — internal/WIP material
  cannot leak by default.
- The site tracks `ADR007` until it is promoted to `stable`, then follows `stable`.

## Consequences

- #317's cleanup becomes mechanical: apply §5 to `ISSUES/` and `src/foundation/network/ISSUES/`.
- #247's templates become the enforcement point of §4.
- Doc reviews get an objective question: *"is this content in its §2 home?"*
- The Documentation repo's sync model is now sanctioned by an upstream decision rather
  than being a website-side convention.

## Open questions for review

1. Should `DESIGN.md` files be published to the site (currently: no — contributors read
   them in-repo)?
2. Obligation level for module docs: is README+INSTALL a **MUST** for catalog inclusion
   (aligning with ADR-011's SHOULD-with-linting approach), or SHOULD?
3. Does `docs/Architecture/` fold into the site sync allow-list? (The glossary is now `GLOSSARY.md`
   at the repo root and is already synced; the remaining concept docs are arguably public-worthy.)
