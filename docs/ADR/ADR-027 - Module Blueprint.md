# ADR-027 — Module Blueprint

| | |
|---|---|
| **Status** | **Draft** (2026-09-20) — for @LarsRossen and @ErikDaniel007 to agree before sign-off |
| **Version** | 0.1 |
| **Date** | 2026-09-20 |
| **Author** | Lars Rossen |
| **Deciders** | @LarsRossen, @ErikDaniel007 |
| **Related** | **#363** (origin: the artifact set) · **#248** (what `version` and `status` claim — built 2026-09-20, §D3) · [ADR-013](<ADR-013 - Documentation Structure and Standards.md>) (which document serves which audience; README + INSTALL mandatory for catalog inclusion) · [ADR-015](<ADR-015 - Community Governance and Contribution Files.md>) (AUTHORS and the community-health files) · [ADR-011](<ADR-011 - SBOM Governance.md>) (the SBOM this blueprint will name once it is accepted) · [ADR-007](<ADR-007 - TAPPaaS Taxonomy.md>) (the module/manager/controller taxonomy and the verb dispatch) · [ADR-020](<ADR-020 - Declared-Field Change Model (validate, drift, modify).md>) (what `update`, `modify` and `reconcile` do with these files) · [ADR-026](<ADR-026 - Managed Machines as Modules.md>) D6 (a module is named by its directory; an instance is not a module) · [ADR-022](<ADR-022 - Workload Ontology.md>) (`kind`, `scope`, `management`) |
| **Changelog** | v0.1 (2026-09-20) — first draft: the artifact set with obligation levels, the co-location and naming rules, severity by tier and source, the template as the blueprint's copy, and five questions for the deciders. |

Every TAPPaaS module is the same shape, so tooling and people can rely on it.

---

## Context

A module is the unit TAPPaaS installs, updates, tests and deletes (ADR-007; ADR-009
calls it the atomic deployable unit). What a module *is made of* has never been
written down. The estate shows it: of 25 modules today, all carry `README.md` and
`INSTALL.md`, 22 carry `DESIGN.md`, 11 carry `TEST.md`, 11 carry `AUTHORS.md`, two
carry `delete.sh`, one (`n8n`) carries documentation and nothing else, and two
(`network`, `templates`) carry no `install.sh` because the bootstrap provisions them.
None carries an SBOM.

Some of that variation is meaningful and some is drift, and nothing tells them apart.
The consequences are concrete:

- **A community author cannot know when a module is finished.** `00-Template` shows
  one possible shape, not the required one.
- **Tooling cannot check what it is not told.** `install-module.sh` skips a missing
  `install.sh` and `test-module.sh` skips a missing `test.sh` — silently, because
  both are legitimate for *some* module. So a module that simply forgot its tests
  installs and updates as if it had them.
- **Reviews argue from taste.** ADR-013 settled the documents (README and INSTALL are
  mandatory for catalog inclusion; DESIGN where internals are non-trivial), #248
  settled `version` and `status`, ADR-015 the community-health files. The executable
  artifacts were never settled.

This ADR names the whole set, the obligation on each, and what happens when one is
missing. It does not invent new artifacts: everything below is something modules
already carry, plus the SBOM that ADR-011 will name.

## Decision

### D1 — the module directory is the module

Every artifact lives in the module's own directory, beside the others. No module
keeps part of itself elsewhere — not its documentation, not its service scripts, not
its fields. The directory's name is the module's name (ADR-026 D6.2), and
`<module>.json` inside it is the module's own file; an instance of it is named
separately (D6.1) and lives in `config/`, never here.

This is what makes the rest checkable: "does this module carry X?" is `test -f`.

### D2 — the artifact set, and what each is for

| Artifact | Level | Whose question it answers |
|---|---|---|
| `<module>.json` | **MUST** | the tooling's: what this module is (`kind`, `tier`, `source`, `version`, `status`, `dependsOn`, its fields) |
| `README.md` | **MUST** | an end user deciding whether to use it: what you get, what you don't, what it needs (ADR-013) |
| `INSTALL.md` | **MUST** | an admin installing it — **only** what automation cannot do (ADR-013) |
| `install.sh` | **MUST**, unless provisioned by another module (D5) | `module add`: bring this module into being on this site |
| `update.sh` | **MUST** | the nightly sweep: take the release forward, idempotently (ADR-020) |
| `test.sh` | **MUST** | the update gate and `module test`: is it healthy, before and after a change |
| `services/<service>/` | **MUST** for each service the module `provides` | a consumer's: `install-service.sh`, `update-service.sh`, `delete-service.sh`, `test-service.sh`, `fields.json`, `README.md` |
| `fields.json` | **MUST** when the module defines fields of its own | the schema's: what those fields mean, composed into `module-fields.json` (#567) |
| `delete.sh` | **MAY** | only when deleting needs more than removing the guest and the config (the satellite's tunnel; the backup module's PBS) |
| `DESIGN.md` | **SHOULD** | a developer's: how it works inside (ADR-013 — expected wherever internals are non-trivial) |
| `TEST.md` | **SHOULD** | a reviewer's: what the suite asserts, and what it does not |
| `AUTHORS.md` | **SHOULD** | attribution (ADR-015) |
| `<module>-sbom.json` | **MAY** today, **MUST** when ADR-011 is accepted | a CVE report's: what is actually inside the guest (#143) |

**MUST** means the module is incomplete without it and the lint says so. **SHOULD**
means its absence is a finding a reviewer may accept with a reason. **MAY** means it
exists for a reason the module knows and nothing checks.

### D3 — the module's own file carries its claim

`<module>.json` is the contract: `kind` and `scope` (ADR-022), `tier` and `source`
(ADR-007b), `dependsOn` / `integratesWith` / `provides`, the module's fields, and
`version` + `status` — which mean what #248 says they mean (SemVer, `0.x` until
someone other than the author has run it; Development → Testing → Production, each
step earned). The classification lint already enforces that; this ADR adopts it
rather than restating it.

Keys beginning `_` are documentation for the next reader, not data, and no tool reads
them.

### D4 — obligation is checked, and the severity follows who is affected

A `module-manager validate` blueprint check reports the set:

| | a MUST is missing | a SHOULD is missing |
|---|---|---|
| `tier: foundation`, `source: official` | **error** | warning |
| everything else (`app`, community, private, local) | **warning** | note |

TAPPaaS's own modules hold themselves to the standard; a community module is told,
not refused — the same line `validate-module-tier-source.sh` already draws for
`source: community`. An install is never blocked by a *missing* artifact, because the
user installing it is not the person who can fix it; CI on this repository is where
foundation modules are held.

### D5 — a module another module provisions says so

`network` and `templates` carry no `install.sh` because the bootstrap and the
`cluster` module create them. That is legitimate and must not read as a gap, so the
module declares it — `"provisionedBy": "<module>"` in `<module>.json` — and the
blueprint check accepts the absence when it is declared, and only then.

### D6 — `00-Template` is the blueprint, in files

A new module starts as a copy of `00-Template`, which carries every MUST and SHOULD
as a working stub: a `<module>.json` with `version: 0.1.0` and `status: Development`
(what a new module has earned, #248), the four scripts, the four documents, an empty
`services/`. The blueprint check runs on the template in CI, so the template cannot
drift from the rule that describes it.

### D7 — what this ADR does not decide

- **The NixOS baseline** every VM imports (#324, #390, #448, #472, FW #87) — that is
  G1.4's, and the blueprint will point at it once it exists.
- **The SBOM's content and generation** — ADR-011, still Draft. The blueprint names
  the file so the two land together.
- **Where modules live** in the repository — the `src/apps` restructure is #421.
- **How a module's payload is configured inside the guest** (Ansible or otherwise) —
  #430.

## Consequences

- A module author has one list and a template that matches it; a reviewer has the
  same list. "Is it finished?" stops being a matter of taste.
- The estate gets measurable: `n8n` (documentation only), `vaultwarden` and
  `netbird-client` (no `test.sh`) are findings the day the check lands, not opinions.
- Foundation modules must carry `test.sh` — the sweep's gate is only as good as the
  test behind it. Two of them would need one written.
- The check is one more thing to keep true: it runs in CI and in `module-manager
  validate`, not at install time, so it cannot fail a user's install.

## Alternatives considered

- **Leave it to review.** What we have: consistent modules from people who read
  other modules, gaps from people who did not.
- **Make every artifact MUST.** `delete.sh` on a module that needs no teardown is a
  stub that must be kept working; obligation without a reason is noise.
- **Refuse to install an incomplete module.** Punishes the user for the author's
  omission, and TAPPaaS's whole point is that a module installs.

## Open — for the deciders

1. **Is `test.sh` a MUST for every module**, including an app whose test would only
   be "the port answers"? (The alternative: MUST for `tier: foundation`, SHOULD for
   apps.)
2. **`provisionedBy` (D5)** — a new field, or is a sentence in the README enough for
   the two modules this affects?
3. **Severity split (D4)** — is "error for official foundation, warning for the rest"
   the right line, or should every official module (app included) be held to error?
4. **SBOM** — wait for ADR-011 to be accepted, or name `<module>-sbom.json` as MUST
   now with a deadline release?
5. **`AUTHORS.md`** — SHOULD, as here, or MUST for anything accepted into the
   official repositories (ADR-015 governs the repository-level files; this is the
   per-module one)?

## Acceptance

- [ ] The artifact table (D2) is agreed, with the obligation level on each.
- [ ] The five open questions are answered and folded in.
- [ ] `00-Template` carries every MUST and SHOULD as a stub (D6).
- [ ] `module-manager validate` reports the blueprint per D4, and CI fails on an
      official foundation module missing a MUST.
- [ ] The findings the check reports on today's estate are triaged into issues.
