# ADR-045 — CVE Lifecycle and Risk Scores

| | |
|---|---|
| **Status** | **Accepted** — implementation started 2026-11-07 |
| **Version** | 1.0 |
| **Date** | 2026-11-07 |
| **Author** | Lars Rossen |
| **Deciders** | @LarsRossen |
| **Closes / addresses** | Follows #788 (release CVE preview and ack). Amends ADR-011 §8 (VEX lifecycle), ADR-028 (the boundary gains a CVE phase and a release score), ADR-041 (security conditions take their status from the risk level) and ADR-039 (an alert for new critical/high CVEs). |
| **Changelog** | v0.1 (2026-11-07): first draft, from the operator's direction of 2026-11-07, after the 2.4 preview walk-through of immich. v0.2 (2026-11-07): the operator's review. Only the highest category counts, each further item at half the one before; open items 20/8; no fix multiplier; zones (×0.25 DMZ, ×2 management) between modules and environments; zones outside every environment roll up to the site; analysed low/medium pass without an ack; woodpecker is a module like any other. v0.3 (2026-11-07): the operator's review. Level bands 0/7/16/30, so one new critical is high and not critical outside the management zone; zone multipliers by tier (0 ×2, 1 ×1, 2 ×0.75, 3 ×0.5, 4 ×0.25, 5–6 ×0.1). v1.0 (2026-11-07): **Accepted** by the operator. A zone without a tier counts ×1; the firewall counts in the management zone. |

A site keeps three CVE records today: the nightly scan, the VEX statements in the repo, and the
acks for the next boundary. None of them cleans itself, and none of them adds up to a number an
operator can watch. This ADR gives them a lifecycle and one score:

1. **Cleanup is automatic.** The boundary removes VEX statements that no longer match anything
   any channel ships, lists the ones a version change has made inapplicable, and archives the
   acks it used.
2. **One risk score**, computed the same way for a running module, a zone, an environment, the site and
   a release candidate. The health view, the console and the alerts use it.
3. **A documented release process**: triage into VEX, fix what can be fixed, ack the rest, and
   record each module's release score.

## Context

What exists (2026-11-07, v2.4 candidate):

- **The nightly scan.** `health-manager scan security` runs after each sweep
  (`tappaas-security-scan.service`, started by `update-tappaas.service`). It writes
  `config/sbom/cve-status.json`. Each target has critical/high counts, a `verdict`
  (act/act-low/watch/triage/failed), `critHighRisk`, a `riskLevel` (the worst TAPPaaS rating
  among the `exploitable` statements), `critHighVex` and `new` (critical/high since the last
  scan).
- **The release preview.** `tappaas-train.sh preview` compares the last release with "if
  released now", per module, for critical/high only. Each CVE is `open`, `risk` (analysed and
  still counted) or `ack`. A critical/high CVE that is new against the last tag, a major version
  change, or a failed match goes into the **gate**. The boundary stops until every gate item is
  acked.
- **VEX.** `<module>-vex.json` (CycloneDX 1.5) and `templates-vex.json` for the baseline.
  `cve-triage.sh add` pins each statement to the exact package version it analysed. A version
  bump silently stops a statement applying.
- **Acks** live in the site's `config/release-train.json` `.ack`. They are not pinned to a pin
  or a preview. The boundary deletes them all on success, and `record` keeps only the item list
  in `release/releases.json`, not the notes.

What is missing:

| Gap | Effect, seen on the 2.4 walk-through |
|---|---|
| No stale-VEX detection | immich has 3 of 71 statements that match nothing any more (libssh 0.12.2, libtiff 4.7.2 ×2). Nobody notices. |
| No re-triage signal | A pin move turns a decided CVE back into an `open` one with no hint that it was analysed before. The baseline's 11 open items were all decided for glibc 2.42-100; the pin ships 2.42-103. |
| Acks are unpinned and wiped wholesale | An ack made against one preview covers the same key in a later pin. Stale acks are never shown. The notes are lost at the boundary. |
| A new analysed RISK still needs an ack | Work already done in VEX is asked for again. |
| No score | Risk is a worst-of word (`low`…`critical`) per row, used only by the preview. |
| No alert for new critical/high | `notify` mails only newly *fixable* findings. A new critical with no fix, or a new RISK, sends nothing. CVE health conditions are never critical and reach only the daily digest. A module that is already warning raises no event when it gets worse. |
| The console shows almost nothing | `/api/security` exists, but no page uses it (`/security` is `live: false`). There is a "CVE act" badge and an Overview tile, and no counts, risk level or trend. |
| The scan only runs after a sweep | A CVE published on a quiet day waits for the next sweep. |
| No release runbook or policy | RELEASE-TRAIN.md documents the commands, but not the order of work, what may be acked versus what must be triaged, or what a release records. |

## Decision

### D1. Every counted CVE has one of four states

The same states apply on a running site and in a release candidate, per module (and per platform
target):

| State | Meaning | Source |
|---|---|---|
| **decided** | A VEX statement says not affected, false positive or resolved. Not counted. | `<module>-vex.json`, `templates-vex.json`, nixpkgs patches |
| **risk** | Analysed and exploitable here, with a TAPPaaS rating (low/medium/high/critical). Counted at its rating. | `exploitable` statement with a `ratings[]` entry |
| **open** | Critical/high, and nobody has analysed it. Counted at a penalty (D3). | — |
| **carried** | Was decided or analysed for another version of the same package, and that version no longer ships. Counted as open until someone confirms it. | Detected by D2 |

`carried` is new. It turns "silently stopped applying" into a visible item with the previous
analysis attached, so re-triage is one confirmation instead of a fresh analysis.

### D2. Automatic VEX and ack cleanup at the boundary

A new boundary phase, **`cve`**, runs after `pin_gate` passes and before `prove`. It commits to
the pin branch, so the change is in the release and in its history. It does three things:

1. **Classify every VEX statement** against what the supported channels ship after the
   boundary: the new main and the new staging (the candidate), and the new stable (the promoted
   staging). For each statement:
   - **live:** it matches a finding in at least one of those closures or images. Keep it.
   - **carried:** the CVE is still found for the same package, at a version the statement does
     not name. Keep it, and list it in the preview's CARRIED column.
   - **gone:** the CVE is not found in any version of the package in any channel. Remove it.

   "Gone" is judged against all three channels, not just the candidate. Production keeps
   running the previous release until it updates, and its statements must stay until no channel
   ships that version.
2. **Re-pin is one confirmation.** `cve-triage.sh carry <module> [<CVE>…]` re-pins carried
   statements to the version now shipped, keeping the analysis text and adding a line
   `carried from <old version> on <date>`. It is never automatic. A new version can change
   reachability, so a person confirms. The preview shows the old analysis next to each carried
   item, so confirming is a reading job.
3. **Archive and reset the acks.** The `record` phase copies the full ack (items, notes, the pin
   and the preview digest it was given against) into the release's entry in
   `release/releases.json`, then deletes it, as today. New: an ack stores the preview `digest`
   and pin it was given for, and the boundary refuses an ack whose pin differs from the pin it
   took, unless the gate items it covers are unchanged. The preview lists **stale acks** (acked
   items no longer in the gate) and `ack` drops them when it writes.

Between boundaries the preview reports the same classification (LIVE/CARRIED/GONE counts per
module) without changing anything, so the operator sees the cleanup before it happens.

### D3. One risk score: module, zone, environment, site, release

**Points per counted CVE.** A CVE falls into one category: an analysed item by its TAPPaaS
rating, an open or carried item by its CVE severity.

| State | Critical | High | Medium | Low |
|---|---|---|---|---|
| risk (by its TAPPaaS rating) | 25 | 10 | 3 | 1 |
| open / carried (by its CVE severity) | 20 | 8 | — | — |
| decided | 0 | 0 | 0 | 0 |

Medium and low CVE severities without an analysis are not counted; the scan still lists them.
Whether a fix is available plays no part: the risk is the same until the fix is installed, and
the score does not show it.

**Module score.**
1. Only the **highest category that has any item** counts. If a module has a critical item, its
   highs, mediums and lows add nothing. If it has no critical but some highs, its mediums and
   lows add nothing, and so on.
2. Within that category the items are sorted by points, highest first, and **each additional
   item counts half the one before**: three risk-rated criticals score
   25 + 25×50 % + 25×50 %×50 % = 43.75. A risk critical and an open critical score
   25 + 20×50 % = 35.
3. So one category never reaches twice its top value: critical below 50, high below 20, medium
   below 6, low below 2.

The level comes from the score (after the zone multiplier, for a zone):

| Score | 0 | above 0, below 7 | 7 to below 16 | 16 to below 30 | 30 and above |
|---|---|---|---|---|---|
| Level | ok | low | medium | high | critical |

The bands are wider than the categories on purpose. A single new critical does not make a module
critical: one open critical (20) or one analysed critical (25) is **high**; it takes two
criticals (25 + 12.5) or a critical in the management zone (20 × 2) to reach critical. One open
or analysed high (8 or 10) is medium. Analysed highs reach high from three (10 + 5 + 2.5 = 17.5);
open highs alone approach 16 but never reach it, so unanalysed highs keep a module at medium in a
service zone. Mediums and lows never pass low.

**Zone.** A zone's score is the highest module score among the modules deployed in it, times the
multiplier of the zone's `tier` in `zones.json`:

| Tier | 0 (management) | 1 (services) | 2 | 3 | 4 (DMZ) | 5 and 6 |
|---|---|---|---|---|---|---|
| Multiplier | ×2 | ×1 | ×0.75 | ×0.5 | ×0.25 | ×0.1 |

The multiplier follows the tier structure the firewall already enforces: the lower the tier, the
more a compromise there reaches. On hrossen that puts mgmt at ×2; rossen and test at ×1; home at
×0.75; iotCloud, iotUntrust and guest at ×0.5; dmz at ×0.25; and iotLocal and iotCams at ×0.1.
A zone without a tier (the overlays, work, wan) counts ×1. So one open critical in a service zone is high (20), and in the
management zone critical (40); one open high in the management zone is high (16).

**Environment and site.**
- An environment's score is the **highest score of its zones** (the zones whose `environment`
  names it, as `zones.json` and the CMDB already record).
- The site's score is the highest of its environments **and of every zone that belongs to no
  environment** (dmz, work, guest, the overlays…).
- The platform targets count as modules of the zone they sit in: the pvehost nodes, the firewall
  (it sits in every zone, and counts in the management zone) and the backup server in the
  management zone, unifi-os in its own zone. Woodpecker is a module
  like any other (D2 and D5 apply to it: a VEX file, compared in the preview, scored).
- Each score is shown with the module that sets it, so the number always points at its cause.

**Release score.** The module score over the candidate's closures and images. A release knows no
site's zones, so it has no zone multiplier. The release's own level is its highest module score.
Both are recorded per module in `releases.json` at `record` and printed in the release notes.

Example, immich in the 2.4 candidate: the highest category with an item is critical, holding one
open item (brotli, 20), so immich scores **20, high**. Its nine open highs and six risk-rated
items add nothing while that one is there. Triage brotli to not affected and the high category
counts instead: nine open highs give 8 × (1 + ½ + … + ½⁸) ≈ 15.97, medium. On hrossen immich
sits in the `rossen` service zone (tier 1, ×1), so the `rossen` environment is at least 20 too.

The computation lives in one place: a `score` function in `lib/ts` used by health-manager. The
preview calls `health-manager score --details <file>` instead of duplicating it in Python.

### D4. Health, alerts and the console

- **Health (ADR-041).** The `security` condition on a module, node, zone or environment takes
  its status from the level: ok/low → ok, medium → warning, high → warning, critical →
  **critical**. Zones and environments take their own score (D3), not the ADR-041 worst-of
  roll-up, so the zone multiplier shows in health too.
  A level change is a status change, so it emits an event even if the condition was already
  warning. `cve-scan-failed` stays warning; `cve-scan-stale` stays on the site.
- **Alerts (ADR-039)**, in `tappaas-cicd-alerts.json`:
  - `cve-new-critical`: an immediate mail when the scan finds a new critical/high CVE that is
    **open** in a module (the scan's `new`, minus what VEX decides). One mail per scan, listing
    the items.
  - `cve-level-up`: an immediate mail when a module's level rises to high or critical.
  - Everything else (new medium-weight items, a level going down, carried items) goes into the
    daily digest.
  - Quieting is the existing `health-manager ack` and maintenance windows.
- **Scan cadence.** A daily `tappaas-security-rescan.timer` refreshes the grype/trivy databases
  and rescans the last inventory (no new SBOM, no sweep). New CVEs then show within a day even on
  a site that skips sweeps. It talks only to the scanners' database mirrors, never to Codeberg.
- **Console.** The `/security` page goes live on `/api/security`:
  - The site level and score, then one row per environment, then per zone (with its
    multiplier), then per module and platform target: level, score, the module that sets it,
    open / risk / carried / decided counts, and a 7-day sparkline. The zones that belong to no
    environment sit directly under the site.
  - A module row expands to its counted CVEs with state, category, package and version, rating
    and the VEX analysis text. Whether a fix exists is not shown.
  - The Overview "Security" tile and the Modules badge show the level instead of "CVE act".
  - `health-manager report security` prints the same table.

### D5. The release process

Written down in RELEASE-TRAIN.md as a runbook. The gate policy changes:

- **What needs an ack:** open and carried critical/high items new against the last release,
  risk items rated high or critical, majors, and failed matches.
- **What passes without an ack:** a new item that is already analysed at risk low or medium.
  Analysing it was the decision; asking again is noise. It still counts in the release score.

The steps, from T-3 days to the boundary:

1. **Preview** (T-3): `tappaas-train.sh preview`. Read the per-module rows: OPEN, RISK,
   CARRIED, GONE, stale acks, and the release score.
2. **Fix first.** For every row with fixable items, bump the image or package pin (the preview's
   "fix exists" column and `image-pins.py`), live-test it on the staging site, and re-preview.
   No module is acked while a tested bump would clear its items.
3. **Confirm carried items**: `cve-triage.sh carry` after reading each previous analysis.
4. **Triage open critical/high**: `cve-triage.sh open <module>`, then `add` for each item:
   not affected (with justification), false positive, or exploitable with a rating. An item
   that would take more than a short analysis can be acked with a note saying so, and goes on
   the roadmap.
5. **Ack the rest**, one note per module: `tappaas-train.sh ack --module <m> --note "<why>"`.
   The note says what was accepted and why: no fix upstream, not reachable in practice, tracked
   in #N.
6. **Boundary**: `pin_gate` re-checks, the `cve` phase cleans up (D2), and `record` stores each
   module's release score, its counts and the ack notes in `releases.json`.

The release notes get a security section generated from the record: the release's level and
score, each module's score and level against the previous release, what was fixed (FIXED
counts), what was decided, and what was accepted with its note.

## Consequences

- **Good.**
  - VEX stays true to what ships. Dead statements leave by themselves, and a version change
    becomes a confirmation, not a lost analysis.
  - An ack is a recorded decision, kept with the release instead of deleted.
  - One number and one level answer "how exposed is this module, zone, environment, site or
    release",
    in the console, in health, and in the release notes.
  - A new open critical reaches the operator the same day, by mail.
- **Cost.**
  - A boundary phase that commits to the pin branch.
  - A `score` function and its tests, health and alert changes, a console page, a rescan timer.
  - The weights, the halving and the zone multipliers are judgement calls. They live in one
    table, so changing them is one edit, and the release record stores the values it used.
- **Risk.**
  - A wrong "gone" removes a statement production still needs. Judging against all three
    channels guards against it, and a removed statement is in git history and can be restored
    with `cve-triage add`.
  - Scores invite gaming (deciding things away). The VEX analysis text is shown next to every
    decided item in the console and the release notes, so a decision stays reviewable.

## Phases

| Phase | Content | Done when |
|---|---|---|
| P1 | D2: preview classification (LIVE/CARRIED/GONE, stale acks), `cve-triage carry`, ack pinned to digest and pin, the boundary `cve` phase, ack archive in `releases.json` | A rehearsal boundary removes the 3 stale immich statements and lists the baseline's glibc items as carried |
| P2 | D3: `score` in `lib/ts` (module, zone with its tier multiplier, environment, site), `health-manager score`, preview and release record use it; woodpecker gets a VEX file and a preview row | The 2.4-style preview prints a score per module (immich 20, high) and the record stores it |
| P3 | D4: health status from level, the two alerts, the rescan timer, the console page and badges | On hrossen a new open critical mails within a day, and `/security` shows site → environment → zone → module |
| P4 | D5: gate policy (analysed low/medium pass), the runbook in RELEASE-TRAIN.md, the release-notes section, ADR-028 cross-reference | The next boundary is run from the runbook alone |

## Settled in review

Settled in v0.2 (operator, 2026-11-07): the base weights 25/10/3/1; open items at 20/8; only the
highest category counts, each further item at half the one before; no fix multiplier and no "fix
available" in the score or the console; analysed low and medium pass the gate without an ack;
environments are the highest of their zones, zones the highest of their modules times ×0.25 (DMZ)
or ×2 (management), and zones outside every environment roll up to the site; woodpecker is a
module like any other.

Settled in v0.3 (operator, 2026-11-07): the level bands are 0 / 7 / 16 / 30, so a single new
critical is high and only the management zone or a second critical makes it critical; the zone
multiplier follows the zone tier (tier 0 ×2, 1 ×1, 2 ×0.75, 3 ×0.5, 4 ×0.25, 5 and 6 ×0.1),
replacing the DMZ/management types of v0.2.

Settled in v1.0 (operator, 2026-11-07): a zone without a tier counts ×1, and the firewall counts in
the management zone (tier 0, ×2), so one open critical in it makes the site critical.
