# ADR-045 — CVE Lifecycle and Risk Scores

| | |
|---|---|
| **Status** | **Draft** — for the operator's review |
| **Version** | 0.1 |
| **Date** | 2026-11-07 |
| **Author** | Lars Rossen |
| **Deciders** | @LarsRossen |
| **Closes / addresses** | Follows #788 (release CVE preview and ack). Amends ADR-011 §8 (VEX lifecycle), ADR-028 (the boundary gains a CVE phase and a release score), ADR-041 (security conditions take their status from the risk level) and ADR-039 (an alert for new critical/high CVEs). |
| **Changelog** | v0.1 (2026-11-07): first draft, from the operator's direction of 2026-11-07, after the 2.4 preview walk-through of immich. |

A site keeps three CVE records today: the nightly scan, the VEX statements in the repo, and the
acks for the next boundary. None of them cleans itself, and none of them adds up to a number an
operator can watch. This ADR gives them a lifecycle and one score:

1. **Cleanup is automatic.** The boundary removes VEX statements that no longer match anything
   any channel ships, lists the ones a version change has made inapplicable, and archives the
   acks it used.
2. **One risk score**, computed the same way for a running module, an environment, the site and
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

### D3. One risk score: module, environment, site, release

**Per CVE**, the points it adds:

| State | Critical | High | Medium | Low |
|---|---|---|---|---|
| risk (by its TAPPaaS rating) | 25 | 10 | 3 | 1 |
| open / carried (by its CVE severity) | 10 | 4 | — | — |
| decided | 0 | 0 | 0 | 0 |

An open item weighs less than a confirmed critical or high, and more than a confirmed medium:
"not analysed" is not the same as "dangerous". Medium and low CVE severities without an
analysis are not counted; the scan still lists them.

A **fix multiplier** applies on a running site: ×2 for any counted CVE whose fix is available
in the module's channel and not applied (the scan's `act` verdict, an image tag that clears it,
or an OPNsense package update). Leaving a known fix uninstalled is worse than having no fix.

**Module score** is the sum of points. Its **level** is the higher of:

| Score | 0 | 1–9 | 10–24 | 25–49 | ≥ 50 |
|---|---|---|---|---|---|
| Level | ok | low | medium | high | critical |

and the worst single `risk` rating. One confirmed critical makes the module critical, however
low its sum.

**Environment and site.**
- An environment's **level** is the worst level of its modules. Its **score** is the sum, shown
  with the module that contributes most.
- The site adds the foundation modules and the platform targets (pvehost nodes, the firewall,
  unifi-os, Debian LXC) as their own rows. Its level is the worst of all of them.
- The "worst level" rule keeps one bad module visible. The sum shows trend.

**Release score.** The same function over the candidate's closures and images, with no fix
multiplier (a release ships what it pins). It is recorded per module in `releases.json` at
`record` and printed in the release notes. Example, immich in the 2.4 candidate: open
brotli critical (10), 9 open high (36), 4 risk low (4), 1 risk low on ffmpeg (1), 1 risk medium
on ffmpeg (3) → **54, critical** by sum, medium by worst rating; the release notes show both
the number and the items that make it.

The computation lives in one place: a `score` function in `lib/ts` used by health-manager. The
preview calls `health-manager score --details <file>` instead of duplicating it in Python.

### D4. Health, alerts and the console

- **Health (ADR-041).** The `security` condition on a module, node or environment takes its
  status from the level: ok/low → ok, medium → warning, high → warning, critical → **critical**.
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
  - The site level and score, then one row per environment, then per module and platform
    target: level, score, open / risk / carried / decided counts, the top contributors, and a
    7-day sparkline.
  - A module row expands to its counted CVEs with state, package and version, rating, fix, and
    the VEX analysis text.
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

The release notes get a security section generated from the record: the site's release level
and score, each module's score and level against the previous release, what was fixed (FIXED
counts), what was decided, and what was accepted with its note.

## Consequences

- **Good.**
  - VEX stays true to what ships. Dead statements leave by themselves, and a version change
    becomes a confirmation, not a lost analysis.
  - An ack is a recorded decision, kept with the release instead of deleted.
  - One number and one level answer "how exposed is this module, environment, site or release",
    in the console, in health, and in the release notes.
  - A new open critical reaches the operator the same day, by mail.
- **Cost.**
  - A boundary phase that commits to the pin branch.
  - A `score` function and its tests, health and alert changes, a console page, a rescan timer.
  - The weights are a judgement call. They are in one table, so changing them is one edit, and
    the release record stores the weights it used.
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
| P2 | D3: `score` in `lib/ts`, `health-manager score`, preview and release record use it | The 2.4-style preview prints a score per module and the record stores it |
| P3 | D4: health status from level, the two alerts, the rescan timer, the console page and badges | On hrossen a new open critical mails within a day, and `/security` shows site → environment → module |
| P4 | D5: gate policy (analysed low/medium pass), the runbook in RELEASE-TRAIN.md, the release-notes section, ADR-028 cross-reference | The next boundary is run from the runbook alone |

## Open questions

1. **Weights.** Are 25/10/3/1 for risk and 10/4 for open right? Should an open critical count
   as much as a confirmed high?
2. **Fix multiplier.** ×2 for an uninstalled fix on a running site: keep it, or show
   "fix available" as a separate flag instead?
3. **Analysed low/medium skip the ack.** Agree, or keep every new item behind an ack?
4. **Platform targets.** Count the firewall, nodes and unifi-os in the site level (D3), or show
   them beside it? Their fixes come from their own channels, not from a TAPPaaS release.
5. **Woodpecker** has no VEX and is not compared today. Bring it under the same rules in P1, or
   leave it out of the score until it has a VEX file?
