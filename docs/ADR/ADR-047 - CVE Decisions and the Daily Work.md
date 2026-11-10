# ADR-047 — CVE Decisions and the Daily Work

| | |
|---|---|
| **Status** | **Draft** — for the operator's review |
| **Version** | 0.1 |
| **Date** | 2026-11-10 |
| **Author** | Lars Rossen |
| **Deciders** | @LarsRossen |
| **Closes / addresses** | Amends ADR-045 (D1 states, D2 lifecycle, D5 gate) and ADR-011 §8 (VEX). Built on the measurement in [`docs/plans/cve-as-built.md`](../plans/cve-as-built.md). The delivery of these records to production is a separate ADR (the security stream). |
| **Changelog** | v0.1 (2026-11-10): first draft. |

ADR-045 gave CVEs a lifecycle and a score. Running it for one boundary showed that the records
are the wrong size for daily work: a VEX statement is one CVE at one version, a site ack is a
whole CI, and nothing in between says "this critical counts as high here, because". This ADR
adds that record, makes decisions survive version moves where the reasoning allows it, separates
what TAPPaaS decides from what a site decides, and turns the operator's list of CVEs into a list
of actions.

**Why a new ADR and not an amendment.** ADR-045 is accepted and live, and its score, bands and
boundary phase stay. This changes the record model under it and adds a site layer and a daily
check. Folding that into ADR-045 would bury a second decision in the first one's history.

## Context

Measured on hrossen on 2026-11-10 (the as-built document has the detail):

- The site is critical because of 21 curl CVEs on the firewall. One sentence about how the
  firewall uses curl settles them. Today that is 21 statements pinned to curl 8.21.0.
- Three sqlite highs from the NixOS baseline set the level of 22 of 24 units.
- 1708 VEX statements fall into 398 module-and-package groups with 767 distinct analysis texts.
  1215 of the 1502 `not_affected` statements say `code_not_reachable`: the module does not use
  the affected part. That reasoning is about the module, and it is recorded per version.
- The 2.4 boundary removed 213 statements and carried 92; 91 were confirmed by hand the same day.
  The next boundary will remove about 440.
- A reclassification exists only as `exploitable` plus a rating. It has no author, date, expiry
  or structured reason.
- Site acks on CVEs: none. A site ack silences a CI's mail and changes no score.
- The operator sees 36 conditions, 24 unit rows and 1732 expandable CVE rows. The 43 open
  critical/high CVEs are 14 package decisions (82 CVEs in 31 packages by the nightly scan's
  higher count).
- No step looks at a newer upstream version.

## Decision

### D1. Three layers, each with one writer

| Layer | Question it answers | Writer | Where |
|---|---|---|---|
| **Facts** | What is installed, and which CVEs match it? | the scan | `config/sbom/` on the site |
| **Central decisions** | Does it affect TAPPaaS as built, and how bad is it in a TAPPaaS deployment? | TAPPaaS maintainers | the repo, next to the module |
| **Site decisions** | Does this installation accept what is left? | the site's operator | the site's `config/` |

A central decision is true for every site that deploys the module the way TAPPaaS ships it. A
site decision is only for what makes a site different, and should be rare. The scan applies them
in a fixed order: a VEX statement that decides a CVE wins; then a site acceptance; then a central
assessment; then the upstream severity.

Central decisions are of three kinds:

| Kind | Says | Record |
|---|---|---|
| **VEX statement** | not affected, false positive, resolved | `<module>-vex.json`, CycloneDX, as today |
| **Assessment** (new, D2) | affected, and its severity here is X, because | `<module>-assess.json` |
| **Deferral** (new, D6) | known, not yet analysed or not yet fixed, accepted for a release | `<module>-assess.json`, kind `deferred` |

### D2. The assessment: a contextual severity with a reason

An assessment replaces `exploitable` plus `ratings[]`. It is its own file, so a VEX file stays
plain CycloneDX and the assessments can travel as data.

```json
{
  "id": "network-curl-outbound",
  "module": "network",
  "package": "pkg:generic/opnsense/curl",
  "versions": "*",
  "cves": ["CVE-2026-86413", "CVE-2026-86414"],
  "match": { "AV": ["N"], "UI": ["R", "A", "P"] },
  "modified": { "AV": "A" },
  "rating": null,
  "reason": "client-only",
  "justification": "curl on the firewall only makes outbound requests that an administrator or the update job starts: firmware and package fetches from the configured mirrors. No service on the firewall passes a URL from the network to curl. An attacker has to control a mirror or sit on the management path.",
  "assumes": { "maxExposure": "internal" },
  "author": "larsrossen",
  "decided": "2026-11-10",
  "reviewBy": "2027-02-08",
  "basis": { "CVE-2026-86413": { "severity": "Critical", "vector": "CVSS:3.1/AV:N/AC:L/PR:N/UI:R/S:U/C:H/I:H/A:H", "kev": false } }
}
```

- **Scope.** A module (or `templates` for the baseline, or a platform role: `pvehost`, `network`),
  one package, a version range (D3), and the CVEs it covers. The CVEs are a list, a `match` rule,
  or both.
- **`match`: a rule on the upstream CVSS vector**, within this one module and package. A new CVE
  that fits is assessed the day it appears, marked `auto` until a maintainer has read it (D7,
  review queue). A rule never crosses a package or a module. Without `match`, only the listed
  CVEs are covered.
- **`modified`: CVSS environmental metrics.** The contextual severity is the upstream vector
  re-scored with the modified metrics (attack vector, privileges required, user interaction, and
  the confidentiality, integrity and availability requirements). The result is computed, so it
  moves when upstream changes the vector, and anyone can check it. The example turns a network
  attack vector into an adjacent one.
- **`rating`: a plain level** (low to critical), only for CVEs without a usable vector (VuXML
  entries, advisories with a severity word only). When both are possible, `modified` is used.
- **`reason`** from a fixed list: `internal-only`, `client-only`, `admin-input-only`,
  `local-access-required`, `feature-disabled`, `mitigated-by-rule`, `data-not-sensitive`,
  `other`. The view groups and filters by it.
- **`justification`** is mandatory free text. The tool refuses fewer than 80 characters and
  refuses `other` without it. It is shown wherever the rating is shown.
- **`assumes`**: what must be true at a site for the assessment to hold (D5).
- **`author`, `decided`, `reviewBy`.** `reviewBy` is mandatory, at most 180 days ahead, 90 by
  default.
- **`basis`**: what upstream said when it was decided, per CVE, written by the tool.

The scan keeps the CVSS vector, the KEV flag and the EPSS score of each finding (grype and trivy
both report them; today the scan drops them).

**Re-evaluation.** An assessment stops applying, and its CVEs become `review` (D4), when:

| Trigger | Checked by |
|---|---|
| upstream severity or vector differs from `basis` | every scan |
| the CVE enters the known-exploited list | every scan; the CVE counts at its upstream severity at once and raises `cve-new-critical` |
| EPSS rises above 10 % | every scan |
| `reviewBy` has passed | every scan; a 14-day warning in the review queue first |
| the package version leaves `versions` | every scan |
| the site does not meet `assumes` | every scan, on that site only (D5) |

The first, fourth and fifth leave the old rating in force for 14 days so a date does not turn a
site critical overnight; the queue shows them from the first day. Known-exploited and EPSS do not
wait.

`cve-triage.sh assess <module> --package <p> [--cve … | --match …] --modified AV:A --reason …
--justification "…"` writes the record and prints every CVE it would cover on the last scan
before it writes.

### D3. Decisions survive version moves where the reasoning allows it

A VEX statement and an assessment both get a `versions` range in place of the exact version.
What the default is depends on what the reasoning rests on:

| Reasoning | Examples | Default range |
|---|---|---|
| About the deployment | every assessment; `requires_environment`, `requires_configuration`, `protected_by_mitigating_control`, `protected_at_perimeter` | `*`: holds until the review date |
| About how the module uses the package | `code_not_reachable`, `requires_dependency` | the same major version; a move inside it is carried automatically and listed for review afterwards |
| About the build | `code_not_present`, `protected_by_compiler`, `resolved`, nixpkgs patches | the exact version, as today |
| About the match | `false_positive` | every version, as today |

ADR-045 D2 said a carry is never automatic. This changes it for the second row: 1215 statements
say the module does not use the affected code, and a patch release rarely changes what a module
calls. The carry is made by the boundary's `cve` phase, committed with the list, and each carried
statement sits in the review queue (D7) until someone ticks it. A major version move still stops
and asks first.

A VEX statement may also name several CVEs of one package with one analysis text, so "immich
does not use ImageMagick's MVG coder" is one statement over eight CVEs. `cve-triage add` already
merges same-analysis statements; it gains `--cve` more than once.

### D4. States

ADR-045's four states become six:

| State | Meaning | Counts as |
|---|---|---|
| decided | a VEX statement says not affected, false positive or resolved | 0 |
| **assessed** (was `risk`) | an assessment applies | its contextual severity |
| **accepted** (new) | the site accepted it (D5) | 0 in the level; listed and counted beside the score |
| **deferred** (new) | centrally known and put off with a note (D6) | its upstream severity |
| **review** (was `carried`) | a decision exists and its basis no longer holds: version, upstream change, date, or a failed site assumption | its upstream severity, with the old decision attached |
| open | critical/high, nobody has looked | its upstream severity |

Points, bands and zone multipliers are ADR-045's. One change: an assessed item scores the same
points as an open one of the same level (20 and 8), so analysing something never raises the score.

### D5. The site layer: assumptions and acceptances

**Assumptions are checked, not acked.** An assessment's `assumes` is evaluated against the site's
own configuration at every scan:

| Key | Holds when |
|---|---|
| `maxExposure: internal` | the module instance has no public proxy route and sits in no zone of tier 4 or above |
| `maxExposure: authenticated` | every proxy route of the instance is behind identity |
| `zoneTier: "<=1"` | the instance's `zone0` tier is in range |
| `serviceOff: <service>` | the module's config has the service disabled |

When an assumption fails, the assessment does not apply on that site and the CVE is `review` with
the text "assumes internal only; nextcloud is public here". A site that deploys differently gets
the truth for its deployment without a site record, and when its exposure changes the next scan
picks it up.

**A site acceptance** is the one site record:

```json
{ "cve": "CVE-2026-109258", "package": "pkg:nix/imagemagick", "unit": "immich",
  "note": "Uploads are from two family accounts only.", "by": "lars", "at": "2026-11-10", "until": "2027-05-10" }
```

- Stored in the site's `config/security-acceptances.json`, written by
  `health-manager accept <unit> <CVE> --note … --until …` and by the console.
- Keyed by CVE, package without version, and unit. It survives version moves and rescans.
- `until` is mandatory, at most one year.
- It ends, and says so in the digest, when: `until` passes; the CVE enters the known-exploited
  list; the upstream severity rises; or a central decision now covers the CVE (the acceptance is
  archived as superseded).
- An accepted item leaves the level. The row shows "high, 2 accepted" so the acceptance stays
  visible and counted.
- `health-manager ack --type security` remains what it is: quiet mail for one CI. The console
  and the alert texts point at `accept` for CVEs.

A site cannot rate a CVE down in any other way. It can accept, with a date, or it can change its
deployment so an assumption holds.

### D6. The release ack becomes a deferral

A boundary ack for a CVE is spent at the release and tells no site anything. It becomes a central
record: `tappaas-train.sh ack --module <m> --note` writes a `deferred` entry for each CVE gate
item into `<module>-assess.json` on the pin branch, with `reviewBy` at the next boundary.

- Sites see "known, put off until 2026-11-23: <note>" next to the CVE, where today they see an
  unexplained open item.
- At the next boundary an expired deferral is a gate item again, so "accepted once" cannot become
  "accepted for ever".
- Majors and failed matches keep the ack in `release-train.json`. The record phase archives only
  the acks the gate actually used.

### D7. The view is a list of actions

The Security page and `health-manager report security` open with queues, and keep ADR-045's
site → zone → module table underneath as the detail.

**For a site's operator:**

| Queue | A card says | Source |
|---|---|---|
| Update | "Update to 2.4.1 clears 14 in 3 modules" | the site's scan against its channel's release record |
| Coming | "2.5 on 23 Nov clears 9" | the candidate's record on staging |
| Your decision | "immich: assumes internal only, public here (8 CVEs)"; "2 acceptances end this month" | D5 |
| With TAPPaaS | "31 packages in triage, oldest 6 days" | open and deferred items, grouped by package |
| With upstream | "12 assessed, no fix published" | assessed items |

Only the first and third need the operator. On a site that deploys TAPPaaS as shipped, "Your
decision" is empty.

**For the maintainers**, on the staging site (`tappaas-train.sh security`, and a console tab
shown where the train runs):

| Queue | A card says | Action |
|---|---|---|
| Move a pin | "karakeep 0.31.2 → 0.31.4 clears 9, adds 0, carries 41" | D8 |
| Decide | "curl on network: 21 open (6 critical), all AV:N/UI:R" | one `assess` or one VEX statement for the group |
| Review | auto-matched by a rule; carried inside a major; `reviewBy` within 14 days; upstream changed | tick, or re-decide |
| Deferred | due at the next boundary | fix, decide, or defer again with a note |

**A baseline finding is shown once.** A CVE in a package that comes from the shared NixOS closure
belongs to a `baseline` unit in the view. A module whose level is set only by baseline items
shows "medium, from the baseline" and its health condition is derived from the baseline's, so it
is not a root cause. The module's own packages and images stay its own. The score keeps counting
the item in each module, because it is present in each.

**Sized against hrossen today:**

| | Now | With this ADR |
|---|---|---|
| Site-level root causes from CVEs | 29 | 5 to 8: the baseline, the firewall, the nodes as one, and the modules with their own items |
| What to read to act | 24 unit rows, 1732 CVE rows | 14 Decide cards (31 by the nightly scan's count), 4 pin cards, under 10 Review cards |
| Decisions to settle the firewall | 21 statements, per curl version | 1 assessment with a rule, reviewed every 90 days |
| Decisions to move 22 units off medium | 3 statements × each sqlite version | 1 statement on `templates` |
| Hand confirmations at a boundary | 91 | the major-version moves only; the rest reviewed after the fact |

### D8. A daily check: would moving the pin help?

`tappaas-train.sh candidates` runs once a day on the staging site, after the rescan. It needs no
running guest and changes nothing in the repo.

| Target | Candidate | How it is scanned |
|---|---|---|
| Container image | the newest upstream tag of the same form, and the newest patch tag of the pinned minor (`image-pins.py` already lists both) | `trivy image` of the candidate reference, by digest; cached, so an unchanged digest is not scanned again |
| nixpkgs pin | the tip of the tracked release branch | the closures evaluated against it, as `pin-preview.py --to` does now |
| Debian guests, nodes, firewall | what the distribution's archive or channel already offers | the scan's own fix state: these patch themselves or with one channel update |

For each module it writes one proposal to `config/pin-candidates.json`:

- **Move:** from → to, the CVEs it clears, the ones it adds, the decisions that carry
  automatically and the ones that need a look, and whether it is a major.
- **Nothing helps:** no candidate clears the open items. The proposal is a triage workbook for
  them, grouped by package, each with its vector and, where an existing rule nearly fits, the
  assessment it would take.

A person approves. `tappaas-train.sh candidates apply <module>` writes the pin change to a branch
and stops; the live test and the merge are the maintainer's, as ADR-028 D4 requires. A proposed
statement or assessment is written with `cve-triage` by a person who has read it.

The check talks to the image registries and the nixpkgs channel. It does not touch Codeberg.

### D9. Two defects to fix first

Both make every number in the view unreliable, so they come before it:

1. **The rescan must match what the scan matched.** On Debian and image targets the daily rescan
   finds about a third of the nightly scan's findings. Whichever side is wrong, both must agree
   on the same inventory, and a test must hold them to it.
2. **"New" means first seen.** A ledger `config/sbom/first-seen.json` (target, CVE, package →
   date) replaces the comparison with the previous file. A CVE is new once.

## Consequences

- **Good.**
  - A reclassification is a record with a reason, an author and an end date, and it re-opens by
    itself when upstream or the site's exposure changes.
  - The number of decisions follows the number of packages and reasons, not CVEs times versions.
  - A site that runs TAPPaaS as shipped has nothing to decide. One that does not is told exactly
    which assumption it breaks.
  - The records are data with no code in them, so they can be delivered apart from releases.
- **Cost.**
  - A second file per module and a migration: 190 `exploitable` statements become assessments,
    grouped by package and reason. 1708 statements gain a `versions` field.
  - CVSS re-scoring in `lib/ts`, with the vectors kept by the scan.
  - A console page reorganised around queues.
  - A daily job that pulls image metadata and layers for up to 13 images when tags move.
- **Risk.**
  - **A coarse rule hides a real CVE.** A rule is limited to one module and one package, a
    matched CVE is marked `auto` and queued for a read, and known-exploited overrides everything.
  - **Automatic carries inside a major miss a change in reachability.** They are reviewed after
    the fact; the statement's text and the version it moved from are in the queue.
  - **Acceptances pile up.** They end by date, are counted beside every score, and cannot be
    made without one.
  - **Assumption checks are wrong.** A check that cannot be evaluated counts as failed.

## Phases

| Phase | Content | Done when |
|---|---|---|
| P0 | D9: scan and rescan agree; the first-seen ledger | Two days on hrossen with the same counts from both runs and no repeated `cve-new` |
| P1 | D2, D4: the scan keeps vectors, KEV and EPSS; `<module>-assess.json`; `cve-triage assess`; re-scoring; the `assessed` and `review` states; migration of the 190 rated statements | The firewall's curl items are one assessment and hrossen's site level follows from it |
| P2 | D3: `versions` ranges, automatic carry inside a major in the `cve` phase, multi-CVE statements | A rehearsal boundary carries without a hand commit and lists what it carried |
| P3 | D5: `assumes` evaluation, `health-manager accept`, the `accepted` state | A test module made public on hrossen turns its assessment into `review`; an acceptance survives an image bump |
| P4 | D6: deferrals from `ack`; the record archives only used acks | The next boundary's gate lists an expired deferral |
| P5 | D7: the queues in `report security` and the console; the baseline unit; derived health conditions | hrossen's page opens with the queues, and CVE root causes drop below 10 |
| P6 | D8: `candidates` and `candidates apply` | A daily run on hrossen proposes a move for an image with a newer patch tag, with its cleared and added CVEs |

## Open questions

1. **Does a site acceptance lower the site's level?** Proposed: yes, with the count shown beside
   it (D5). The alternative keeps the level central and makes acceptance a mail matter only,
   which is what the unused health ack does today.
2. **Are rules (`match`) acceptable**, or must every CVE be listed by hand? Proposed: rules,
   inside one module and package, with a read-after queue. Without them the firewall is 21 entries
   again at the next curl release.
3. **Automatic carry inside a major for `code_not_reachable`** reverses ADR-045's "never
   automatic". Proposed: yes, reviewed afterwards. The alternative keeps about 90 confirmations
   per boundary.
4. **Review period**: 90 days by default and 180 at most. With decisions per package the yearly
   load is roughly 400 groups × 4 reads if nothing is merged further; is that acceptable, or
   should deployment-based decisions run a year?
5. **Assessed and open at the same points** (20 and 8) in place of 25/20 and 10/8. It removes the
   small penalty for analysing; it also means a confirmed critical and an unread one look alike.
6. **Who may author a central decision?** Proposed: the deciders of this ADR, by commit, as now.
   Contributors propose through a pull request. The security stream ADR depends on this answer,
   because the feed's signature is this person's.
7. **`security` as one condition type** for CVE levels and for other security reasons (seen on
   unifi-os) belongs to the health review; this ADR only needs CVE conditions to be told apart.
