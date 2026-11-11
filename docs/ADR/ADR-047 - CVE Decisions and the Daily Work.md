# ADR-047 — CVE Decisions and the Daily Work

| | |
|---|---|
| **Status** | **Proposed** — every question settled with the operator; for his review |
| **Version** | 0.4 |
| **Date** | 2026-11-11 |
| **Author** | Lars Rossen |
| **Deciders** | @LarsRossen |
| **Closes / addresses** | Amends ADR-045 (D1 states, D2 lifecycle, D5 gate) and ADR-011 §8 (VEX). Built on the measurement in [`docs/plans/cve-as-built.md`](../plans/cve-as-built.md). Delivery to production is [ADR-048](<ADR-048 - The Security Stream.md>). |
| **Changelog** | v0.1 (2026-11-10): first draft. v0.2 (2026-11-10): the operator's answers. Central decisions are **per component**, not per CVE and version: the component record replaces the assessment file, and VEX is generated from it (D2, D3). A site acceptance **lowers the site's score** (D5). Decisions reach production **faster than code** (ADR-048). The scan/rescan defect and "new means first seen" are **built** (D9); every figure is re-sized against the corrected scan. v0.3 (2026-11-11): the operator's answers to the open questions. **A decision is a reclassification** (D4): every CVE has an effective level, the same as upstream, lower, or none, and is scored by that level alone; the separate points for analysed and unanalysed items go. An unread CVE differs from a confirmed one in the view, not in points. The in-between level is expressed in VEX as `exploitable` with a TAPPaaS rating. Version scope settled: automatic inside a major, Review at a new major. Review period settled: 90 days (180 at most) for records grounded in how the code is used, one year for records grounded in how TAPPaaS is deployed. Authors as proposed. The condition-type question goes to the health review. v0.4 (2026-11-11): **Proposed.** The single points table is 20 / 8 / 3 / 1, so levels stay where they are today and fall as decisions are made. No question is open. |

ADR-045 gave CVEs a lifecycle and a score. Running it for one boundary showed that the records
are the wrong size for daily work: a VEX statement is one CVE at one version, a site ack is a
whole CI, and nothing in between says "this critical counts as high here, because". This ADR
makes the **component** the unit of a central decision, gives a reclassification a reason, an
author and an end date, separates what TAPPaaS decides from what a site decides, and turns the
operator's list of CVEs into a list of actions.

**Why a new ADR and not an amendment.** ADR-045 is accepted and live, and its score, bands and
boundary phase stay. This changes the record model under it and adds a site layer and a daily
check. Folding that into ADR-045 would bury a second decision in the first one's history.

## Context

Measured on hrossen on 2026-11-10, with the corrected scan (D9):

- 37 scan targets in 24 scored units: 1 critical, 2 high, 21 medium. Expanding them lists 2414
  CVE rows: 209 open, 189 analysed, 18 carried, 1998 decided.
- The 82 open critical/high CVEs sit in 31 packages, and in 56 unit-and-package pairs. Counted as
  components (D2) they are about 40: the baseline's sqlite is one, not 17.
- The site is critical because of 21 curl CVEs on the firewall. One sentence about how the
  firewall uses curl settles them. Today that is 21 statements pinned to curl 8.21.0.
- Three sqlite highs from the NixOS baseline are the only open items of 15 units and set their
  level.
- 1708 VEX statements fall into 398 module-and-package groups with 767 distinct analysis texts.
  1215 of the 1502 `not_affected` statements say `code_not_reachable`: the module does not use
  the affected part. That is a statement about how a module uses a component, recorded once per
  CVE and version.
- The 2.4 boundary removed 213 statements and carried 92; 91 were confirmed by hand the same day.
  The next boundary will remove about 440.
- A reclassification exists only as `exploitable` plus a rating, with no author, date, expiry or
  structured reason.
- Site acks on CVEs: none. A site ack silences a CI's mail and changes no score.
- No step looks at a newer upstream version.

## Decision

### D1. Three layers, each with one writer

| Layer | Question it answers | Writer | Where |
|---|---|---|---|
| **Facts** | What is installed, and which CVEs match it? | the scan | `config/sbom/` on the site |
| **Central decisions** | How does TAPPaaS use this component, and what does that make of its CVEs? | TAPPaaS maintainers | the repo, next to the module; delivered by the feed (ADR-048) |
| **Site decisions** | Does this installation accept what is left? | the site's operator | the site's `config/` |

A central decision is true for every site that deploys the module the way TAPPaaS ships it. A
site decision is only for what makes a site different, and should be rare. The scan applies them
in a fixed order: a central "not affected" wins; then a site acceptance; then the central
contextual severity; then the upstream severity.

### D2. The component is the unit of a central decision

**What a component is.** One upstream project as one module uses it:

| Part | Is | Examples |
|---|---|---|
| module | the module, `templates` for the shared NixOS baseline, or a platform role | `network`, `immich`, `templates`, `pvehost` |
| ecosystem | where the package comes from | `nix`, `deb`, `opnsense`, `npm`, `pypi`, `go` |
| source name | the upstream source project, not the binary package | `curl`, `tiff` (for libtiff6, libtiff-dev, libtiffxx6), `sqlite`, `imagemagick` |

Written `network/opnsense:curl`, `karakeep/deb:tiff`, `templates/nix:sqlite`. For Debian and
Alpine the source name is the distribution's source package, which the scan now keeps for every
package (D9); for Nix it is the package name; for a language package its registry name. A
package whose findings match no record forms a component by itself, so every finding belongs to
exactly one component, and a component can exist with no record yet. hrossen's 1708 statements
fall into 398 such groups.

The same upstream project in two modules is two components. immich and nextcloud both ship
ImageMagick and use it differently. What they share through the baseline is decided once, on
`templates`.

**The record.** `<module>-components.json` holds one entry per component:

```json
"network/opnsense:curl": {
  "use": "Outbound only. The firewall's update job and an administrator fetch firmware, packages and lists from the configured mirrors. No service on the firewall passes a URL from the network to curl.",
  "reason": "client-only",
  "assumes": { "maxExposure": "internal" },
  "versions": "8.*",
  "rules": [
    { "id": "r1", "match": { "AV": ["N"], "UI": ["R", "A", "P"] }, "modified": { "MAV": "A" },
      "why": "The attacker has to control a mirror or sit on the management path." }
  ],
  "cves": {
    "CVE-2026-86413": { "rule": "r1", "read": "larsrossen 2026-11-10" },
    "CVE-2026-94265": { "level": "none", "state": "not_affected", "justification": "code_not_reachable",
                         "why": "HTTP/3 is not built into the firewall's curl." },
    "CVE-2026-97001": { "level": "high", "why": "No vector published. Needs a hostile mirror; the effect is code execution as root." },
    "CVE-2026-87866": { "level": "same", "why": "Reachable from the WAN side through the captive portal's fetch." }
  },
  "author": "larsrossen", "decided": "2026-11-10", "reviewBy": "2027-11-10",
  "basis": { "CVE-2026-86413": { "severity": "Critical", "vector": "CVSS:3.1/AV:N/AC:L/PR:N/UI:R/S:C/C:H/I:H/A:H", "kev": false } }
}
```

- **`use`** is the standing statement: how this module uses this component. It is mandatory, at
  least 80 characters, and shown wherever a decision from this record is shown.
- **`reason`** from a fixed list, in two groups. Grounded in **how the code is used**:
  `not-used`, `feature-disabled`, `client-only`, `admin-input-only`. Grounded in **how TAPPaaS
  is deployed**: `internal-only`, `local-access-required`, `mitigated-by-rule`,
  `data-not-sensitive`. And `other`, which counts as the first group. The view groups by it, and
  the review period follows from it.
- **`assumes`**: what must be true at a site for the record to hold (D5).
- **`versions`**: which versions of the component the `use` statement holds for (D3).
- **`rules`**: a reclassification for every CVE of this component whose upstream CVSS vector
  matches. `modified` holds CVSS environmental metrics; the effective level is the upstream
  vector re-scored with them, so it is computed, checkable, and moves when upstream changes the
  vector. A rule can lower a level or leave it. It can never set it to none.
- **`cves`**: the reclassification of a CVE by name (D4). `level: none` exists only here, each
  added by a person with a VEX state and a justification. Another entry confirms a rule's result
  (`rule` and `read`), sets its own (`modified`, or a plain `level` where the CVE has no usable
  vector, as with VuXML entries), or confirms the upstream level (`same`).
- **`author`, `decided`, `reviewBy`**: `reviewBy` is mandatory and is the component's date, not
  each CVE's. A record grounded in how the code is used is reviewed after 90 days by default and
  180 at most: code changes under it. A record grounded in how TAPPaaS is deployed runs one
  year, and must carry `assumes`: the deployment it rests on is checked on every site at every
  scan (D5), so the date is a backstop.
- **`basis`**: what upstream said when each CVE was decided, written by the tool.

`cve-triage.sh component <module> <source> …` creates and edits records. Before it writes, it
prints every CVE on the last scan that the record would cover and what each would become.

**VEX is generated.** `<module>-vex.json` stays, as CycloneDX, for anyone who wants the standard
format. It is written by `cve-triage.sh export` from the component records and the versions the
channels ship, at each feed build and each boundary, one statement per CVE as D4 shows. Nobody
edits it. The boundary's "gone" and
"carried" bookkeeping (ADR-045 D2) goes away with the hand-kept statements.

**The scan keeps the CVSS vector, the known-exploited flag and the EPSS score** of each finding.
Grype and trivy report all three; today the scan drops them.

### D3. How a wrong coarse decision gets caught

A component record covers CVEs nobody has read yet. That is its purpose and its risk. Seven
guards, from the structure outward:

| Guard | What it catches |
|---|---|
| **A rule re-rates, it never hides.** Only a named CVE can be `not_affected`. | A blanket "this component does not matter". The CVE stays on the page at its contextual severity. |
| **A matched CVE is marked "by rule" until read.** It sits in the maintainers' Review queue with its description and the rule that caught it. Unread after 14 days, it counts at its upstream severity again. | A CVE that fits the rule's vector and not its reasoning. |
| **Known-exploited overrides everything.** The CVE counts at its upstream severity at once and raises `cve-new-critical`. An EPSS above 10 % sends it to Review. | A CVE the rule underrated and attackers did not. |
| **Upstream changed its mind.** The vector or severity differs from `basis`: back to Review. | A decision made on an early, wrong advisory. |
| **`assumes` is checked on every site, every scan** (D5). | A site that deploys the module differently from what the `use` statement describes. |
| **`versions` ends.** Inside the component's major version the record carries on by itself and nothing is asked. A new major sends the whole record to Review. | A `use` statement that a rewrite of the component made untrue. |
| **`reviewBy`** (90 to 180 days, or a year: D2). The record is listed 14 days before the date, and stops applying 14 days after it. | A `use` statement that stopped being true while nobody looked. |

Two more are cheap and visible. The release notes and the console show, per component, how many
CVEs a rule re-rated and from what to what, so "21 CVEs, 6 critical to high, by one rule" is in
front of every reader. And a rule is limited to environmental metrics: it cannot lower a CVE by
more than the CVSS arithmetic allows for the stated change in exposure.

When any guard fires, the affected CVEs are marked `review` (D4): their effective level is the
upstream level again, with the old decision attached. Three of the guards (upstream change, version, date)
leave the old result in force for 14 days so a date does not turn a site critical overnight.

### D4. A decision is a reclassification

Every CVE has two levels: the **upstream level** (what the advisory says) and the **effective
level** (what it is in a TAPPaaS deployment). A central decision is the step from one to the
other. It has three possible outcomes, and all three are VEX:

| Outcome | Effective level | In the record | In the generated VEX (CycloneDX) |
|---|---|---|---|
| **None** | none | `level: none` with a state and a justification | `analysis.state`: `not_affected` with `justification` (`code_not_reachable`, …), `false_positive`, or `resolved`; `analysis.detail`: the `use` statement and the `why` |
| **Lower** | low, medium or high, below upstream | a rule's `modified` metrics, or `modified` or `level` by name | `analysis.state: exploitable`, and a `ratings[]` entry from TAPPaaS carrying the environmental vector |
| **Same** | the upstream level | `level: same` | `analysis.state: exploitable`, and a TAPPaaS rating equal to upstream's, with the reason it stands |
| not yet decided | the upstream level | no entry | `analysis.state: in_triage`, no TAPPaaS rating |

The in-between case, a critical that counts as high on the firewall:

```json
{ "id": "CVE-2026-86413",
  "affects": [{ "ref": "pkg:generic/opnsense/curl@8.21.0" }],
  "ratings": [
    { "source": { "name": "NVD" }, "method": "CVSSv31", "severity": "critical", "score": 9.6,
      "vector": "CVSS:3.1/AV:N/AC:L/PR:N/UI:R/S:C/C:H/I:H/A:H" },
    { "source": { "name": "TAPPaaS" }, "method": "CVSSv31", "severity": "high", "score": 8.8,
      "vector": "CVSS:3.1/AV:N/AC:L/PR:N/UI:R/S:C/C:H/I:H/A:H/MAV:A",
      "justification": "client-only: the attacker has to control a mirror or sit on the management path." } ],
  "analysis": { "state": "exploitable",
    "detail": "network/opnsense:curl. Outbound only. The firewall's update job and an administrator fetch firmware, packages and lists from the configured mirrors. Reclassified by rule r1; read by larsrossen 2026-11-10; review by 2027-11-10." } }
```

`exploitable` is CycloneDX's word for "affected, and counted". The TAPPaaS rating beside the
upstream one is the reclassification: the same vector with the environmental metrics added, the
score and level that follow from it, and the reason. A consumer that reads only `analysis.state`
sees an affected component; one that reads ratings sees both levels and why they differ. Where a
CVE has no vector, the TAPPaaS rating has `method: other`, a level and the justification.

**The score counts the effective level, and nothing else.** One table replaces ADR-045's two:

| Effective level | critical | high | medium | low | none |
|---|---|---|---|---|---|
| Points | 20 | 8 | 3 | 1 | 0 |

ADR-045's rules stay: only the highest category with an item counts, each further item at half
the one before, the bands 0 / 7 / 16 / 30, the zone multipliers. As in ADR-045, a CVE whose
upstream level is medium or low and that nobody has reclassified is listed and not counted.

Whether somebody has read a CVE no longer changes its points. It changes **what the view says**:

| Mark | Meaning | Shown as |
|---|---|---|
| **unread** | the effective level is upstream's because nobody has decided | a hollow level badge; in the maintainers' Decide queue; a unit row reads "high · 3 unread"; new ones are mailed (`cve-new-critical`) |
| **by rule** | a rule set the level and no person has read this CVE yet | the level badge with "by rule"; in the Review queue; back to unread after 14 days |
| **confirmed** | a person decided: none, lower or same | a solid badge with the reason code; the row expands to the `use` statement, the `why`, the author and the date |
| **deferred** | known and put off with a note until a date (D6) | hollow, with the note and the date |
| **review** | a decision existed and a guard of D3 fired, or a site assumption fails | hollow, with the old decision and what changed |
| **accepted** | this site accepted it (D5) | struck through, counted beside the score: "high · 2 accepted"; no points |

So a unit that is high because of three unread CVEs and one that is high because of three
confirmed ones have the same score and level, and read differently at a glance: the first is
work for the maintainers, the second is the true state until upstream fixes it. The site, zone
and environment rows carry the same split: "critical · set by network (7 unread)".

**What the single table changes.** The weights are ADR-045's for an unanalysed item, now for
every counted CVE. A level that rests on unread CVEs stays exactly where it is today: hrossen's
15 baseline-only units stay medium (8 + 4 + 2 = 14), the firewall stays critical. A level that
rests on confirmed items counts a little less than under ADR-045 (a critical 20 where it was 25,
a high 8 where it was 10): karakeep's four confirmed highs read medium (15) where they read high
(18.75). So nothing rises on the day this is deployed, and every level can only fall as
components are decided. One confirmed critical is still high, and critical in the management
zone.

### D5. The site layer: assumptions and acceptances

**Assumptions are checked, not acked.** A record's `assumes` is evaluated against the site's own
configuration at every scan:

| Key | Holds when |
|---|---|
| `maxExposure: internal` | the module instance has no public proxy route and sits in no zone of tier 4 or above |
| `maxExposure: authenticated` | every proxy route of the instance is behind identity |
| `zoneTier: "<=1"` | the instance's `zone0` tier is in range |
| `serviceOff: <service>` | the module's config has the service disabled |

When an assumption fails, the record does not apply on that site and its CVEs are `review` with
the text "assumes internal only; nextcloud is public here". A site that deploys differently gets
the truth for its deployment without writing anything, and when its exposure changes the next
scan picks it up. A check that cannot be evaluated counts as failed.

**A site acceptance** is the one site record:

```json
{ "component": "immich/nix:imagemagick", "cve": "CVE-2026-109258", "unit": "immich",
  "note": "Uploads are from two family accounts only.", "by": "lars", "at": "2026-11-10", "until": "2027-05-10" }
```

- Stored in the site's `config/security-acceptances.json`, written by
  `health-manager accept <unit> <CVE> --note … --until …` and by the console. `--component`
  without a CVE accepts every CVE of that component currently counted, by name; it does not
  cover future ones.
- Keyed by component, CVE and unit. No version: it survives version moves, rescans and upgrades.
- `until` is mandatory, at most one year.
- **It lowers the site's score.** An accepted item has no points on that site, for its unit and
  for the zone, environment and site above. The row reads "high · 2 accepted" so the acceptance
  stays visible and counted.
- It ends, and says so in the digest, when: `until` passes; the CVE becomes known-exploited; the
  upstream severity rises; or a central decision now covers the CVE (archived as superseded).
- `health-manager ack --type security` remains what it is: quiet mail for one CI.

A site cannot rate a CVE down in any other way. It can accept, with a date, or change its
deployment so an assumption holds.

### D6. The release ack becomes a deferral

A boundary ack for a CVE is spent at the release and tells no site anything. It becomes a central
record: `tappaas-train.sh ack --module <m> --note` writes a `deferred` entry for each CVE gate
item into its component's record, with `reviewBy` at the next boundary.

- Sites see "known, put off until 2026-11-23: <note>" next to the CVE.
- At the next boundary an expired deferral is a gate item again.
- Majors and failed matches keep the ack in `release-train.json`. The record phase archives only
  the acks the gate used.

### D7. The view is a list of actions

The Security page and `health-manager report security` open with queues, and keep ADR-045's
site → zone → module table underneath as the detail. A card is a component, never a CVE.

**For a site's operator:**

| Queue | A card says | Source |
|---|---|---|
| Update | "Update to 2.4.1 clears 14 CVEs in 3 components" | the site's scan against its channel's newest release record |
| Coming | "2.5 on 23 Nov clears 9" | the candidate's record |
| Your decision | "immich: assumes internal only, public here (ImageMagick, 8 CVEs)"; "2 acceptances end this month" | D5 |
| With TAPPaaS | "31 components in triage, oldest 6 days" | open and deferred items |
| With upstream | "12 components confirmed, no fix published" | confirmed items that still count |

Only the first and third need the operator. On a site that deploys TAPPaaS as shipped, "Your
decision" is empty.

**For the maintainers**, on the staging site (`tappaas-train.sh security`, and a console tab
shown where the train runs):

| Queue | A card says | Action |
|---|---|---|
| Move a pin | "karakeep 0.31.2 → 0.31.4 clears 9, adds 0" | D8 |
| Decide | "curl on network: 21 open (6 critical), all AV:N/UI:R, no record" | write the component record |
| Review | matched by a rule and unread; a guard of D3 fired; `reviewBy` within 14 days | read and tick, or re-decide |
| Deferred | due at the next boundary | fix, decide, or defer again with a note |

**A baseline component is shown once.** A component of `templates` appears as one card and one
row, with the count of units that contain it. A module whose level is set only by baseline
components shows "medium, from the baseline", and its health condition is derived from the
baseline's, so it is not a root cause. The score keeps counting the item in each module, because
it is present in each.

**Sized against hrossen:**

| | Now | With this ADR |
|---|---|---|
| What to read to act | 24 unit rows, 2414 CVE rows | about 40 Decide cards until the records exist, then the Review queue; a handful of pin cards |
| Open CVEs behind those cards | 82 | the same 82, grouped: curl on the firewall 21, ImageMagick in immich 8, libheif in vllm-amd 8, qemu-guest-agent on unifi-os 6, expat in three places 4 each, sqlite once for the baseline |
| Decisions to settle the firewall's curl | 21 statements, again at each curl version | 1 record with one rule, read again every 90 days |
| Decisions to move 15 units off medium | 3 statements per sqlite version | 1 record on `templates` |
| Hand-kept statements | 1708, a quarter replaced per boundary | about 400 component records; VEX generated |
| Hand confirmations at a boundary | 91 | a review when a component changes major version |
| Site-level root causes from CVEs | 29 | under 10: the baseline once, the firewall, the nodes, and the modules with components of their own |
| Site decisions on a default deployment | none possible that change the score | none needed |

The nightly scan and the rescan now give these same figures (D9); the lower figures in the
as-built document's rescan column were the defect.

### D8. A daily check: would moving the pin help?

`tappaas-train.sh candidates` runs once a day on the staging site, after the rescan. It needs no
running guest and changes nothing in the repo.

| Target | Candidate | How it is scanned |
|---|---|---|
| Container image | the newest upstream tag of the same form, and the newest patch tag of the pinned minor (`image-pins.py` already lists both) | `trivy image` of the candidate reference, by digest; cached, so an unchanged digest is not scanned again |
| nixpkgs pin | the tip of the tracked release branch | the closures evaluated against it, as `pin-preview.py --to` does now |
| Debian guests, nodes, firewall | what the distribution's archive or channel already offers | the scan's own fix state: these patch themselves or with one channel update |

For each module it writes one proposal to `config/pin-candidates.json`:

- **Move:** from → to, the CVEs it clears and adds per component, whether a component leaves its
  record's `versions`, and whether the move is patch-level (eligible for ADR-048's patch line) or
  a minor or major (the train).
- **Nothing helps:** no candidate clears the open items. The proposal is a draft component record
  for each undecided component: its CVEs with their vectors, and the rule that would cover most
  of them.

A person approves. `tappaas-train.sh candidates apply <module>` writes the pin change to a branch
and stops; the live test and the merge are the maintainer's, as ADR-028 D4 requires. A draft
record becomes a record when a person has written its `use` statement.

The check talks to the image registries and the nixpkgs channel. It does not touch Codeberg.

### D9. Two defects, fixed first (built)

1. **The rescan now matches what the scan matched.** The stored inventory kept a package's name,
   version and purl, and dropped its source package. Debian and Alpine file advisories under the
   source package, so the rescan matched libtiff6 against advisories for `libtiff6` instead of
   `tiff` and found nothing. The scan now keeps each package's source name, version and release
   under trivy's own property names, and the rescan hands them back. An inventory taken before
   the fix is not matched thinner: the last scan's result stands until the next full scan.
2. **"New" means first seen.** `config/sbom/first-seen.json` records, per target, when each
   critical/high CVE was first and last counted. A CVE is new once. One not counted for 30 days
   is forgotten, so a regression is announced again.

Proved on hrossen on 2026-11-10 in a scratch copy of its configuration: the fixed scan and the
fixed rescan of its inventory agree on all 37 targets (6213 findings, 191 critical/high CVEs, the
same state for every item), the scan equals the live nightly scan, and with the ledger seeded
from the site's two stored scans nothing is announced as new (the live nightly scan had announced
361 keys, 109 of them open). Commit 17fe1acf; it takes effect on a site with the first full scan
after the update.

## Consequences

- **Good.**
  - The number of decisions follows the number of components, not CVEs times versions.
  - A reclassification is a record with a use statement, an author and an end date, and it
    re-opens by itself when upstream or the site's exposure changes.
  - A site that runs TAPPaaS as shipped has nothing to decide. One that does not is told which
    assumption it breaks, and can accept what is left with a date.
  - The records are data with no code in them, so they can be delivered apart from releases.
- **Cost.**
  - A migration: 1708 statements become about 400 component records. A tool groups them and
    carries the per-CVE decisions over; each record's `use` statement needs a person. Until a
    record has one, its migrated per-CVE decisions keep working and it is listed for review.
  - CVSS re-scoring in `lib/ts`, with the vectors kept by the scan.
  - A console page reorganised around queues.
  - A daily job that pulls image metadata and layers for up to 13 images when tags move.
- **Risk.**
  - **A coarse rule underrates a real CVE.** D3.
  - **Acceptances pile up.** They end by date, are counted beside every score, and cannot be
    made without one.
  - **The migration loses a decision.** The generated VEX is compared with the hand-kept files
    before the switch; the scan must count the same items the day before and the day after.

## Phases

| Phase | Content | Done when |
|---|---|---|
| P0 | D9 | **Built.** Deployed with the next update of hrossen; two nights with the same counts from scan and rescan and no repeated `cve-new` |
| P1 | D2: the scan keeps vectors, known-exploited and EPSS; the component key; `<module>-components.json`; `cve-triage component`; re-scoring; the reclassification outcomes and marks of D4, the single points table | The firewall's curl items are one record and hrossen's site level follows from it |
| P2 | Migration of the 1708 statements; `cve-triage export`; the boundary's `cve` phase generates VEX | The scan counts the same items from the records as from the old files; a rehearsal boundary needs no carry commit |
| P3 | D3: the guards, the "by rule" mark, the Review queue | A new CVE matching a rule is reclassified the same night and listed "by rule"; a known-exploited one is not lowered |
| P4 | D5: `assumes` evaluation, `health-manager accept`, the `accepted` state in the score | A test module made public on hrossen turns its record into `review`; an acceptance lowers the level and survives an image bump |
| P5 | D6: deferrals from `ack`; the record archives only used acks | The next boundary's gate lists an expired deferral |
| P6 | D7: the queues in `report security` and the console; the baseline shown once; derived health conditions | hrossen's page opens with the queues |
| P7 | D8: `candidates` and `candidates apply` | A daily run on hrossen proposes a patch-level image move with its cleared and added CVEs |

## Settled in review

Settled in v0.2 (operator, 2026-11-10): the scan/rescan defect is fixed before anything else; a
site acceptance lowers that site's score; central decisions are per component, not per CVE and
version; decisions reach production faster than code, through a separate feed (ADR-048).

Settled in v0.3 (operator, 2026-11-11): a decision is a reclassification, to the same level, a
lower one, or none, and a CVE is scored by its effective level alone; an unread CVE differs from
a confirmed one in the view, not in points. A record carries on inside the component's major
version and goes to Review at a new major. Review after 90 days (180 at most) for records
grounded in how the code is used, one year for records grounded in how TAPPaaS is deployed.
Central decisions are authored by the deciders of this ADR, by commit; contributors propose them
through a pull request. Whether `security` should be one condition type for CVE levels and for
other security reasons is the health review's question.

Settled in v0.4 (operator, 2026-11-11): the single points table is 20 / 8 / 3 / 1 / 0.

## Open questions

None.
