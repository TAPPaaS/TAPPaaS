# ADR-048 — The Security Stream

| | |
|---|---|
| **Status** | **Proposed** — every question settled with the operator; for his review |
| **Version** | 0.4 |
| **Date** | 2026-11-11 |
| **Author** | Lars Rossen |
| **Deciders** | @LarsRossen |
| **Closes / addresses** | The delivery half of [ADR-047](<ADR-047 - CVE Decisions and the Daily Work.md>). Amends ADR-028 (private channels, a daily patch line, a public line 14 days behind), ADR-033 (subscriber tags, a second remote, a stream key for data) and ADR-045 (decisions no longer travel only with a release). |
| **Changelog** | v0.1 (2026-11-10): first draft, a soft paywall over open development. v0.2 (2026-11-11): the operator's model, replacing it. **Development is private**: unstable and staging live on a server we run. **Production exists twice**: a subscriber line with daily bug, security and decision patches, and a public line that gets the same feature releases at the same boundaries and each patch 14 days later. Access by **per-site tokens** on that server. Both the decision feed and the patches are paid. A person signs every patch release. Canary: hrossen and makerfloss, two days. v0.3 (2026-11-11): **Proposed.** A fix for a known-exploited CVE goes to the public line at once. The licence stays plain MPL-2.0 and the embargo is practical only: no subscriber terms, no contributor agreement. The forge is Forgejo on a rented server, its own TAPPaaS site, administered by Lars, best effort. A lapsed token works for 14 more days. A production canary on the subscriber line joins the ring. The roadmap and the ADRs are published at once from private `main`. A bug fix enters the daily patch only with a `Patch:` trailer naming how it affects operation. v0.4 (2026-11-11): the production canary runs a separately signed **canary tag** that only canary-ring sites accept, signed in the same `sign-day` sitting (D4, D8). The two remaining choices are listed as deferred. No question is open. |

A production site gets a fix or a CVE decision when the release that carries it reaches `stable`,
up to four weeks after it was made. This ADR adds a daily stream of bug fixes, security patches
and decisions to production, and makes that stream the paid product: subscribers get it daily,
everyone gets it 14 days later. Features keep the train and its soak, and reach both at the same
boundary.

## Context

- A site reads its code and its CVE decisions from the branch it tracks. `stable` moves every two
  weeks and is one release behind `staging`.
- Debian guests, the nodes and the firewall patch themselves from their distributions (ADR-028
  D5). NixOS guests move when the pin moves, a container image when its pin line moves, and
  TAPPaaS's own code when a release moves.
- ADR-028 D12 and D15 allow an urgent fix on `stable` between boundaries, by hand, numbered
  `vMAJOR.MINOR.N` and signed.
- ADR-033 makes `stable` and `staging` tips signed tags, verified before a checkout moves.
- Today everything is developed in the open on Codeberg, pushed on to a GitHub mirror, and the
  documentation site is built from the same repository. Three people have commits in the tree.
- Sites do not report back.
- Constraints: no scheduled job and no polling against Codeberg; images are on GitHub Releases.

## Decision

### D1. Private development, two production lines

| Channel | Where | Who can read it | Moves |
|---|---|---|---|
| **unstable** (`main`) | the private forge (D7) | maintainers and contributors | continuously |
| **staging** | the private forge | maintainers, contributors, the staging sites | at the boundary, and daily patches |
| **production, subscriber line** | the private forge, a repository of its own | subscribed sites | feature releases at the boundary; bug, security and decision patches daily |
| **production, public line** | Codeberg, public | everyone | the **same feature releases at the same boundary**; each patch **14 days after** subscribers got it |

A feature never reaches a subscriber earlier than the public. What a subscription buys is 14 days
on every fix and every decision, and nothing else.

### D2. What a patch may be

A patch is a commit from `main` that a release line takes between boundaries. Three kinds
qualify:

| Kind | Examples | How it is recognised |
|---|---|---|
| Security | a nixpkgs lock move inside the same NixOS release; an image pin inside the same minor; a code fix for a vulnerability | commit type `build(pin)`, or a `fix` with `Patch: security` |
| Decisions | component records (ADR-047) | commit type `chore(vex)` |
| Bug fix that affects operation | a backup that does not run, an update that fails, a service that does not start, a check that reports wrongly | a `fix` with a `Patch:` trailer |
| Health rule correction | a released rule file that reports wrongly (ADR-049 D7) | a `fix(health-rules)` with a `Patch:` trailer; it changes rule files only, and is a patch like any other bug fix |

**The marker is a commit trailer** on the `fix` commit on `main`:

```
fix(backup): pull job skipped when the buddy answers late

Patch: operation
```

| `Patch:` value | Means | From ADR-028 D12 |
|---|---|---|
| `data` | data is lost, or a backup believed to exist does not | data safety |
| `security` | a vulnerability in TAPPaaS's own code or configuration | security |
| `service` | a service is down or cannot start | service down |
| `operation` | an update, a test, a check or an operator path fails or misleads | disruption |

The author sets it; the maintainer who runs the patch day reads the list of marked commits and
can drop one. **A `fix` without the trailer is cosmetic by definition and waits for the
release**: wording, layout, a log line, a refactor that fixes nothing an operator meets. The
commit-message hook accepts the trailer beside the three body lines and refuses any other value.

Never on a patch line, marked or not: `feat` commits, a migration, a change to a configuration
schema, a new module, a new NixOS release, a minor or major version of an image.
`tappaas-train.sh patch-scope` refuses a patch that carries one, by commit type, by the trailer,
and by a list of paths that only a release may touch (`migrations/`, `fields.json`,
`module-catalog.json`, `flake.nix`). The site's verifier applies the path list too, so a mistake
in the release tooling cannot put a migration on a patch.

### D3. One release, two branches: how the lines stay the same

Each release in service has two branches on the private forge:

| Branch | Holds | Tagged |
|---|---|---|
| `rel/X.Y` | the release as cut, plus every patch whose embargo has ended | `vX.Y.N`: the **public** line |
| `sub/X.Y` | `rel/X.Y` plus the patches still under embargo | `vX.Y.N+sK`: the **subscriber** line, K patches ahead of public `vX.Y.N` |

The rules that keep them from drifting:

1. **A patch enters through `sub` only.** It is cherry-picked from `main` onto `sub/X.Y`. Nothing
   is ever committed to `rel` directly.
2. **A patch leaves the embargo in the order it entered.** Fourteen days after its subscriber
   release, the oldest embargoed patch is cherry-picked from `sub` onto `rel`, `rel` is merged
   back into `sub`, and both are tagged: public `vX.Y.(N+1)` and subscriber `vX.Y.(N+1)+s(K-1)`.
   The merge changes no file. Two cases are taken out of order, and the check covers them like
   any other: the boundary's release-fault ports (below), and a fix for a known-exploited CVE,
   which is ported the day it is released to subscribers (D4).
3. **The check.** `tappaas-train.sh embargo-check` computes, for every line: the tree of `sub`
   must equal the tree of `rel` with the embargoed patches applied in order, and when no patch is
   under embargo the two trees must be identical. It runs before every tag on either branch. A
   mismatch stops the publication. The lines cannot drift without it being seen the same day.
4. **Each tag says what it holds.** The tag message of a subscriber tag lists the ids of the
   patches still under embargo; a public tag lists the ones it has taken. The verifier uses this
   in D8.
5. **A fault found during the soak is a patch like any other.** It goes to `sub`, and is public
   14 days later. If the release it fixes becomes public production before that, the boundary
   takes it across early (below).

**At a boundary**, for the release leaving staging:

- subscriber production moves to the tip of `sub/X.Y`;
- public production moves to the tip of `rel/X.Y`, after the boundary has ported every patch on
  `sub/X.Y` that fixes a fault this release introduced. Those are named when they are made
  (`fix … --release-fault`). The public never gets a release with a known fault of its own that
  subscribers have already had fixed. Security and other patches keep their 14 days.

A release line was cut from `main` 14 days before it becomes production, so every fix that was on
`main` at the cut is in `rel/X.Y` from the start, and each of them reached subscribers at least
14 days earlier on the previous line. The cadence and the embargo are both 14 days on purpose.

### D4. The daily rhythm and the gates

| When | Who | What |
|---|---|---|
| nightly | the staging site (hrossen) | scan, rescan, `candidates` (ADR-047 D8) |
| morning | a maintainer | the queues; fixes, pin moves and records are pushed to private `main` |
| on that push | the build | the **decision feed** (D5): lint, sign, gate, publish to subscribers the same day |
| the same day | `tappaas-train.sh patch-day` | picks the day's qualifying commits (D2) onto `sub/X.Y` for each line in service; `patch-scope`; `embargo-check` |
| **gate 1**, hours | hrossen | every NixOS module's system is built from each patched line; the canary guest is deployed from it and its module test runs; a moved image runs its module's test |
| **gate 2**, two days | hrossen, makerfloss and the production canary | hrossen and makerfloss run the patched staging line, the production canary the patched subscriber line. The patch moves on unless `tappaas-train fault` records a fault against it |
| **gate 3**, a signature | a maintainer with a release key | `vX.Y.N+sK` on each line; subscribers get it that night |
| 14 days after gate 3 | the forge, then a maintainer | the port of D3, `embargo-check`, a signature on the public tag, a push to Codeberg |

So a fix written on day 0 is on subscriber production on day 2 and on public production on day
16. Days with no patch commit produce nothing.

**Known-exploited: the same day, and for everyone.** A fix for a CVE on the known-exploited
list skips gate 2 and the embargo: `patch-day --expedite --why "security: …"`. Gate 1 and the
signatures stay. It is tagged on `sub` and ported to `rel` in the same sitting, so subscriber and
public production get it the same day. Nobody is left open to an attack in progress because
they do not pay. Every other patch waits its 14 days, a critical one included.

**The canary ring.** Three sites, two days:

| Site | Runs | Shows |
|---|---|---|
| hrossen | unstable; gate 1 builds and deploys each patched line there | the patch builds for every module and a guest takes it |
| makerfloss | the patched staging line | the patch under real use on the next release |
| the production canary | the patched subscriber line, one tag ahead of the other subscribers | the patch under real use on the release production runs |

The production canary is one of Lars's own production sites or a subscriber who agreed to it. It
has `security.ring: canary` in its `site.json`, and the forge serves it each subscriber tag when
gate 1 passes and its canary tag is signed, two days before the others. Its operator reports a fault with
`tappaas-train fault`, or by telling a maintainer, who records it.

**Signing, made cheap.** One sitting a day at most. `tappaas-train.sh sign-day` on the signer's
machine fetches every tag that waits, prints one screen for each (the commits, the scope check,
the gates passed, the tree hash, for a public tag the embargo dates), and signs them after one
confirmation. A typical day is one subscriber tag per line and, two weeks into the model, one
public tag per line: two to four signatures from one command. The production canary takes a
patch two days before its release tag exists, so the sitting also signs a **canary tag** for each
patch that passed gate 1 the day before (D8): one more signature per line on a patch day. The
signature stays a person's
statement about one commit, as ADR-033 has it; no automation key can sign a release.

### D5. The decision feed

ADR-047's component records, delivered as data the day they are made.

- **Content.** One file, `tappaas-decisions.json`: every module's records from private `main`,
  with `sequence`, `generated`, `validUntil` (14 days) and the source commit. Records name the
  versions they hold for, so one feed serves every line.
- **Built by an event**: a push to `main` that touches a records file. No schedule.
- **Signed** with `ssh-keygen -Y sign -n tappaas-decisions` by a **stream key** that
  `.tappaas/allowed_signers` restricts to that namespace. It can sign a feed and nothing else. It
  lives with the build on the private forge.
- **Gate.** hrossen applies each feed first. It is published when the lint passed, the scan with
  it did not fail, and every unit whose level dropped is explained by a record that changed.
- **Verified at the site**: the signature and namespace, a `sequence` higher than the last, a
  `validUntil` in the future, the schema. A feed that fails is not applied. Past `validUntil` the
  site falls back to the records in its checkout and raises `decisions-stale`.
- **A known-exploited CVE counts at its upstream severity whatever the feed says.** That rule is
  in the site's code and uses the scanner's own database.
- **Paid.** The feed is served only to subscribers, from the forge (D7). The same records are
  patch commits on `sub`, so they reach the public line with the 14-day port, and a free site
  reads them from its checkout as it does today.

### D6. What becomes of the public repository, the mirror and the docs

| Thing | Today | With this ADR |
|---|---|---|
| Codeberg `TAPPaaS` | all development; `main`, `staging`, `stable` | the **publication repository**: `stable` (the public line) and the signed public tags. Default branch `stable`. No `main`, no `staging`. Nothing is developed there |
| History on Codeberg | every commit as it is pushed | the same commits, arriving with the release that contains them: a feature four weeks after it was written, a patch 14 days after subscribers got it |
| Codeberg CI | builds and tests on push | none. Releases arrive tested and signed |
| Issues | Codeberg | Codeberg stays the public tracker for faults and requests. Security reports and embargoed work are tracked on the forge |
| GitHub mirror | push mirror of Codeberg | unchanged, and it mirrors only Codeberg. It must never be pointed at the forge. Subscriber tags (`+sK`) never reach Codeberg, so they never reach GitHub |
| Images on GitHub Releases | built at releases | unchanged. Images change at feature releases, which both lines get on the same day, so they stay public |
| Documentation site | built from the repository | built from public `stable` at each public release. It describes what the public can run. A preview for unreleased work is served from the forge to maintainers and contributors |
| ADRs and the roadmap | on `main`, public at once | **still public at once**, through the `design` branch below |
| `channels.json` | declares unstable, staging, production | the public repository declares production only. The forge's repositories declare all three, and the subscriber line |

**Plans and design stay public in real time.** Only code and patches are delayed. `ROADMAP.md`
and `docs/ADR/` are written on private `main` as today, and published on every merge:

- A push to private `main` that touches `ROADMAP.md` or `docs/ADR/**` starts a job on the forge
  (a path-filtered trigger). It copies exactly those paths to a `design` branch and pushes that
  branch to Codeberg. `design` has a history of its own and holds nothing else, so no code can
  leave by it; the job refuses a commit that would add any other path.
- The documentation site builds its roadmap and ADR pages from `design`, and everything else
  from public `stable`. An ADR can therefore describe something whose code is still four weeks
  from the public line; the page says which release carries it.
- One limit: an ADR or a roadmap line does not describe an unfixed vulnerability in detail
  before its patch is public. It names the work ("harden the pull path") and the detail follows
  with the patch.
- Codeberg issues stay the public tracker, so a plan and its discussion stay in one public place.

**Outside contributors.**

- **Regular contributors** get an account on the forge and work against private `main` as today.
  They see patches before the public does and are asked to keep the embargo. That is a request
  between colleagues, not a licence term (D9).
- **A pull request on Codeberg** is made against public `stable`, which is weeks behind `main`.
  A maintainer ports it to private `main`, with the author kept on the commit. It appears on
  Codeberg with the release that contains it. This is slower for the contributor than today and
  the page that explains contributing has to say so.
- **A fork** such as AndreasJe's keeps working against the public line. Integrating it becomes a
  port to `main` like any pull request; with a forge account it becomes direct.
- **Community and site module repositories** are their own repositories and are not affected.

### D7. The forge: tokens on a server we run

**What it is.** A Forgejo instance, installed as a TAPPaaS site of its own (the `forgejo` and
`woodpecker` modules, identity, backup), on a rented server, administered by Lars. Not hrossen:
the product must not depend on the test system. Availability is best effort: there is no second
server and no on-call. That is acceptable because no site needs the forge to keep running (see
"When the forge is down"). It holds:

| Repository | Readable by | Content |
|---|---|---|
| `tappaas/TAPPaaS` | maintainers, contributors | `main`, `staging`, every `rel/` and `sub/` branch, all tags |
| `tappaas/production` | subscribers (read-only) | the subscriber line: `stable` and the `+sK` tags, pushed there after gate 3. Its releases carry the decision feed |

A subscriber can read `tappaas/production` and nothing else. Development is not visible to them.

**How a site authenticates.**

- A subscription creates one account per site with one read-only access token. The operator
  enters it once: `site-manager subscription set` reads it from the terminal and stores it with
  the site's secrets. It is never put in a URL or a config file.
- The site's repository entry for TAPPaaS points at the forge. Fetches go over HTTPS with the
  token through a credential helper. The decision feed is fetched the same way, once a night,
  inside the update the site already runs.
- What arrives is verified exactly as today (ADR-033 D6): the tag's signature against the
  enrolled signers, the tree hash, the ancestry. The forge is transport. A compromised forge can
  withhold a release; it cannot make a site run something unsigned.

**Revocation and figures.** Disabling the account ends access at once. The forge's access log
gives, per site: last fetch, the tag it fetched, and so which sites are behind. A small licence
service beside Forgejo holds `site → token → paid until` and disables an account 14 days after
its subscription ended.

**When a subscription lapses**, the site falls back to the public line without the operator
doing anything, and without ever going backwards:

1. **Grace, 14 days.** From the day the subscription ends the token still works. The forge adds
   "subscription ended on <date>, access until <date>" to its answers, and the site raises a
   `subscription` warning that says so.
2. **The token is disabled.** The forge answers the site's fetch with "subscription ended" (a
   status the site can tell from an outage). The site stops asking for the feed.
3. The site keeps the subscriber tag it runs. It paid for those patches.
4. Each night it looks at the public line. It moves there when a public tag exists whose base
   release is the same or newer **and** whose tag message lists every patch its own tag held
   under embargo (D3 rule 4). That is at most 14 days later, or at the next boundary.
5. From then on it follows Codeberg as any free site. Renewing at any point returns it to the
   subscriber line.

A public tag is not a git descendant of a subscriber tag, so ADR-033's "never backwards" rule
gains this one case: a move from a subscriber tag to a public tag that contains all its patches.
The same rule lets a free site subscribe: a subscriber tag always contains its public base.

**When the forge is down**, subscribers get no patches until it is back. Nothing breaks: a site
stays on its last verified release. An outage longer than `validUntil` makes the feed stale and
sites say so.

### D8. What changes in the verifier and the train

- **A canary tag is told from a release tag in two ways, and both must agree.** Its name is the
  release tag's with `-rc` (`vX.Y.N+sK-rc`), which the release-tag pattern does not match. Its
  signed message carries `ring: canary`; a release tag's carries `ring: release`. A name and a
  message that disagree are refused. The signature and the signers are the same as for a release
  tag (ADR-033 D2, D4): what differs is what the tag says, not who may say it.
  - A site accepts a canary tag only when its own `site.json` has `security.ring: canary`. Every
    other site refuses it, wherever it came from, and reports the refusal.
  - A canary tag is never a base for trust: it cannot enrol or remove a signer, and it is not
    recorded as the last verified release. The chain of ADR-033 D4 runs through release tags only.
  - The release tag signed after the soak points at the same commit. A canary site moves to it
    without a rebuild; the tree hash is the same.
  - A canary tag whose patch is withdrawn after a fault has no release tag. The canary site goes
    forward to the next canary or release tag; the ancestry rule holds, because a withdrawn patch
    is reverted on `sub`, never rewound.
  - Canary tags are served from a `canary` branch of `tappaas/production` and never reach
    Codeberg.
- Release tags match `vX.Y.N` and `vX.Y.N+sK`. A subscriber tag's message carries
  `embargoed: <patch ids>`; a public tag's `patches: <patch ids>`.
- The ancestry rule accepts the two cross-line moves of D7 and no other.
- `patch-scope` (paths) runs in the verifier for any tag that is not a feature release.
- The train gains `patch-day`, `embargo-check`, `sign-day` (release and canary tags), and the port. `tappaas-train patch`
  (ADR-028 D15) becomes `patch-day --expedite`.
- The stream key is one line in `allowed_signers` with `namespaces="tappaas-decisions"`.

### D9. The licence: plain MPL-2.0, a practical embargo

Everything stays MPL-2.0, for subscribers and for the public. There are no subscriber terms and
no contributor agreement.

- **MPL-2.0 requires** that whoever receives the software can get its source under MPL.
  Subscribers receive source. It does not require publishing to the public and sets no deadline,
  so a 14-day delay before the public release breaks nothing.
- **MPL-2.0 lets every recipient pass the software on.** A subscriber may lawfully publish a
  patch on the day they receive it. Nothing in the subscription says otherwise, and nothing may.
- **So the embargo is practical, not legal.** It holds because the patches are served only to
  tokens, because a subscriber gains nothing by republishing, and because the public gets the
  same patch 14 days later anyway. A leak costs 14 days on that patch and nothing else.
- **What a subscription buys is a service**: the triage done, the patch built, tested on three
  sites, signed and delivered daily, and the decision feed. It does not buy exclusive rights to
  code.
- **Contributions** come in under MPL-2.0 as today. No rights beyond the licence are needed from
  Erik, Andreas or anyone else, because nothing is distributed under other terms.
- **Upstream is never embargoed.** A CVE and its upstream fix are public from the first minute;
  what waits 14 days is our work on top of them.

## Consequences

- **Good.**
  - A subscriber gets a fix in two days and a decision the same day; a known-exploited fix the
    same day.
  - The public line loses nothing against today: it gets features at the same boundary and fixes
    within 14 days, where today a fix waits up to four weeks.
  - The two production lines are held together by a tree check, not by care.
  - Revocation is immediate and usage is visible.
- **Cost.**
  - A server to run, back up and keep available, with a licence service.
  - Moving development off Codeberg: accounts, CI, the docs build, the mirror's source, every
    session's and contributor's remotes.
  - Two branches and two tag series per release, a daily patch routine and a daily signature.
  - Open development of code ends; plans and design stay open. Outside contributions get slower.
- **Risk.**
  - **A patch breaks production.** Gate 1 builds every module; gate 2 is two days on two sites;
    the way back is the previous tag by an operator command.
  - **The lines drift.** `embargo-check` before every tag.
  - **The embargo leaks.** It lawfully can (D9). A leak gives the public early what it gets on
    day 14.
  - **The public waits 14 days for a fix subscribers have.** Never for a known-exploited CVE
    (D4). For the rest, the upstream fix and advisory are public, the Debian half of every site
    patches itself, and today the same fix waits up to four weeks.
  - **The forge is the single way to patches for subscribers, on best effort.** Signed content
    limits what a compromise can do; an outage delays patches and breaks nothing. A
    known-exploited fix also goes to Codeberg, so it is reachable with the forge down.

## Alternatives considered

- **A soft paywall over open development** (v0.1): everything authored on public `main`, the
  daily delivery sold. Replaced by the operator's decision.
- **The public line as the subscriber line 14 days late, with no second branch.** No porting at
  all, and the simplest. It fails at the boundary: features would also arrive 14 days late on the
  public line, or the public would get every fresh patch at each boundary.
- **Encryption to a site key on a public host.** No server, and no instant revocation or usage
  figures. Replaced by tokens.
- **Move the boundary forward for every fix** (ADR-028 today). Kept for anything outside the
  patch scope.

## Phases

| Phase | Content | Done when |
|---|---|---|
| S1 | The forge as a TAPPaaS site; development, CI and the docs preview move there; Codeberg becomes the publication repository; the `design` branch and its job; the mirror and the docs site build from Codeberg | A boundary runs from the forge; Codeberg receives only `stable`, its tags and `design`; an ADR merged to private `main` is on the docs site the same hour |
| S2 | `rel/` and `sub/` branches, `+sK` tags, `patch-scope`, `embargo-check`, the port, the verifier's cross-line rule | A rehearsal line takes three patches, ports them in order, and the check stops a deliberately wrong port |
| S3 | The `Patch:` trailer and the hook; `patch-day`; gates 1 and 2 with the production canary; `sign-day`; `--expedite` with its same-day public port | A marked fix pushed in the morning is on the canary that day and on a subscribed test site two days later with one signing command; an unmarked fix is left for the release |
| S4 | The decision feed: builder, stream key, site verification, fallback | hrossen applies a feed and refuses a replayed and an expired one |
| S5 | Tokens: accounts, `site-manager subscription`, the licence service, the 14-day grace, lapse and fallback | A lapsed test site warns for 14 days, holds its tag, then joins the public line by itself when the public tag covers its patches |

## Settled in review

Settled in v0.2 (operator, 2026-11-11): a hard paywall with a 14-day embargo; unstable and
staging private; production as a subscriber line and a public line with the same feature
boundaries; per-site tokens on a server we run, with fallback to the public line when a
subscription lapses; the feed and the patches both paid; a person signs each patch release with a
release key; the canary ring is hrossen and makerfloss for two days.

Settled in v0.3 (operator, 2026-11-11): a fix for a known-exploited CVE goes to the public line
at once, every other patch waits 14 days; the licence is plain MPL-2.0 with a practical embargo,
no subscriber terms and no contributor agreement; the forge is Forgejo on a rented server, its
own TAPPaaS site, administered by Lars, best effort; a lapsed token is disabled after 14 days of
grace; one production canary on the subscriber line joins hrossen and makerfloss; the roadmap
and the ADRs are published at once; the daily patch takes security fixes, decisions, and bug
fixes marked as affecting operation, and cosmetic fixes wait for the release.

Settled in v0.4 (operator, 2026-11-11): the production canary runs a separately signed canary
tag that only canary-ring sites accept, signed in the same `sign-day` sitting as the rest.

## Open questions

None.

## Deferred

Two choices are left to the day they are needed. Neither changes this ADR:

- which site is the production canary: one of Lars's own production sites, or a named subscriber;
- which rented server hosts the forge.
