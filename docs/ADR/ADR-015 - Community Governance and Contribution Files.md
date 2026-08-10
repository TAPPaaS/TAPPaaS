# ADR-015 — Community Governance and Contribution Files

| | |
|---|---|
| **Status** | Draft — for review (Lars / Erik) |
| **Version** | 0.1 |
| **Date** | 2026-08-10 |
| **Author** | drafted by Claude for Lars Rossen |
| **Related** | [ADR-013](<ADR-013 - Documentation Structure and Standards.md>) (doc taxonomy — governance files are the "meta" layer it doesn't cover); [ADR-011](<ADR-011 - SBOM Governance.md>) (supply-chain governance, referenced by SECURITY); [ADR-007](<ADR-007 - TAPPaaS Taxonomy.md>) (module/namespace model that CODEOWNERS routes); `docs/codeberg-migration.md` (forge = Codeberg); the external `CLAUDE.md` Codeberg-etiquette section (the human-facing form of which belongs in an in-repo `CONTRIBUTING.md`) |
| **Changelog** | v0.1 — initial draft: gap analysis, canonical file set, per-repo placement, content outlines, phased rollout |

## Context

TAPPaaS is now a **public, multi-repo, multi-contributor** project on **Codeberg**
(a volunteer-run, donation-funded Forgejo instance):

- **`TAPPaaS/TAPPaaS`** — the core platform (foundation + apps).
- **`TAPPaaS/Community`** — contributor-namespaced modules (`src/<contributor>/…`, e.g.
  `src/larsrossen/…`, `src/ErikDaniel007/…`), registered via `src/module-catalog.json`.
- **`TAPPaaS/Documentation`** — the MkDocs site that builds tappaas.org (ADR-013 §6).

The project has begun accepting **external contributions** (multiple namespaces already
exist in Community), yet the repositories carry **none of the standard open-source
"community health" files** except `LICENSE` (MPL-2.0). There is no in-repo statement of
how to contribute, how contributors are expected to behave, how to report a vulnerability,
how decisions are made, or who reviews what.

Two TAPPaaS-specific pressures make this a real gap, not a formality:

1. **Codeberg etiquette is currently only in `CLAUDE.md`.** The norms that protect a
   volunteer forge — minimize forge load, few concise commits, human attribution, no
   high-volume "vibe-coded" contributions — live **outside the repo** (in the external
   AI-tooling `CLAUDE.md`). A *human* contributor has no in-repo place to learn them. The
   canonical, human-facing home for those norms is `CONTRIBUTING.md`.
2. **The Community namespace model has no review routing.** `src/<contributor>/` implies
   each contributor owns their subtree, but nothing encodes that, so review
   responsibility is ad-hoc.

ADR-013 fixed where *documentation* lives; it deliberately did **not** cover these
governance/meta files. This ADR closes that gap.

### Gap analysis (as of 2026-08-10)

| File | Purpose | `TAPPaaS/TAPPaaS` | `TAPPaaS/Community` | `TAPPaaS/Documentation` |
|------|---------|:-:|:-:|:-:|
| `LICENSE` | Legal license (MPL-2.0) | ✅ | ⚠️ verify | ⚠️ verify |
| `CONTRIBUTING.md` | How to contribute | ❌ | ❌ | ~ (partly in README) |
| `CODE_OF_CONDUCT.md` | Behavioral standard + enforcement | ❌ | ❌ | ❌ |
| `SECURITY.md` | Private vulnerability disclosure | ❌ | ❌ | ❌ |
| `SUPPORT.md` | Where to get help | ❌ | ❌ | ~ (community pages) |
| `GOVERNANCE.md` | Roles + decision process | ❌ | ❌ | ❌ |
| `MAINTAINERS.md` / `CODEOWNERS` | Who reviews what | ❌ | ❌ | ❌ |
| Issue/PR templates (`.forgejo/`) | Structured intake | ❌ | ❌ | ❌ |
| `CHANGELOG.md` | Release notes | ❌ | ❌ | ❌ |

## Decision

### D1 — Canonical file set and where each lives

Adopt the community-health set below. To avoid drift across three repos (Forgejo has **no
org-wide default-health-file mechanism** like GitHub's `.github` repo), designate
**`TAPPaaS/TAPPaaS` as the canonical governance home**; the other repos carry a short
tailored `CONTRIBUTING.md` + `CODEOWNERS` and **link back** to the canonical
`CODE_OF_CONDUCT`, `SECURITY`, and `GOVERNANCE`.

| File | Canonical location | Community | Documentation |
|------|--------------------|-----------|---------------|
| `LICENSE` (MPL-2.0) | each repo (self-contained) | own copy | own copy |
| `CONTRIBUTING.md` | `TAPPaaS/TAPPaaS` (root) | own (namespace/module rules) → links core | own (docs workflow) → links core |
| `CODE_OF_CONDUCT.md` | `TAPPaaS/TAPPaaS` (root) | link | link |
| `SECURITY.md` | `TAPPaaS/TAPPaaS` (root) | link | link |
| `SUPPORT.md` | `TAPPaaS/TAPPaaS` (root) | link | (community pages already) |
| `GOVERNANCE.md` | `TAPPaaS/TAPPaaS` (root) | link | link |
| `CODEOWNERS` | each repo (paths differ) | **required** (namespace routing) | own |
| `.forgejo/issue_template/`, `.forgejo/PULL_REQUEST_TEMPLATE.md` | each repo | each repo | each repo |
| `CHANGELOG.md` | `TAPPaaS/TAPPaaS` (root) | optional | n/a |

### D2 — Locations and Codeberg/Forgejo specifics

- Health files may sit in **repo root** or a **`docs/`** subdir; Forgejo also honors
  **`.forgejo/`** (and legacy `.gitea/`). **Use repo root** for the prose files
  (discoverable, conventional) and **`.forgejo/`** for issue/PR templates + `CODEOWNERS`.
- **Templates target Codeberg**, not GitHub: `.forgejo/issue_template/*.yaml` +
  `.forgejo/PULL_REQUEST_TEMPLATE.md`, with an `issue_template/config.yaml` routing
  questions to the issue tracker (TAPPaaS has no Discussions — Forgejo lacks the feature;
  cf. the recent Documentation community-page cutover to Codeberg issues). **Do not** add
  `.github/ISSUE_TEMPLATE` — `.github/` here holds only the release-image workflows for the
  stale GitHub mirror (`docs/codeberg-migration.md`).
- All "where to file / who to contact" links point at **`codeberg.org/TAPPaaS/…`**, never
  the GitHub mirror.

### D3 — What goes in each file (content contract)

- **`CONTRIBUTING.md`** — the substantive one. Sections: project layout (foundation vs
  apps vs Community namespaces); the module contract (`<vm>.json` / `.nix` /
  `install.sh` / `update.sh` / `test.sh`, per `apps/00-Template`); **catalog registration**
  (`src/module-catalog.json`); dev environment + how to run `test.sh`; **branch/PR
  workflow**; **Conventional-Commits** subjects; **Codeberg etiquette** promoted from
  `CLAUDE.md` (few concise commits, minimize forge load, **human attribution — no AI
  co-author trailers**, no high-volume automated PRs); bash standards (strict mode,
  logging, shellcheck); how/where to ask before coding.
- **`CODE_OF_CONDUCT.md`** — adopt the **Contributor Covenant v2.1** verbatim; fill in the
  enforcement **contact** (a role address, not a personal inbox where avoidable).
- **`SECURITY.md`** — **private** disclosure channel (email/security contact — never public
  issues), supported-version policy, response expectations; cross-link **ADR-011 (SBOM
  Governance)** and the `feat/378-secret-scanning` work.
- **`SUPPORT.md`** — questions → **Codeberg issues** (label `question`); bugs/features →
  issues; docs → tappaas.org. Explicitly: issues are for actionable items, not open-ended
  support threads.
- **`GOVERNANCE.md`** — current reality first (BDFL/small-maintainer model is fine to state
  honestly): roles (contributor → module owner → core maintainer), how a module is
  **accepted into Community** and later **promoted toward core**, how maintainers are added,
  how ADRs are proposed/accepted (this very process), and the release cadence
  (`main` = 2.0 line, `stable`).
- **`CODEOWNERS`** — Community: `src/<contributor>/  @<contributor>` per namespace so PRs
  auto-route. Core/Docs: map subsystem paths to the responsible maintainer(s).
- **Issue/PR templates** — `bug_report`, `feature_request`, `new_module` (Community); PR
  template with a checklist (tests updated, docs updated, catalog entry if new module,
  concise Conventional-Commit title, no AI trailer).
- **`CHANGELOG.md`** — *Keep a Changelog* + SemVer; optional at first (git history +
  release notes may suffice until a formal release train exists).

### D4 — Relationship to ADR-013 and the external `CLAUDE.md`

- These files are **governance/meta**, complementary to ADR-013's *documentation* taxonomy:
  ADR-013 governs `docs/`, module READMEs, and the site; ADR-015 governs the root-level
  contributor-facing contract. No overlap, no conflict.
- The **human-facing** subset of the `CLAUDE.md` Codeberg-etiquette rules is **copied into
  `CONTRIBUTING.md`** so contributors without the AI tooling get the same norms. `CLAUDE.md`
  stays external (AI-tooling config, per the tappaas-claude split) and simply references
  `CONTRIBUTING.md` as the human source of truth.

### D5 — Phased rollout (minimal-first)

1. **Phase 1 (now):** `TAPPaaS/TAPPaaS` — `CONTRIBUTING.md`, `CODE_OF_CONDUCT.md`,
   `SECURITY.md`. These are the highest-leverage and unblock external contribution safely.
2. **Phase 2:** `TAPPaaS/Community` — `CONTRIBUTING.md` (namespace/module rules) +
   `CODEOWNERS` (per-namespace routing); `SUPPORT.md` and `.forgejo/` templates in core.
3. **Phase 3:** `GOVERNANCE.md`, `MAINTAINERS`, templates in the other repos, `CHANGELOG.md`
   once a release train exists.

## Consequences

- **Positive:** external contributors have a clear, in-repo onboarding path; conduct and
  security expectations are explicit; review routing is encoded; the volunteer-forge norms
  finally live where humans can read them; PRs/issues arrive structured.
- **Cost:** ~9 short files across three repos to author and then keep from drifting. The
  "canonical in core + link" pattern (D1) is chosen specifically to minimize drift given
  Forgejo's lack of org-default health files.
- **Neutral:** none of this changes code or module behavior; it is process/documentation.

## Acceptance criteria

- [ ] Phase-1 files present in `TAPPaaS/TAPPaaS`, discoverable in the Codeberg repo header.
- [ ] `CONTRIBUTING.md` documents the module contract, catalog registration, PR workflow,
      and the Codeberg-etiquette norms (human-attribution, concise commits, minimize load).
- [ ] `SECURITY.md` names a private disclosure channel and links ADR-011.
- [ ] `TAPPaaS/Community` has `CODEOWNERS` routing every `src/<contributor>/` namespace.
- [ ] Issue/PR templates live under `.forgejo/` (not `.github/`) and reference Codeberg.
- [ ] No file or link points contributors at the GitHub mirror.

## Open questions

1. **Enforcement contact** for the Code of Conduct — a shared role address, or named
   maintainers initially?
2. **Governance maturity** — document the honest current small-maintainer model now, or
   define a fuller committer/steering model up front?
3. **CLA/DCO** — require a Developer Certificate of Origin sign-off on commits, or rely on
   the inbound=outbound MPL-2.0 default? (Recommend DCO for external contributions.)
4. Should shared files (`CODE_OF_CONDUCT`, `SECURITY`, `GOVERNANCE`) be **duplicated** into
   each repo for discoverability, or kept **single-source in core with links**? (D1 assumes
   link; revisit if Codeberg surfaces linked files poorly in the per-repo UI.)
